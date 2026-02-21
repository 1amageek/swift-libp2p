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

    private let upgrader: ConnectionUpgrader
    private nonisolated let broadcaster = EventBroadcaster<SwarmEvent>()
    private nonisolated let negotiationSemaphore: AsyncSemaphore

    // Listeners
    private var listeners: [any Listener] = []
    private var securedListeners: [any SecuredListener] = []

    // Protocol handlers
    private var handlers: [String: ProtocolHandler] = [:]

    // State
    private var isRunning = false

    // Background tasks
    private var idleCheckTask: Task<Void, Never>?
    private var reconnectTasks: [Task<Void, Never>] = []
    private var acceptTasks: [Task<Void, Never>] = []

    // Peer-connected dedup tracking
    private var peerConnectedEmitted: Set<PeerID> = []

    // MARK: - Init

    init(configuration: SwarmConfiguration) {
        self.configuration = configuration
        self.upgrader = NegotiatingUpgrader(
            security: configuration.security,
            muxers: configuration.muxers
        )
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
        for address in configuration.listenAddresses {
            for transport in configuration.transports {
                if transport.canListen(address) {
                    do {
                        if let securedTransport = transport as? SecuredTransport {
                            let listener = try await securedTransport.listenSecured(
                                address,
                                localKeyPair: configuration.keyPair
                            )
                            securedListeners.append(listener)
                            emit(.newListenAddr(listener.localAddress))

                            let acceptTask = Task { [weak self] in
                                guard let self else { return }
                                await self.securedAcceptLoop(listener: listener, address: listener.localAddress)
                            }
                            acceptTasks.append(acceptTask)
                        } else {
                            let listener = try await transport.listen(address)
                            listeners.append(listener)
                            emit(.newListenAddr(listener.localAddress))

                            let acceptTask = Task { [weak self] in
                                guard let self else { return }
                                await self.acceptLoop(listener: listener, address: address)
                            }
                            acceptTasks.append(acceptTask)
                        }
                    } catch {
                        emit(.listenError(address, error))
                    }
                }
            }
        }

        // Fail if no listeners could bind and we had addresses to listen on
        if listeners.isEmpty && securedListeners.isEmpty && !configuration.listenAddresses.isEmpty {
            throw NodeError.noListenersBound
        }

        // Update current listen addresses for synchronous access
        let boundAddresses = listeners.map(\.localAddress) + securedListeners.map(\.localAddress)
        listenAddresses.update(boundAddresses)

        // Resolve unspecified addresses (0.0.0.0 / ::) to actual interface IPs
        let resolved = Self.resolveUnspecifiedAddresses(boundAddresses)
        advertisedAddresses.update(resolved)
    }

    /// Shuts down the swarm: cancel tasks, close listeners, close connections.
    func shutdown() async {
        isRunning = false

        // Cancel accept loops first so listeners can close cleanly
        for task in acceptTasks { task.cancel() }
        acceptTasks.removeAll()

        // Cancel background tasks
        idleCheckTask?.cancel()
        idleCheckTask = nil
        for task in reconnectTasks { task.cancel() }
        reconnectTasks.removeAll()

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

        // Close all secured listeners (QUIC, etc.)
        for listener in securedListeners {
            emit(.expiredListenAddr(listener.localAddress))
            do {
                try await listener.close()
            } catch {
                swarmLogger.debug("Failed to close secured listener: \(error)")
            }
        }
        securedListeners.removeAll()

        // Close all connections
        for peer in pool.connectedPeers {
            let removed = pool.remove(forPeer: peer)
            for managed in removed {
                do {
                    try await managed.connection?.close()
                } catch {
                    swarmLogger.debug("Failed to close connection to \(peer): \(error)")
                }
                if managed.state.isConnected {
                    configuration.resourceManager?.releaseConnection(peer: peer, direction: managed.direction)
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
        // Self-connection guard
        let localPeerID = configuration.keyPair.peerID
        if let targetPeer = address.peerID, targetPeer == localPeerID {
            throw NodeError.selfDialNotAllowed
        }

        // Gating check (dial)
        if let gater = configuration.pool.gater {
            if !gater.interceptDial(peer: address.peerID, address: address) {
                emitConnectionEvent(.gated(peer: address.peerID, address: address, stage: .dial))
                throw NodeError.connectionGated(stage: .dial)
            }
        }

        // Check for pending dial to same peer (join existing)
        if let peerID = address.peerID, let pendingTask = pool.pendingDial(to: peerID) {
            return try await pendingTask.value
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
            }
            emit(.outgoingConnectionError(peer: address.peerID, error: error))
            throw error
        }
    }

    /// Closes all connections to a peer and disables auto-reconnect.
    func closePeer(_ peer: PeerID) async {
        pool.disableAutoReconnect(for: peer)

        let removed = pool.remove(forPeer: peer)
        for managed in removed {
            if let connection = managed.connection {
                await runBestEffort("close removed connection during closePeer") {
                    try await connection.close()
                }
            }
            if managed.state.isConnected {
                configuration.resourceManager?.releaseConnection(peer: peer, direction: managed.direction)
            }
        }

        if !removed.isEmpty {
            onPeerDisconnected(peer)
            emitConnectionEvent(.disconnected(peer: peer, reason: .localClose))
        }
    }

    /// Opens a new stream to a peer with the given protocol.
    func newStream(to peer: PeerID, protocol protocolID: String) async throws -> MuxedStream {
        guard let connection = pool.connection(to: peer) else {
            throw NodeError.notConnected(peer)
        }

        // Reserve outbound stream resource
        if let rm = configuration.resourceManager {
            do {
                try rm.reserveOutboundStream(to: peer)
            } catch let error as ResourceError {
                switch error {
                case .limitExceeded(let scope, let resource):
                    throw NodeError.resourceLimitExceeded(scope: scope, resource: resource)
                }
            }
        }

        let stream: MuxedStream
        do {
            stream = try await connection.newStream()
        } catch {
            configuration.resourceManager?.releaseStream(peer: peer, direction: .outbound)
            throw error
        }

        // Negotiate protocol using multistream-select
        let reader = BufferedStreamReader(stream: stream)
        let result: NegotiationResult
        do {
            result = try await MultistreamSelect.negotiate(
                protocols: [protocolID],
                read: { try await reader.readMessage() },
                write: { try await stream.write(ByteBuffer(bytes: $0)) }
            )
        } catch {
            configuration.resourceManager?.releaseStream(peer: peer, direction: .outbound)
            await runBestEffort("close outbound stream after protocol negotiation failure") {
                try await stream.close()
            }
            throw error
        }

        if result.protocolID != protocolID {
            configuration.resourceManager?.releaseStream(peer: peer, direction: .outbound)
            await runBestEffort("close outbound stream after protocol mismatch") {
                try await stream.close()
            }
            throw NodeError.protocolNegotiationFailed
        }

        // Preserve bytes that were read ahead during protocol negotiation.
        let bufferedRemainder = reader.drainRemainder()
        let negotiationRemainder = result.remainder + bufferedRemainder
        let negotiatedStream: MuxedStream
        if negotiationRemainder.isEmpty {
            negotiatedStream = stream
        } else {
            negotiatedStream = BufferedMuxedStream(stream: stream, initialBuffer: negotiationRemainder)
        }

        // Wrap stream with resource tracking if resource manager is configured
        if let rm = configuration.resourceManager {
            return ResourceTrackedStream(
                stream: negotiatedStream,
                peer: peer,
                direction: .outbound,
                resourceManager: rm
            )
        }
        return negotiatedStream
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

        // Find a transport that can dial
        guard let transport = configuration.transports.first(where: { $0.canDial(address) }) else {
            throw NodeError.noSuitableTransport
        }

        let isRelay = transport.pathKind == .relay

        // SecuredTransport (e.g., QUIC) bypasses the upgrade pipeline
        if let securedTransport = transport as? SecuredTransport {
            return try await performSecuredDial(to: address, using: securedTransport, isLimited: isRelay)
        }

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

        // Standard transport: dial then upgrade
        let rawConnection = try await transport.dial(address)

        // Upgrade connection (security + muxer negotiation)
        let result: UpgradeResult
        do {
            result = try await upgrader.upgrade(
                rawConnection,
                localKeyPair: configuration.keyPair,
                role: .initiator,
                expectedPeer: address.peerID
            )
        } catch {
            await runBestEffort("close raw connection after upgrade failure") {
                try await rawConnection.close()
            }
            throw error
        }

        let remotePeer = result.connection.remotePeer

        // Self-connection guard (post-handshake, for addresses without embedded PeerID)
        if remotePeer == configuration.keyPair.peerID {
            await runBestEffort("close self-connection after handshake") {
                try await result.connection.close()
            }
            throw NodeError.selfDialNotAllowed
        }

        // Gating check (secured)
        if let gater = configuration.pool.gater {
            if !gater.interceptSecured(peer: remotePeer, direction: .outbound) {
                await runBestEffort("close upgraded connection rejected by secured gater") {
                    try await result.connection.close()
                }
                emitConnectionEvent(.gated(peer: remotePeer, address: address, stage: .secured))
                throw NodeError.connectionGated(stage: .secured)
            }
        }

        // Check per-peer limit
        if !pool.canConnectTo(peer: remotePeer) {
            await runBestEffort("close upgraded connection rejected by per-peer limit") {
                try await result.connection.close()
            }
            throw NodeError.connectionLimitReached
        }

        // Reserve outbound connection resource
        if let rm = configuration.resourceManager {
            do {
                try rm.reserveOutboundConnection(to: remotePeer)
            } catch let error as ResourceError {
                await runBestEffort("close upgraded connection after outbound resource reservation failure") {
                    try await result.connection.close()
                }
                switch error {
                case .limitExceeded(let scope, let resource):
                    throw NodeError.resourceLimitExceeded(scope: scope, resource: resource)
                }
            }
        }

        // Transition connecting entry to connected, or create new entry
        let connID: ConnectionID
        if let cid = connectingID {
            pool.updateConnection(cid, connection: result.connection)
            connID = cid
        } else {
            connID = pool.add(
                result.connection,
                for: remotePeer,
                address: address,
                direction: .outbound,
                isLimited: isRelay
            )
        }
        didConnect = true

        // Clear dial backoff on successful connection
        dialBackoff.recordSuccess(for: remotePeer)

        // Enable auto-reconnect if policy allows
        if configuration.pool.reconnectionPolicy.enabled {
            pool.enableAutoReconnect(for: remotePeer, address: address)
        }

        // Resolve simultaneous connect before emitting events.
        await resolveSimultaneousConnect(for: remotePeer)

        // Start handling inbound streams BEFORE onPeerConnected.
        Task { [weak self] in
            await self?.handleInboundStreams(connection: result.connection)
            await self?.handleConnectionClosed(id: connID, peer: remotePeer)
        }

        // Emit events (guarded: only fires for first connection to this peer)
        onPeerConnected(remotePeer)
        emitConnectionEvent(.connected(peer: remotePeer, address: address, direction: .outbound))

        return remotePeer
    }

    private func performSecuredDial(
        to address: Multiaddr,
        using transport: SecuredTransport,
        isLimited: Bool = false
    ) async throws -> PeerID {
        // Track connecting state if peer ID is known from address
        let connectingID: ConnectionID?
        if let peerID = address.peerID {
            connectingID = pool.addConnecting(for: peerID, address: address, direction: .outbound, isLimited: isLimited)
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

        // SecuredTransport returns MuxedConnection directly
        let muxedConnection = try await transport.dialSecured(
            address,
            localKeyPair: configuration.keyPair
        )

        let remotePeer = muxedConnection.remotePeer

        // Self-connection guard (post-handshake)
        if remotePeer == configuration.keyPair.peerID {
            await runBestEffort("close self-connection after secured handshake") {
                try await muxedConnection.close()
            }
            throw NodeError.selfDialNotAllowed
        }

        // Gating check (secured stage)
        if let gater = configuration.pool.gater {
            if !gater.interceptSecured(peer: remotePeer, direction: .outbound) {
                await runBestEffort("close secured dial connection rejected by secured gater") {
                    try await muxedConnection.close()
                }
                emitConnectionEvent(.gated(peer: remotePeer, address: address, stage: .secured))
                throw NodeError.connectionGated(stage: .secured)
            }
        }

        // Check per-peer limit
        if !pool.canConnectTo(peer: remotePeer) {
            await runBestEffort("close secured dial connection rejected by per-peer limit") {
                try await muxedConnection.close()
            }
            throw NodeError.connectionLimitReached
        }

        // Reserve outbound connection resource
        if let rm = configuration.resourceManager {
            do {
                try rm.reserveOutboundConnection(to: remotePeer)
            } catch let error as ResourceError {
                await runBestEffort("close secured dial connection after outbound resource reservation failure") {
                    try await muxedConnection.close()
                }
                switch error {
                case .limitExceeded(let scope, let resource):
                    throw NodeError.resourceLimitExceeded(scope: scope, resource: resource)
                }
            }
        }

        // Transition connecting entry to connected, or create new entry
        let connID: ConnectionID
        if let cid = connectingID {
            pool.updateConnection(cid, connection: muxedConnection)
            connID = cid
        } else {
            connID = pool.add(
                muxedConnection,
                for: remotePeer,
                address: address,
                direction: .outbound,
                isLimited: isLimited
            )
        }
        didConnect = true

        // Clear dial backoff on successful connection
        dialBackoff.recordSuccess(for: remotePeer)

        // Enable auto-reconnect if policy allows
        if configuration.pool.reconnectionPolicy.enabled {
            pool.enableAutoReconnect(for: remotePeer, address: address)
        }

        // Resolve simultaneous connect before emitting events.
        await resolveSimultaneousConnect(for: remotePeer)

        // Start handling inbound streams BEFORE onPeerConnected.
        Task { [weak self] in
            await self?.handleInboundStreams(connection: muxedConnection)
            await self?.handleConnectionClosed(id: connID, peer: remotePeer)
        }

        // Emit events (guarded: only fires for first connection to this peer)
        onPeerConnected(remotePeer)
        emitConnectionEvent(.connected(peer: remotePeer, address: address, direction: .outbound))

        return remotePeer
    }

    // MARK: - Private: Accept

    private func acceptLoop(listener: any Listener, address: Multiaddr) async {
        while isRunning && !Task.isCancelled {
            do {
                let rawConnection = try await listener.accept()

                Task { [weak self] in
                    await self?.handleInboundConnection(rawConnection)
                }
            } catch {
                if isRunning && !Task.isCancelled {
                    emit(.listenError(address, error))
                    continue
                }
                break
            }
        }
    }

    private func securedAcceptLoop(listener: any SecuredListener, address: Multiaddr) async {
        for await muxedConnection in listener.connections {
            guard isRunning && !Task.isCancelled else { break }
            Task { [weak self] in
                await self?.handleSecuredInboundConnection(muxedConnection, from: address)
            }
        }
    }

    private func handleInboundConnection(_ rawConnection: any RawConnection) async {
        // Gating check (accept)
        if let gater = configuration.pool.gater {
            let remoteAddress = rawConnection.remoteAddress
            if !gater.interceptAccept(address: remoteAddress) {
                await runBestEffort("close inbound raw connection rejected by accept gater") {
                    try await rawConnection.close()
                }
                emitConnectionEvent(.gated(peer: nil, address: remoteAddress, stage: .accept))
                return
            }
        }

        // Check inbound limits
        if !pool.canAcceptInbound() {
            await runBestEffort("close inbound raw connection rejected by inbound limit") {
                try await rawConnection.close()
            }
            return
        }

        do {
            // Upgrade connection (security + muxer negotiation)
            let result: UpgradeResult
            do {
                result = try await upgrader.upgrade(
                    rawConnection,
                    localKeyPair: configuration.keyPair,
                    role: .responder,
                    expectedPeer: nil
                )
            } catch {
                await runBestEffort("close inbound raw connection after upgrade failure") {
                    try await rawConnection.close()
                }
                throw error
            }

            let remotePeer = result.connection.remotePeer
            let remoteAddress = result.connection.remoteAddress

            // Self-connection guard (inbound)
            if remotePeer == configuration.keyPair.peerID {
                await runBestEffort("close inbound self-connection") {
                    try await result.connection.close()
                }
                return
            }

            // Gating check (secured)
            if let gater = configuration.pool.gater {
                if !gater.interceptSecured(peer: remotePeer, direction: .inbound) {
                    await runBestEffort("close inbound upgraded connection rejected by secured gater") {
                        try await result.connection.close()
                    }
                    emitConnectionEvent(.gated(peer: remotePeer, address: remoteAddress, stage: .secured))
                    return
                }
            }

            // Check per-peer limit
            if !pool.canConnectTo(peer: remotePeer) {
                await runBestEffort("close inbound upgraded connection rejected by per-peer limit") {
                    try await result.connection.close()
                }
                return
            }

            // Reserve inbound connection resource
            if let rm = configuration.resourceManager {
                do {
                    try rm.reserveInboundConnection(from: remotePeer)
                } catch {
                    await runBestEffort("close inbound upgraded connection after inbound resource reservation failure") {
                        try await result.connection.close()
                    }
                    return
                }
            }

            // Add to pool
            let isRelay = Self.isCircuitRelayAddress(remoteAddress)
            let connID = pool.add(
                result.connection,
                for: remotePeer,
                address: remoteAddress,
                direction: .inbound,
                isLimited: isRelay
            )

            // Clear dial backoff — peer is reachable (inbound proves connectivity)
            dialBackoff.recordSuccess(for: remotePeer)

            // Resolve simultaneous connect before emitting events.
            await resolveSimultaneousConnect(for: remotePeer)

            // Start handling inbound streams BEFORE onPeerConnected.
            Task { [weak self] in
                await self?.handleInboundStreams(connection: result.connection)
                await self?.handleConnectionClosed(id: connID, peer: remotePeer)
            }

            // Emit events (guarded: only fires for first connection to this peer)
            onPeerConnected(remotePeer)
            emitConnectionEvent(.connected(peer: remotePeer, address: remoteAddress, direction: .inbound))

        } catch {
            emit(.connectionError(nil, error))
        }
    }

    private func handleSecuredInboundConnection(
        _ muxedConnection: any MuxedConnection,
        from address: Multiaddr
    ) async {
        let remotePeer = muxedConnection.remotePeer
        let remoteAddress = muxedConnection.remoteAddress

        // Gating check (accept stage)
        if let gater = configuration.pool.gater {
            if !gater.interceptAccept(address: remoteAddress) {
                await runBestEffort("close secured inbound connection rejected by accept gater") {
                    try await muxedConnection.close()
                }
                emitConnectionEvent(.gated(peer: nil, address: remoteAddress, stage: .accept))
                return
            }
        }

        // Check inbound limits
        if !pool.canAcceptInbound() {
            await runBestEffort("close secured inbound connection rejected by inbound limit") {
                try await muxedConnection.close()
            }
            return
        }

        // Self-connection guard (secured inbound)
        if remotePeer == configuration.keyPair.peerID {
            await runBestEffort("close secured inbound self-connection") {
                try await muxedConnection.close()
            }
            return
        }

        // Gating check (secured stage)
        if let gater = configuration.pool.gater {
            if !gater.interceptSecured(peer: remotePeer, direction: .inbound) {
                await runBestEffort("close secured inbound connection rejected by secured gater") {
                    try await muxedConnection.close()
                }
                emitConnectionEvent(.gated(peer: remotePeer, address: remoteAddress, stage: .secured))
                return
            }
        }

        // Check per-peer limit
        if !pool.canConnectTo(peer: remotePeer) {
            await runBestEffort("close secured inbound connection rejected by per-peer limit") {
                try await muxedConnection.close()
            }
            return
        }

        // Reserve inbound connection resource
        if let rm = configuration.resourceManager {
            do {
                try rm.reserveInboundConnection(from: remotePeer)
            } catch {
                await runBestEffort("close secured inbound connection after inbound resource reservation failure") {
                    try await muxedConnection.close()
                }
                return
            }
        }

        // Add to pool
        let isRelay = Self.isCircuitRelayAddress(remoteAddress)
        let connID = pool.add(
            muxedConnection,
            for: remotePeer,
            address: remoteAddress,
            direction: .inbound,
            isLimited: isRelay
        )

        // Clear dial backoff — peer is reachable (inbound proves connectivity)
        dialBackoff.recordSuccess(for: remotePeer)

        // Resolve simultaneous connect before emitting events.
        await resolveSimultaneousConnect(for: remotePeer)

        // Start handling inbound streams BEFORE onPeerConnected.
        Task { [weak self] in
            await self?.handleInboundStreams(connection: muxedConnection)
            await self?.handleConnectionClosed(id: connID, peer: remotePeer)
        }

        // Emit events (guarded: only fires for first connection to this peer)
        onPeerConnected(remotePeer)
        emitConnectionEvent(.connected(peer: remotePeer, address: remoteAddress, direction: .inbound))
    }

    // MARK: - Private: Stream Handling

    private func handleInboundStreams(connection: MuxedConnection) async {
        let supportedProtocols = Array(handlers.keys)
        let localPeer = configuration.keyPair.peerID
        let rm = configuration.resourceManager
        let semaphore = negotiationSemaphore

        for await stream in connection.inboundStreams {
            let capturedHandlers = handlers

            let remotePeer = connection.remotePeer
            let remoteAddress = connection.remoteAddress
            let localAddress = connection.localAddress

            Task {
                // Limit concurrent inbound stream negotiations
                await semaphore.wait()

                // Reserve inbound stream resource
                if let rm = rm {
                    do {
                        try rm.reserveInboundStream(from: remotePeer)
                    } catch {
                        semaphore.signal()
                        await runBestEffort("close inbound stream after inbound stream resource reservation failure") {
                            try await stream.close()
                        }
                        return
                    }
                }

                defer {
                    rm?.releaseStream(peer: remotePeer, direction: .inbound)
                }

                do {
                    let reader = BufferedStreamReader(stream: stream)
                    let result = try await MultistreamSelect.handle(
                        supported: supportedProtocols,
                        read: { try await reader.readMessage() },
                        write: { try await stream.write(ByteBuffer(bytes: $0)) }
                    )

                    // Release semaphore after negotiation completes (before handler runs)
                    semaphore.signal()

                    // Preserve bytes read ahead during protocol negotiation.
                    let bufferedRemainder = reader.drainRemainder()
                    let negotiationRemainder = result.remainder + bufferedRemainder
                    let negotiatedStream: MuxedStream
                    if negotiationRemainder.isEmpty {
                        negotiatedStream = stream
                    } else {
                        negotiatedStream = BufferedMuxedStream(stream: stream, initialBuffer: negotiationRemainder)
                    }

                    if let handler = capturedHandlers[result.protocolID] {
                        let context = StreamContext(
                            stream: negotiatedStream,
                            remotePeer: remotePeer,
                            remoteAddress: remoteAddress,
                            localPeer: localPeer,
                            localAddress: localAddress,
                            protocolID: result.protocolID
                        )
                        await handler(context)
                    } else {
                        await runBestEffort("close inbound stream for unsupported protocol") {
                            try await stream.close()
                        }
                    }
                } catch {
                    semaphore.signal()
                    await runBestEffort("close inbound stream after handler failure") {
                        try await stream.close()
                    }
                }
            }
        }
    }

    // MARK: - Private: Connection Close / Reconnect

    private func handleConnectionClosed(id: ConnectionID, peer: PeerID) async {
        guard let managed = pool.managedConnection(id) else { return }
        let wasConnected = managed.state.isConnected

        // Don't overwrite reconnecting state
        if case .reconnecting = managed.state {
            return
        }

        // Release connection resource
        configuration.resourceManager?.releaseConnection(peer: peer, direction: managed.direction)

        // Update state
        pool.updateState(id, to: .disconnected(reason: .remoteClose))

        if wasConnected && !pool.isConnected(to: peer) {
            onPeerDisconnected(peer)
            emitConnectionEvent(.disconnected(peer: peer, reason: .remoteClose))

            // Reset retry count if connection was stable
            pool.resetRetryCountIfStable(id)

            // Only the peer with the smaller PeerID initiates reconnection.
            let localPeerID = configuration.keyPair.peerID
            if let address = pool.reconnectAddress(for: peer), localPeerID < peer {
                let retryCount = pool.managedConnection(id)?.retryCount ?? 0
                let policy = configuration.pool.reconnectionPolicy

                if policy.shouldReconnect(attempt: retryCount, reason: .remoteClose) {
                    await scheduleReconnect(id: id, peer: peer, address: address, attempt: retryCount + 1)
                } else if retryCount >= policy.maxRetries {
                    pool.updateState(id, to: .failed(reason: .remoteClose))
                    emitConnectionEvent(.reconnectionFailed(peer: peer, attempts: retryCount))
                }
            }
        }
    }

    private func scheduleReconnect(id: ConnectionID, peer: PeerID, address: Multiaddr, attempt: Int) async {
        let delay = configuration.pool.reconnectionPolicy.delay(for: attempt - 1)
        let nextAttempt = ContinuousClock.now + delay

        pool.updateState(id, to: .reconnecting(attempt: attempt, nextAttempt: nextAttempt))
        pool.incrementRetryCount(id)
        emitConnectionEvent(.reconnecting(peer: peer, attempt: attempt, nextDelay: delay))

        let task = Task { [weak self] in
            let slept = await sleepUnlessCancelled(
                for: delay,
                context: "reconnect backoff for peer \(peer)"
            )
            guard slept else { return }
            await self?.performReconnect(id: id, peer: peer, address: address, attempt: attempt)
        }
        reconnectTasks.append(task)
    }

    private func performReconnect(id: ConnectionID, peer: PeerID, address: Multiaddr, attempt: Int) async {
        guard isRunning else { return }
        guard pool.reconnectAddress(for: peer) != nil else { return }

        // Skip if already connected (another path may have succeeded)
        guard !pool.isConnected(to: peer) else { return }

        do {
            guard let transport = configuration.transports.first(where: { $0.canDial(address) }) else {
                throw NodeError.noSuitableTransport
            }

            // SecuredTransport (e.g., QUIC) bypasses the upgrade pipeline
            if let securedTransport = transport as? SecuredTransport {
                let muxedConnection = try await securedTransport.dialSecured(
                    address,
                    localKeyPair: configuration.keyPair
                )

                let remotePeer = muxedConnection.remotePeer

                guard remotePeer == peer else {
                    await runBestEffort("close reconnected secured connection after peer mismatch") {
                        try await muxedConnection.close()
                    }
                    throw NodeError.notConnected(peer)
                }

                if let gater = configuration.pool.gater {
                    if !gater.interceptSecured(peer: remotePeer, direction: .outbound) {
                        await runBestEffort("close reconnected secured connection rejected by secured gater") {
                            try await muxedConnection.close()
                        }
                        emitConnectionEvent(.gated(peer: remotePeer, address: address, stage: .secured))
                        throw NodeError.connectionGated(stage: .secured)
                    }
                }

                // Reserve outbound connection resource
                if let rm = configuration.resourceManager {
                    do {
                        try rm.reserveOutboundConnection(to: peer)
                    } catch let error as ResourceError {
                        await runBestEffort("close reconnected secured connection after outbound resource reservation failure") {
                            try await muxedConnection.close()
                        }
                        switch error {
                        case .limitExceeded(let scope, let resource):
                            throw NodeError.resourceLimitExceeded(scope: scope, resource: resource)
                        }
                    }
                }

                pool.updateConnection(id, connection: muxedConnection)
                pool.resetRetryCount(id)

                dialBackoff.recordSuccess(for: remotePeer)

                await resolveSimultaneousConnect(for: remotePeer)

                Task { [weak self] in
                    await self?.handleInboundStreams(connection: muxedConnection)
                    await self?.handleConnectionClosed(id: id, peer: remotePeer)
                }

                onPeerConnected(remotePeer)
                emitConnectionEvent(.reconnected(peer: peer, attempt: attempt))

                return
            }

            // Standard transport: dial then upgrade
            let rawConnection = try await transport.dial(address)

            let result: UpgradeResult
            do {
                result = try await upgrader.upgrade(
                    rawConnection,
                    localKeyPair: configuration.keyPair,
                    role: .initiator,
                    expectedPeer: peer
                )
            } catch {
                await runBestEffort("close raw connection after reconnect upgrade failure") {
                    try await rawConnection.close()
                }
                throw error
            }

            let remotePeer = result.connection.remotePeer

            guard remotePeer == peer else {
                await runBestEffort("close reconnected upgraded connection after peer mismatch") {
                    try await result.connection.close()
                }
                throw NodeError.notConnected(peer)
            }

            // Gating check (secured)
            if let gater = configuration.pool.gater {
                if !gater.interceptSecured(peer: remotePeer, direction: .outbound) {
                    await runBestEffort("close reconnected upgraded connection rejected by secured gater") {
                        try await result.connection.close()
                    }
                    emitConnectionEvent(.gated(peer: remotePeer, address: address, stage: .secured))
                    throw NodeError.connectionGated(stage: .secured)
                }
            }

            // Reserve outbound connection resource
            if let rm = configuration.resourceManager {
                do {
                    try rm.reserveOutboundConnection(to: peer)
                } catch let error as ResourceError {
                    await runBestEffort("close reconnected upgraded connection after outbound resource reservation failure") {
                        try await result.connection.close()
                    }
                    switch error {
                    case .limitExceeded(let scope, let resource):
                        throw NodeError.resourceLimitExceeded(scope: scope, resource: resource)
                    }
                }
            }

            pool.updateConnection(id, connection: result.connection)
            pool.resetRetryCount(id)

            dialBackoff.recordSuccess(for: remotePeer)

            await resolveSimultaneousConnect(for: remotePeer)

            Task { [weak self] in
                await self?.handleInboundStreams(connection: result.connection)
                await self?.handleConnectionClosed(id: id, peer: remotePeer)
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
            let policy = configuration.pool.reconnectionPolicy

            if policy.shouldReconnect(attempt: retryCount, reason: reason) {
                await scheduleReconnect(id: id, peer: peer, address: address, attempt: retryCount + 1)
            } else {
                pool.updateState(id, to: .failed(reason: reason))
                emitConnectionEvent(.reconnectionFailed(peer: peer, attempts: retryCount))
            }
        }
    }

    // MARK: - Private: Simultaneous Connect Resolution

    private func resolveSimultaneousConnect(for peer: PeerID) async {
        let connections = pool.connectedManagedConnections(for: peer)
        guard connections.count >= 2 else { return }

        let localPeerID = configuration.keyPair.peerID
        let winningDirection: ConnectionDirection = localPeerID < peer ? .outbound : .inbound

        var winner: ManagedConnection?
        var losers: [ManagedConnection] = []

        for conn in connections {
            if conn.direction == winningDirection && winner == nil {
                winner = conn
            } else {
                losers.append(conn)
            }
        }

        // If no clear winner (all same direction), keep the oldest
        if winner == nil, !losers.isEmpty {
            losers.sort { ($0.connectedAt ?? .now) < ($1.connectedAt ?? .now) }
            _ = losers.removeFirst()
        }

        // Close and remove losers
        for loser in losers {
            _ = pool.remove(loser.id)
            if let conn = loser.connection {
                await runBestEffort("close duplicate connection in simultaneous connect resolution") {
                    try await conn.close()
                }
            }
        }
    }

    // MARK: - Private: Idle Check

    private func startIdleCheckTask() {
        let idleTimeout = configuration.pool.idleTimeout
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
        let idleTimeout = configuration.pool.idleTimeout

        // 1. Close idle connections
        let idleConnections = pool.idleConnections(threshold: idleTimeout)
        for managed in idleConnections {
            configuration.resourceManager?.releaseConnection(peer: managed.peer, direction: managed.direction)
            if let connection = managed.connection {
                await runBestEffort("close idle connection during idle check") {
                    try await connection.close()
                }
            }
            _ = pool.remove(managed.id)
            if !pool.isConnected(to: managed.peer) {
                onPeerDisconnected(managed.peer)
                emitConnectionEvent(.disconnected(peer: managed.peer, reason: .idleTimeout))
            }
        }

        // 2. Trim if over limits
        let trimReport = pool.trimReport()
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

        let trimmed = pool.trimIfNeeded()
        for managed in trimmed {
            configuration.resourceManager?.releaseConnection(peer: managed.peer, direction: managed.direction)
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
