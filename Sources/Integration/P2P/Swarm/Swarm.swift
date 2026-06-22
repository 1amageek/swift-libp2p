/// Swarm - Connection lifecycle manager
///
/// Manages all connection lifecycle operations: dial, accept, upgrade, reconnect, idle check.
/// Corresponds to go-libp2p's swarm concept.
///
/// ## Responsibilities
/// - Listen on addresses and accept inbound connections
/// - Dial outbound connections (standard and secured transports)
/// - Upgrade raw connections (security + muxer negotiation)
/// - Handle inbound stream negotiation and dispatch
/// - Manage reconnection and idle connection cleanup
/// - Emit SwarmEvents for Node to consume
///
/// ## Design Decisions
/// - Actor: I/O heavy operations (dial/accept/upgrade) benefit from actor isolation
/// - ConnectionPool as nonisolated let: sync state queries avoid actor hop
/// - EventBroadcaster: actor nonisolated pattern (CLAUDE.md Pattern B)

import Foundation
import Synchronization
import P2PCore
import P2PTransport
import P2PSecurity
import P2PMux
import P2PNegotiation
import P2PRuntime

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Logger for Swarm operations.
private let swarmLogger = Logger(label: "p2p.swarm")

private func runBestEffort(_ context: String, _ operation: () async throws -> Void) async {
    do {
        try await operation()
    } catch is CancellationError {
        swarmLogger.debug("Best-effort operation cancelled: \(context)")
    } catch {
        swarmLogger.warning("Best-effort operation failed (\(context)): \(error)")
    }
}

private func sleepUnlessCancelled(for duration: Duration, context: String) async -> Bool {
    do {
        try await Task.sleep(for: duration)
        return true
    } catch is CancellationError {
        swarmLogger.debug("Sleep cancelled: \(context)")
        return false
    } catch {
        swarmLogger.warning("Sleep failed (\(context)): \(error)")
        return false
    }
}

internal actor Swarm {

    // MARK: - Configuration

    let configuration: SwarmConfiguration

    // MARK: - Sync-accessible components (nonisolated)

    /// Connection pool — sync access avoids actor hop for state queries.
    nonisolated let pool: ConnectionPool

    /// Dial backoff tracker.
    nonisolated let dialBackoff: DialBackoff

    /// Current listen addresses, accessible synchronously.
    nonisolated let listenAddresses: ListenAddressStore

    /// Resolved addresses for external advertisement (0.0.0.0 → actual interface IPs).
    nonisolated let advertisedAddresses: ListenAddressStore

    /// Event stream for Node to consume.
    nonisolated var events: AsyncStream<SwarmEvent> {
        broadcaster.subscribe()
    }

    // MARK: - Internal state

    private let providers: [any ConnectionProvider]
    private nonisolated let broadcaster = EventBroadcaster<SwarmEvent>()
    private nonisolated let negotiationSemaphore: AsyncSemaphore

    // Listeners
    private var listeners: [any ConnectionAcceptor] = []

    // Protocol handlers
    private var handlers: [String: ProtocolHandler] = [:]

    // State
    private var isRunning = false

    // Background tasks
    private var idleCheckTask: Task<Void, Never>?
    private var acceptTasks: [Task<Void, Never>] = []

    /// Long-lived tasks tracked by a monotonically increasing token so each can
    /// self-remove on completion (avoiding unbounded growth) and all can be
    /// cancelled at shutdown. Covers reconnect timers, per-connection
    /// inbound-stream loops, accept candidates, and per-stream negotiations.
    private var trackedTasks: [UInt64: Task<Void, Never>] = [:]
    private var nextTaskToken: UInt64 = 0

    // Peer-connected dedup tracking
    private var peerConnectedEmitted: Set<PeerID> = []

    // MARK: - Init

    init(configuration: SwarmConfiguration) {
        self.configuration = configuration
        self.providers = configuration.connectionProviders
        self.pool = ConnectionPool(configuration: configuration.pool)
        self.dialBackoff = DialBackoff()
        self.listenAddresses = ListenAddressStore()
        self.advertisedAddresses = ListenAddressStore()
        self.negotiationSemaphore = AsyncSemaphore(count: configuration.maxNegotiatingInboundStreams)
    }

    // MARK: - Handler Registration

    /// Registers a protocol handler for inbound stream negotiation.
    func registerHandler(for protocolID: String, handler: @escaping ProtocolHandler) {
        handlers[protocolID] = handler
    }

    /// Returns all registered protocol IDs.
    func registeredProtocolIDs() -> [String] {
        Array(handlers.keys)
    }


    // MARK: - Lifecycle

    /// Starts listening on configured addresses.
    func start() async throws {
        guard !isRunning else { return }
        isRunning = true

        startIdleCheckTask()

        // Start listeners
        let identity = configuration.localIdentity
        for address in configuration.listenAddresses {
            for provider in providers {
                if provider.canListen(address) {
                    do {
                        let listener = try await provider.listen(address, identity: identity)
                        listeners.append(listener)
                        emit(.newListenAddr(listener.localAddress))

                        let acceptTask = Task { [weak self] in
                            guard let self else { return }
                            await self.acceptLoop(listener: listener, address: listener.localAddress)
                        }
                        acceptTasks.append(acceptTask)
                    } catch {
                        emit(.listenError(address, error))
                    }
                }
            }
        }

        // Fail if no listeners could bind and we had addresses to listen on
        if listeners.isEmpty && !configuration.listenAddresses.isEmpty {
            throw NodeError.noListenersBound
        }

        // Update current listen addresses for synchronous access
        let boundAddresses = listeners.map(\.localAddress)
        listenAddresses.update(boundAddresses)

        // Resolve unspecified addresses (0.0.0.0 / ::) to actual interface IPs
        let resolved = Self.resolveUnspecifiedAddresses(boundAddresses)
        advertisedAddresses.update(resolved)
    }

    /// Shuts down the swarm: cancel tasks, close listeners, close connections.
    func shutdown() async throws {
        isRunning = false

        // Cancel accept loops first so listeners can close cleanly
        for task in acceptTasks { task.cancel() }
        acceptTasks.removeAll()

        // Cancel background tasks
        idleCheckTask?.cancel()
        idleCheckTask = nil

        // Cancel all tracked tasks (reconnect timers, inbound-stream loops,
        // accept candidates, per-stream negotiations).
        let tasksToCancel = trackedTasks
        trackedTasks.removeAll()
        for (_, task) in tasksToCancel { task.cancel() }

        // Drain the negotiation semaphore so any stream-negotiation tasks
        // blocked in `wait()` are resumed (they then observe cancellation /
        // closed streams instead of hanging forever).
        negotiationSemaphore.drain()

        // Cancel pending dials
        pool.cancelAllPendingDials()

        // Close all listeners
        for listener in listeners {
            emit(.expiredListenAddr(listener.localAddress))
            do {
                try await listener.close()
            } catch {
                swarmLogger.debug("Failed to close listener: \(error)")
            }
        }
        listeners.removeAll()

        // Close all connections
        for peer in pool.connectedPeers {
            let removed = pool.removeReleasing(forPeer: peer)
            for removal in removed {
                let managed = removal.managed
                do {
                    try await managed.connection?.close()
                } catch {
                    swarmLogger.debug("Failed to close connection to \(peer): \(error)")
                }
                if removal.shouldReleaseResource && managed.state.isConnected {
                    configuration.connectionResources.releaseConnection(peer: peer, direction: managed.direction)
                }
            }
            onPeerDisconnected(peer)
        }

        // Clear tracking state
        dialBackoff.clear()
        peerConnectedEmitted.removeAll()
        listenAddresses.clear()
        advertisedAddresses.clear()

        // Finish event streams
        broadcaster.shutdown()
    }

    // MARK: - Connection Management

    /// Dials a peer at the given address.
    ///
    /// If a dial to the same peer is already in progress, joins the existing dial.
    func dial(to address: Multiaddr) async throws -> PeerID {
        guard isRunning else { throw NodeError.nodeNotRunning }

        // Self-connection guard
        let localPeerID = configuration.localIdentity.keyPair.peerID
        if let targetPeer = address.peerID, targetPeer == localPeerID {
            throw NodeError.selfDialNotAllowed
        }

        // Gating check (dial)
        if let gater = configuration.connectionGater {
            if !gater.interceptDial(peer: address.peerID, address: address) {
                emitConnectionEvent(.gated(peer: address.peerID, address: address, stage: .dial))
                throw NodeError.connectionGated(stage: .dial)
            }
        }

        // Check for pending dial to same peer (join existing)
        if let peerID = address.peerID, let pendingTask = pool.pendingDial(to: peerID) {
            return try await pendingTask.value
        }

        // Dial backoff: suppress redundant dials to a peer that recently failed.
        // Checked on the primary dial path (not only reconnect/discovery) so a
        // dead peer is not hammered. Surfaced as a typed error, never silently.
        if let peerID = address.peerID, dialBackoff.shouldBackOff(from: peerID) {
            throw NodeError.dialBackedOff(peerID)
        }

        // If the address already identifies the remote peer, enforce the per-peer
        // limit before opening another transport path.
        if let peerID = address.peerID, !pool.canConnectTo(peer: peerID) {
            throw NodeError.connectionLimitReached
        }

        // Check outbound limits
        if !pool.canDialOutbound() {
            throw NodeError.connectionLimitReached
        }

        // Start new dial
        let dialTask = Task { [weak self] () throws -> PeerID in
            guard let self = self else { throw NodeError.nodeNotRunning }
            return try await self.performDial(to: address)
        }

        // Register pending dial if peer ID is known
        if let peerID = address.peerID {
            pool.registerPendingDial(dialTask, for: peerID)
        }

        do {
            let result = try await dialTask.value
            if let peerID = address.peerID {
                pool.removePendingDial(for: peerID)
            }
            return result
        } catch {
            if let peerID = address.peerID {
                pool.removePendingDial(for: peerID)
                // Record the failure so the next dial to this peer is backed
                // off. Skip on cancellation (shutdown / superseded dial) — that
                // is not a connectivity failure.
                if !(error is CancellationError) {
                    dialBackoff.recordFailure(for: peerID)
                }
            }
            emit(.outgoingConnectionError(peer: address.peerID, error: error))
            throw error
        }
    }

    /// Closes all connections to a peer and disables auto-reconnect.
    func closePeer(_ peer: PeerID) async {
        pool.disableAutoReconnect(for: peer)

        // Authoritative removal: each connection's resource is released exactly
        // once. A racing handleConnectionClosed observes `shouldReleaseResource
        // == false` (or finds the entry gone) and never double-releases.
        let removed = pool.removeReleasing(forPeer: peer)
        for removal in removed {
            let managed = removal.managed
            if let connection = managed.connection {
                await runBestEffort("close removed connection during closePeer") {
                    try await connection.close()
                }
            }
            if removal.shouldReleaseResource && managed.state.isConnected {
                configuration.connectionResources.releaseConnection(peer: peer, direction: managed.direction)
            }
        }

        if !removed.isEmpty {
            onPeerDisconnected(peer)
            emitConnectionEvent(.disconnected(peer: peer, reason: .localClose))
        }
    }

    /// Opens a new stream to a peer with the given protocol.
    func newStream(to peer: PeerID, protocol protocolID: String) async throws -> MuxedStream {
        guard isRunning else { throw NodeError.nodeNotRunning }
        guard let connection = pool.connection(to: peer) else {
            throw NodeError.notConnected(peer)
        }
        return try await configuration.streamLifecycle.openOutboundStream(
            on: connection,
            peer: peer,
            protocolID: protocolID
        )
    }

    /// Enables auto-reconnect for a peer at the given address.
    func enableAutoReconnect(for peer: PeerID, address: Multiaddr) {
        pool.enableAutoReconnect(for: peer, address: address)
    }

    /// Disables auto-reconnect for a peer.
    func disableAutoReconnect(for peer: PeerID) {
        pool.disableAutoReconnect(for: peer)
    }

    // MARK: - Private: Dial

    private func performDial(to address: Multiaddr) async throws -> PeerID {
        // Emit dialing event
        if let peerID = address.peerID {
            emit(.dialing(peerID))
        }

        // Find a driver that can dial
        guard let provider = providers.first(where: { $0.canDial(address) }) else {
            throw NodeError.noSuitableTransport
        }

        let isRelay = provider.pathKind == .relay

        // Track connecting state if peer ID is known from address
        let connectingID: ConnectionID?
        if let peerID = address.peerID {
            connectingID = pool.addConnecting(for: peerID, address: address, direction: .outbound, isLimited: isRelay)
        } else {
            connectingID = nil
        }

        // Clean up connecting entry on any failure path
        var didConnect = false
        defer {
            if !didConnect, let id = connectingID {
                pool.remove(id)
            }
        }

        let muxedConnection = try await provider.dial(
            address,
            identity: configuration.localIdentity
        )
        let remotePeer = muxedConnection.remotePeer

        // Self-connection guard (post-handshake, for addresses without embedded PeerID)
        if remotePeer == configuration.localIdentity.keyPair.peerID {
            await runBestEffort("close self-connection after handshake") {
                try await muxedConnection.close()
            }
            throw NodeError.selfDialNotAllowed
        }

        // Gating check (secured)
        if let gater = configuration.connectionGater {
            if !gater.interceptSecured(peer: remotePeer, direction: .outbound) {
                await runBestEffort("close upgraded connection rejected by secured gater") {
                    try await muxedConnection.close()
                }
                emitConnectionEvent(.gated(peer: remotePeer, address: address, stage: .secured))
                throw NodeError.connectionGated(stage: .secured)
            }
        }

        // Reserve outbound connection resource
        do {
            try configuration.connectionResources.reserveConnection(peer: remotePeer, direction: .outbound)
        } catch let error as ResourceError {
            await runBestEffort("close upgraded connection after outbound resource reservation failure") {
                try await muxedConnection.close()
            }
            switch error {
            case .limitExceeded(let scope, let resource):
                throw NodeError.resourceLimitExceeded(scope: scope, resource: resource)
            }
        }

        // Transition connecting entry to connected, or create new entry
        let connID: ConnectionID
        if let cid = connectingID {
            guard pool.activateConnectionIfPermitted(cid, connection: muxedConnection) else {
                configuration.connectionResources.releaseConnection(peer: remotePeer, direction: .outbound)
                await runBestEffort("close upgraded connection rejected by per-peer limit") {
                    try await muxedConnection.close()
                }
                throw NodeError.connectionLimitReached
            }
            connID = cid
        } else {
            guard let insertedID = pool.addIfPermitted(
                muxedConnection,
                for: remotePeer,
                address: address,
                direction: .outbound,
                isLimited: isRelay
            ) else {
                configuration.connectionResources.releaseConnection(peer: remotePeer, direction: .outbound)
                await runBestEffort("close upgraded connection rejected by per-peer limit") {
                    try await muxedConnection.close()
                }
                throw NodeError.connectionLimitReached
            }
            connID = insertedID
        }
        didConnect = true

        // Clear dial backoff on successful connection
        dialBackoff.recordSuccess(for: remotePeer)

        // Enable auto-reconnect if policy allows
        if configuration.reconnectionPolicy.enabled {
            pool.enableAutoReconnect(for: remotePeer, address: address)
        }

        // Resolve simultaneous connect before emitting events.
        await resolveSimultaneousConnect(for: remotePeer)

        // Re-check running state: shutdown may have started during the awaits
        // above. Without this, an outbound connection could go live after
        // shutdown. Release exactly once via the authoritative pool removal.
        guard isRunning else {
            if let removal = pool.removeReleasing(connID), removal.shouldReleaseResource {
                configuration.connectionResources.releaseConnection(peer: remotePeer, direction: .outbound)
            }
            await runBestEffort("close outbound connection completed during shutdown") {
                try await muxedConnection.close()
            }
            throw NodeError.nodeNotRunning
        }

        // Start handling inbound streams BEFORE onPeerConnected.
        track { swarm in
            await swarm.handleInboundStreams(connection: muxedConnection)
            await swarm.handleConnectionClosed(id: connID, peer: remotePeer)
        }

        // Emit events (guarded: only fires for first connection to this peer)
        onPeerConnected(remotePeer)
        emitConnectionEvent(.connected(peer: remotePeer, address: address, direction: .outbound))

        return remotePeer
    }

    // MARK: - Private: Accept

    private func acceptLoop(listener: any ConnectionAcceptor, address: Multiaddr) async {
        while isRunning && !Task.isCancelled {
            do {
                let candidate = try await listener.accept()

                track { swarm in
                    await swarm.handleInboundCandidate(candidate)
                }
            } catch {
                if case ConnectionAcceptorError.establishFailed(let underlying) = error {
                    emit(.connectionError(nil, underlying))
                    continue
                }
                if isRunning && !Task.isCancelled {
                    emit(.listenError(address, error))
                    continue
                }
                break
            }
        }
    }

    private func handleInboundCandidate(_ candidate: any InboundSessionCandidate) async {
        let remoteAddress = candidate.remoteAddress

        // Gating check (accept)
        if let gater = configuration.connectionGater {
            if !gater.interceptAccept(address: remoteAddress) {
                await candidate.reject()
                emitConnectionEvent(.gated(peer: nil, address: remoteAddress, stage: .accept))
                return
            }
        }

        // Check inbound limits
        if !pool.canAcceptInbound() {
            await candidate.reject()
            return
        }

        do {
            let muxedConnection = try await candidate.establish()
            await handleEstablishedInboundConnection(muxedConnection)
        } catch ConnectionAcceptorError.establishFailed(let underlying) {
            emit(.connectionError(nil, underlying))
        } catch {
            emit(.connectionError(nil, error))
        }
    }

    private func handleEstablishedInboundConnection(_ muxedConnection: any MuxedConnection) async {
        let remotePeer = muxedConnection.remotePeer
        let remoteAddress = muxedConnection.remoteAddress

        // Self-connection guard (inbound)
        if remotePeer == configuration.localIdentity.keyPair.peerID {
            await runBestEffort("close inbound self-connection") {
                try await muxedConnection.close()
            }
            return
        }

        // Gating check (secured stage)
        if let gater = configuration.connectionGater {
            if !gater.interceptSecured(peer: remotePeer, direction: .inbound) {
                await runBestEffort("close inbound connection rejected by secured gater") {
                    try await muxedConnection.close()
                }
                emitConnectionEvent(.gated(peer: remotePeer, address: remoteAddress, stage: .secured))
                return
            }
        }

        // Reserve inbound connection resource
        do {
            try configuration.connectionResources.reserveConnection(peer: remotePeer, direction: .inbound)
        } catch {
            await runBestEffort("close inbound connection after inbound resource reservation failure") {
                try await muxedConnection.close()
            }
            return
        }

        // Add to pool
        let isRelay = Self.isCircuitRelayAddress(remoteAddress)
        guard let connID = pool.addIfPermitted(
            muxedConnection,
            for: remotePeer,
            address: remoteAddress,
            direction: .inbound,
            isLimited: isRelay
        ) else {
            configuration.connectionResources.releaseConnection(peer: remotePeer, direction: .inbound)
            await runBestEffort("close inbound connection rejected by per-peer limit") {
                try await muxedConnection.close()
            }
            return
        }

        // Clear dial backoff — peer is reachable (inbound proves connectivity)
        dialBackoff.recordSuccess(for: remotePeer)

        // Resolve simultaneous connect before emitting events.
        await resolveSimultaneousConnect(for: remotePeer)

        // Re-check running state: shutdown may have started during the awaits
        // above (gating, resource reservation, simultaneous-connect resolution).
        // Without this, a connection could go live after shutdown.
        guard isRunning else {
            if let removal = pool.removeReleasing(connID), removal.shouldReleaseResource {
                configuration.connectionResources.releaseConnection(peer: remotePeer, direction: .inbound)
            }
            await runBestEffort("close inbound connection accepted during shutdown") {
                try await muxedConnection.close()
            }
            return
        }

        // Start handling inbound streams BEFORE onPeerConnected.
        track { swarm in
            await swarm.handleInboundStreams(connection: muxedConnection)
            await swarm.handleConnectionClosed(id: connID, peer: remotePeer)
        }

        // Emit events (guarded: only fires for first connection to this peer)
        onPeerConnected(remotePeer)
        emitConnectionEvent(.connected(peer: remotePeer, address: remoteAddress, direction: .inbound))
    }

    // MARK: - Private: Stream Handling

    private func handleInboundStreams(connection: MuxedConnection) async {
        let supportedProtocols = Array(handlers.keys)
        let localPeer = configuration.localIdentity.keyPair.peerID
        let rm = configuration.streamResources
        let semaphore = negotiationSemaphore

        for await stream in connection.inboundStreams {
            // Stop spawning per-stream tasks once shutdown has begun. The
            // accept/upgrade path may still deliver a stream after `isRunning`
            // flips; refusing it here prevents work after shutdown.
            guard isRunning else {
                await runBestEffort("close inbound stream after shutdown") {
                    try await stream.close()
                }
                continue
            }

            let capturedHandlers = handlers

            let remotePeer = connection.remotePeer
            let remoteAddress = connection.remoteAddress
            let localAddress = connection.localAddress

            let task = Task {
                await self.processInboundStream(
                    stream,
                    handlers: capturedHandlers,
                    supportedProtocols: supportedProtocols,
                    remotePeer: remotePeer,
                    remoteAddress: remoteAddress,
                    localPeer: localPeer,
                    localAddress: localAddress,
                    resources: rm,
                    semaphore: semaphore
                )
            }
            trackStreamTask(task)
        }
    }

    /// Negotiates a single inbound stream and dispatches it to a handler.
    ///
    /// Resource lifetime: the peer-scoped reservation taken before negotiation
    /// is upgraded to a protocol-scoped reservation once the protocol is known,
    /// and the reservation is then bound to the stream via `ResourceTrackedStream`
    /// so it is released exactly when the stream closes — matching the stream's
    /// lifetime even when the handler retains the stream beyond this task.
    private func processInboundStream(
        _ stream: MuxedStream,
        handlers capturedHandlers: [String: ProtocolHandler],
        supportedProtocols: [String],
        remotePeer: PeerID,
        remoteAddress: Multiaddr,
        localPeer: PeerID,
        localAddress: Multiaddr?,
        resources rm: any StreamResourceAccounting,
        semaphore: AsyncSemaphore
    ) async {
        // Limit concurrent inbound stream negotiations.
        await semaphore.wait()

        // Reserve inbound stream resource (peer scope; protocol is unknown until
        // negotiation completes).
        do {
            try rm.reserveStream(peer: remotePeer, direction: .inbound)
        } catch {
            semaphore.signal()
            await runBestEffort("close inbound stream after inbound stream resource reservation failure") {
                try await stream.close()
            }
            return
        }

        let context: StreamContext?
        do {
            context = try await configuration.streamLifecycle.negotiateInboundStream(
                stream,
                supportedProtocols: supportedProtocols,
                remotePeer: remotePeer,
                remoteAddress: remoteAddress,
                localPeer: localPeer,
                localAddress: localAddress
            )
        } catch {
            semaphore.signal()
            rm.releaseStream(peer: remotePeer, direction: .inbound)
            await runBestEffort("close inbound stream after negotiation failure") {
                try await stream.close()
            }
            return
        }

        // Release semaphore after negotiation completes (before handler runs).
        semaphore.signal()

        guard let context, let handler = capturedHandlers[context.protocolID] else {
            rm.releaseStream(peer: remotePeer, direction: .inbound)
            await runBestEffort("close inbound stream for unsupported protocol") {
                try await stream.close()
            }
            return
        }

        // Upgrade the peer-scoped reservation to a protocol-scoped one now that
        // the protocol is known, so per-protocol limits are enforced for inbound
        // streams too. Release the peer-scoped reservation first to avoid
        // double-counting system/peer counters.
        rm.releaseStream(peer: remotePeer, direction: .inbound)
        do {
            try rm.reserveStream(protocolID: context.protocolID, peer: remotePeer, direction: .inbound)
        } catch {
            await runBestEffort("close inbound stream after protocol resource reservation failure") {
                try await context.stream.close()
            }
            return
        }

        // Bind the protocol-scoped reservation to the stream lifetime: it is
        // released exactly once when the stream closes/resets/deinits, even if
        // the handler retains the stream beyond this task.
        let trackedStream = ResourceTrackedStream(
            stream: context.stream,
            peer: remotePeer,
            direction: .inbound,
            resourceManager: rm,
            negotiatedProtocolID: context.protocolID
        )
        let trackedContext = StreamContext(
            stream: trackedStream,
            remotePeer: context.remotePeer,
            remoteAddress: context.remoteAddress,
            localPeer: context.localPeer,
            localAddress: context.localAddress,
            protocolID: context.protocolID
        )
        await handler(trackedContext)
    }

    // MARK: - Private: Connection Close / Reconnect

    private func handleConnectionClosed(id: ConnectionID, peer: PeerID) async {
        guard let managed = pool.managedConnection(id) else { return }
        let wasConnected = managed.state.isConnected

        // Don't overwrite reconnecting state
        if case .reconnecting = managed.state {
            return
        }

        // Release connection resource exactly once. The entry is kept (it
        // transitions to .disconnected for reconnection bookkeeping), so mark
        // the reservation released under the pool lock; a racing close path
        // (closePeer / idle trim) observes the flag and does not double-release.
        if pool.markResourceReleased(id) {
            configuration.connectionResources.releaseConnection(peer: peer, direction: managed.direction)
        }

        // Update state
        pool.updateState(id, to: .disconnected(reason: .remoteClose))

        if wasConnected && !pool.isConnected(to: peer) {
            onPeerDisconnected(peer)
            emitConnectionEvent(.disconnected(peer: peer, reason: .remoteClose))

            // Reset retry count if connection was stable
            pool.resetRetryCountIfStable(id)

            // Only the peer with the smaller PeerID initiates reconnection.
            let retryCount = pool.managedConnection(id)?.retryCount ?? 0
            let reconnectAddress = pool.reconnectAddress(for: peer)
            let action = configuration.reconnectPlanner.action(
                localPeerID: configuration.localIdentity.keyPair.peerID,
                remotePeerID: peer,
                retryCount: retryCount,
                reason: .remoteClose,
                hasReconnectAddress: reconnectAddress != nil
            )

            switch action {
            case .none:
                break
            case .fail(let attempts):
                pool.updateState(id, to: .failed(reason: .remoteClose))
                emitConnectionEvent(.reconnectionFailed(peer: peer, attempts: attempts))
            case .schedule(let attempt, let delay):
                guard let address = reconnectAddress else { break }
                await scheduleReconnect(id: id, peer: peer, address: address, attempt: attempt, delay: delay)
            }
        }
    }

    private func scheduleReconnect(
        id: ConnectionID,
        peer: PeerID,
        address: Multiaddr,
        attempt: Int,
        delay: Duration
    ) async {
        let nextAttempt = ContinuousClock.now + delay

        pool.updateState(id, to: .reconnecting(attempt: attempt, nextAttempt: nextAttempt))
        pool.incrementRetryCount(id)
        emitConnectionEvent(.reconnecting(peer: peer, attempt: attempt, nextDelay: delay))

        track { swarm in
            let slept = await sleepUnlessCancelled(
                for: delay,
                context: "reconnect backoff for peer \(peer)"
            )
            guard slept else { return }
            await swarm.performReconnect(id: id, peer: peer, address: address, attempt: attempt)
        }
    }

    private func performReconnect(id: ConnectionID, peer: PeerID, address: Multiaddr, attempt: Int) async {
        guard isRunning else { return }
        guard pool.reconnectAddress(for: peer) != nil else { return }

        // Skip if already connected (another path may have succeeded)
        guard !pool.isConnected(to: peer) else { return }

        do {
            guard let provider = providers.first(where: { $0.canDial(address) }) else {
                throw NodeError.noSuitableTransport
            }

            let muxedConnection = try await provider.dial(
                address,
                identity: configuration.localIdentity
            )
            let remotePeer = muxedConnection.remotePeer

            guard remotePeer == peer else {
                await runBestEffort("close reconnected connection after peer mismatch") {
                    try await muxedConnection.close()
                }
                throw NodeError.notConnected(peer)
            }

            // Gating check (secured)
            if let gater = configuration.connectionGater {
                if !gater.interceptSecured(peer: remotePeer, direction: .outbound) {
                    await runBestEffort("close reconnected connection rejected by secured gater") {
                        try await muxedConnection.close()
                    }
                    emitConnectionEvent(.gated(peer: remotePeer, address: address, stage: .secured))
                    throw NodeError.connectionGated(stage: .secured)
                }
            }

            // Reserve outbound connection resource
            do {
                try configuration.connectionResources.reserveConnection(peer: peer, direction: .outbound)
            } catch let error as ResourceError {
                await runBestEffort("close reconnected connection after outbound resource reservation failure") {
                    try await muxedConnection.close()
                }
                switch error {
                case .limitExceeded(let scope, let resource):
                    throw NodeError.resourceLimitExceeded(scope: scope, resource: resource)
                }
            }

            guard pool.activateConnectionIfPermitted(id, connection: muxedConnection) else {
                configuration.connectionResources.releaseConnection(peer: remotePeer, direction: .outbound)
                await runBestEffort("close reconnected connection rejected by per-peer limit") {
                    try await muxedConnection.close()
                }
                throw NodeError.connectionLimitReached
            }
            pool.resetRetryCount(id)

            dialBackoff.recordSuccess(for: remotePeer)

            await resolveSimultaneousConnect(for: remotePeer)

            track { swarm in
                await swarm.handleInboundStreams(connection: muxedConnection)
                await swarm.handleConnectionClosed(id: id, peer: remotePeer)
            }

            onPeerConnected(remotePeer)
            emitConnectionEvent(.reconnected(peer: peer, attempt: attempt))

        } catch {
            dialBackoff.recordFailure(for: peer)

            let errorCode: DisconnectErrorCode = if error is NegotiationError {
                .protocolError
            } else {
                .transportError
            }
            let reason: DisconnectReason = .error(code: errorCode, message: error.localizedDescription)

            let retryCount = pool.managedConnection(id)?.retryCount ?? attempt
            let action = configuration.reconnectPlanner.action(
                localPeerID: configuration.localIdentity.keyPair.peerID,
                remotePeerID: peer,
                retryCount: retryCount,
                reason: reason,
                hasReconnectAddress: true
            )

            switch action {
            case .schedule(let nextAttempt, let delay):
                await scheduleReconnect(id: id, peer: peer, address: address, attempt: nextAttempt, delay: delay)
            case .fail(let attempts):
                pool.updateState(id, to: .failed(reason: reason))
                emitConnectionEvent(.reconnectionFailed(peer: peer, attempts: attempts))
            case .none:
                pool.updateState(id, to: .failed(reason: reason))
                emitConnectionEvent(.reconnectionFailed(peer: peer, attempts: retryCount))
            }
        }
    }

    // MARK: - Private: Simultaneous Connect Resolution

    private func resolveSimultaneousConnect(for peer: PeerID) async {
        let connections = pool.connectedManagedConnections(for: peer)
        let losers = configuration.conflictResolver.duplicateConnections(
            from: connections,
            localPeerID: configuration.localIdentity.keyPair.peerID,
            remotePeerID: peer
        )
        guard !losers.isEmpty else { return }

        // Close and remove losers (authoritative removal: release exactly once)
        for loser in losers {
            if let removal = pool.removeReleasing(loser.id), removal.shouldReleaseResource {
                configuration.connectionResources.releaseConnection(peer: loser.peer, direction: loser.direction)
            }
            if let conn = loser.connection {
                await runBestEffort("close duplicate connection in simultaneous connect resolution") {
                    try await conn.close()
                }
            }
        }
    }

    // MARK: - Private: Idle Check

    private func startIdleCheckTask() {
        let idleTimeout = configuration.idleTimeout
        guard idleTimeout > .zero else { return }

        idleCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                let slept = await sleepUnlessCancelled(
                    for: idleTimeout / 2,
                    context: "idle check interval"
                )
                guard slept else { break }
                await self?.performIdleCheck()
            }
        }
    }

    private func performIdleCheck() async {
        let idleTimeout = configuration.idleTimeout

        // 1. Close idle connections.
        // Remove from the pool FIRST (authoritative, under the lock) so a racing
        // handleConnectionClosed observes the entry gone / already-released and
        // cannot double-release during the subsequent `await close`.
        let idleConnections = pool.idleConnections(threshold: idleTimeout)
        for managed in idleConnections {
            guard let removal = pool.removeReleasing(managed.id) else { continue }
            if removal.shouldReleaseResource {
                configuration.connectionResources.releaseConnection(peer: managed.peer, direction: managed.direction)
            }
            if let connection = removal.managed.connection {
                await runBestEffort("close idle connection during idle check") {
                    try await connection.close()
                }
            }
            if !pool.isConnected(to: managed.peer) {
                onPeerDisconnected(managed.peer)
                emitConnectionEvent(.disconnected(peer: managed.peer, reason: .idleTimeout))
            }
        }

        // 2. Trim if over limits.
        // Compute-and-apply atomically under a single lock so the report
        // describes exactly the connections that were trimmed (no TOCTOU gap
        // between a separate report and apply).
        let trimOutcome = pool.trimReleasing()
        let trimReport = trimOutcome.report
        if trimReport.requiresTrim && trimReport.selectedCount < trimReport.targetTrimCount {
            emitConnectionEvent(
                .trimConstrained(
                    target: trimReport.targetTrimCount,
                    selected: trimReport.selectedCount,
                    trimmable: trimReport.trimmableCount,
                    active: trimReport.activeConnectionCount
                )
            )
            swarmLogger.warning(
                """
                Connection trim constrained: target=\(trimReport.targetTrimCount), \
                selected=\(trimReport.selectedCount), trimmable=\(trimReport.trimmableCount), \
                active=\(trimReport.activeConnectionCount)
                """
            )
        }
        let trimContextsByID: [ConnectionID: ConnectionTrimmedContext] = Dictionary(
            uniqueKeysWithValues: trimReport.candidates.compactMap { candidate -> (ConnectionID, ConnectionTrimmedContext)? in
                guard candidate.selectedForTrim else { return nil }
                return (candidate.id, Self.trimContext(for: candidate))
            }
        )

        for removal in trimOutcome.removed {
            let managed = removal.managed
            if removal.shouldReleaseResource {
                configuration.connectionResources.releaseConnection(peer: managed.peer, direction: managed.direction)
            }
            if let connection = managed.connection {
                await runBestEffort("close trimmed connection during idle check") {
                    try await connection.close()
                }
            }
            if !pool.isConnected(to: managed.peer) {
                onPeerDisconnected(managed.peer)
                if let context = trimContextsByID[managed.id] {
                    emitConnectionEvent(.trimmedWithContext(peer: managed.peer, context: context))
                } else {
                    emitConnectionEvent(.trimmed(peer: managed.peer, reason: "Connection limit exceeded"))
                }
            }
        }

        // 3. Cleanup stale entries
        _ = pool.cleanupStaleEntries(disconnectedThreshold: idleTimeout)

        // 4. Cleanup expired dial backoff entries
        dialBackoff.cleanup()
    }

    private static func trimContext(for candidate: ConnectionTrimReport.Candidate) -> ConnectionTrimmedContext {
        ConnectionTrimmedContext(
            rank: candidate.trimRank,
            tagCount: candidate.tagCount,
            idleDuration: candidate.idleDuration,
            direction: candidate.direction
        )
    }

    // MARK: - Private: Task Tracking

    /// Spawns a tracked actor-isolated task that self-removes on completion and
    /// is cancelled at shutdown. The token is reserved synchronously so the task
    /// can deregister itself even if it finishes before this method returns.
    @discardableResult
    private func track(_ operation: @escaping @Sendable (isolated Swarm) async -> Void) -> Task<Void, Never> {
        let token = nextTaskToken
        nextTaskToken &+= 1
        let task = Task { [weak self] in
            guard let self else { return }
            await operation(self)
            await self.untrack(token)
        }
        trackedTasks[token] = task
        return task
    }

    private func untrack(_ token: UInt64) {
        trackedTasks.removeValue(forKey: token)
    }

    /// Registers an already-created stream-negotiation task for tracking and
    /// self-removal. Used by the inbound-stream loop, which builds the task in
    /// the synchronous `for await` body.
    private func trackStreamTask(_ task: Task<Void, Never>) {
        let token = nextTaskToken
        nextTaskToken &+= 1
        trackedTasks[token] = task
        // Self-remove once the task completes (hop back onto the actor).
        Task { [weak self] in
            await task.value
            await self?.untrack(token)
        }
    }

    // MARK: - Private: Event Helpers

    private func onPeerConnected(_ peer: PeerID) {
        guard !peerConnectedEmitted.contains(peer) else { return }
        peerConnectedEmitted.insert(peer)
        emit(.peerConnected(peer))
    }

    private func onPeerDisconnected(_ peer: PeerID) {
        guard !pool.isConnected(to: peer) else { return }
        peerConnectedEmitted.remove(peer)
        emit(.peerDisconnected(peer))
    }

    private func emit(_ event: SwarmEvent) {
        broadcaster.emit(event)
    }

    private func emitConnectionEvent(_ event: ConnectionEvent) {
        broadcaster.emit(.connection(event))
    }

    // MARK: - Private: Address Resolution

    static func resolveUnspecifiedAddresses(_ boundAddresses: [Multiaddr]) -> [Multiaddr] {
        var result: [Multiaddr] = []
        let interfaceIPs = getInterfaceAddresses()

        for addr in boundAddresses {
            guard addr.isUnspecifiedIP else {
                result.append(addr)
                continue
            }

            let isIPv6 = addr.protocols.contains { if case .ip6 = $0 { return true }; return false }

            let matchingIPs = interfaceIPs.filter { ip in
                if isIPv6 {
                    return ip.contains(":")
                } else {
                    return !ip.contains(":")
                }
            }

            for ip in matchingIPs {
                result.append(addr.replacingIPAddress(ip))
            }
        }

        return result
    }

    private static func getInterfaceAddresses() -> [String] {
        var addresses: [String] = []
        var hasNonLoopback = false

        var ifaddrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrs) == 0, let firstAddr = ifaddrs else {
            return ["127.0.0.1"]
        }
        defer { freeifaddrs(firstAddr) }

        var current: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let addr = current {
            let interface = addr.pointee
            let family = interface.ifa_addr.pointee.sa_family

            if family == sa_family_t(AF_INET) {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                #if canImport(Darwin)
                let addrLen = socklen_t(interface.ifa_addr.pointee.sa_len)
                #else
                let addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                #endif
                getnameinfo(
                    interface.ifa_addr, addrLen,
                    &hostname, socklen_t(hostname.count),
                    nil, 0, NI_NUMERICHOST
                )
                let ip: String = hostname.withUnsafeBufferPointer { buf in
                    let len = buf.firstIndex(of: 0) ?? buf.count
                    return String(decoding: buf[..<len].lazy.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                }

                if ip == "127.0.0.1" {
                    addresses.append(ip)
                } else if !ip.isEmpty {
                    addresses.insert(ip, at: hasNonLoopback ? 1 : 0)
                    hasNonLoopback = true
                }
            }

            current = interface.ifa_next
        }

        if addresses.isEmpty {
            addresses.append("127.0.0.1")
        }
        return addresses
    }

    // MARK: - Private: Utility

    private static func isCircuitRelayAddress(_ addr: Multiaddr) -> Bool {
        addr.protocols.contains { if case .p2pCircuit = $0 { return true }; return false }
    }
}
