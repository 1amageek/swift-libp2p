/// RelayServer - Server for Circuit Relay v2 protocol.
///
/// Accepts reservations and routes circuits between peers.

import Foundation
import NIOCore
import Synchronization
import P2PCore
import P2PMux
import P2PProtocols

/// Logger for RelayServer operations.
private let logger = Logger(label: "p2p.circuit-relay.server")

/// Configuration for RelayServer.
public struct RelayServerConfiguration: Sendable {
    /// Maximum number of active reservations.
    public var maxReservations: Int

    /// Maximum number of circuits per peer.
    public var maxCircuitsPerPeer: Int

    /// Maximum total circuits.
    public var maxCircuits: Int

    /// Duration of reservations.
    public var reservationDuration: Duration

    /// Limits for circuits.
    public var circuitLimit: CircuitLimit

    /// Creates a new configuration.
    public init(
        maxReservations: Int = 128,
        maxCircuitsPerPeer: Int = 16,
        maxCircuits: Int = 1024,
        reservationDuration: Duration = .seconds(3600),
        circuitLimit: CircuitLimit = .default
    ) {
        self.maxReservations = maxReservations
        self.maxCircuitsPerPeer = maxCircuitsPerPeer
        self.maxCircuits = maxCircuits
        self.reservationDuration = reservationDuration
        self.circuitLimit = circuitLimit
    }
}

/// Server for Circuit Relay v2 protocol.
///
/// Accepts reservations and routes circuits between peers.
///
/// ## Usage
///
/// ```swift
/// let server = RelayServer(configuration: .init(
///     maxReservations: 128,
///     maxCircuitsPerPeer: 16
/// ))
/// ```
public final class RelayServer: EventEmitting, Sendable {

    // MARK: - StreamService

    public var protocolIDs: [String] {
        [CircuitRelayProtocol.hopProtocolID]
    }

    // MARK: - Properties

    /// Server configuration.
    public let configuration: RelayServerConfiguration

    /// Event state (dedicated).
    private let eventState: Mutex<EventState>

    private struct EventState: Sendable {
        var stream: AsyncStream<CircuitRelayEvent>?
        var continuation: AsyncStream<CircuitRelayEvent>.Continuation?
    }

    /// Server state (separated).
    private let serverState: Mutex<ServerState>

    private struct ServerState: Sendable {
        var reservations: [PeerID: ServerReservation] = [:]
        var activeCircuits: [CircuitID: ActiveCircuit] = [:]
        var circuitsByPeer: [PeerID: Set<CircuitID>] = [:]
        var cleanupTasks: [PeerID: Task<Void, Never>] = [:]
    }

    private struct ServerReservation: Sendable {
        let peer: PeerID
        let expiration: ContinuousClock.Instant
        let addresses: [Multiaddr]
    }

    private struct CircuitID: Hashable, Sendable {
        let source: PeerID
        let destination: PeerID
        let id: UUID
    }

    private struct ActiveCircuit: Sendable {
        let id: CircuitID
        let startTime: ContinuousClock.Instant
        var bytesTransferred: UInt64
    }

    /// Node context for stream opening and address resolution.
    /// Stored as a single reference (replaces separate opener/localPeer/localAddresses refs).
    private let nodeContextRef: Mutex<(any NodeContext)?> = Mutex(nil)

    // MARK: - Events

    /// Stream of relay server events.
    public var events: AsyncStream<CircuitRelayEvent> {
        eventState.withLock { state in
            if let existing = state.stream { return existing }
            let (stream, continuation) = AsyncStream<CircuitRelayEvent>.makeStream()
            state.stream = stream
            state.continuation = continuation
            return stream
        }
    }

    // MARK: - Initialization

    /// Creates a new relay server.
    ///
    /// - Parameter configuration: Server configuration.
    public init(configuration: RelayServerConfiguration = .init()) {
        self.configuration = configuration
        self.eventState = Mutex(EventState())
        self.serverState = Mutex(ServerState())
    }

    // MARK: - Statistics

    /// Returns the number of active reservations.
    public var reservationCount: Int {
        serverState.withLock { $0.reservations.count }
    }

    /// Returns the number of active circuits.
    public var circuitCount: Int {
        serverState.withLock { $0.activeCircuits.count }
    }

    /// Returns all active reservations.
    public var reservations: [PeerID] {
        serverState.withLock { Array($0.reservations.keys) }
    }

    // MARK: - Hop Protocol Handler

    private func handleHop(context: StreamContext) async {
        let stream = context.stream
        let requester = context.remotePeer

        do {
            // Read request
            let requestData = try await readMessage(from: stream)
            let request = try CircuitRelayProtobuf.decodeHop(requestData)

            switch request.type {
            case .reserve:
                await handleReserve(stream: stream, requester: requester, context: context)

            case .connect:
                guard let targetPeer = request.peer else {
                    try await sendHopStatus(stream: stream, status: .malformedMessage)
                    return
                }
                await handleConnect(
                    stream: stream,
                    source: requester,
                    target: targetPeer.id,
                    context: context
                )

            case .status:
                // Unexpected
                try await sendHopStatus(stream: stream, status: .unexpectedMessage)
            }

        } catch let error {
            logger.debug("Error handling HOP message: \(error)")
            do {
                try await stream.close()
            } catch let closeError {
                logger.debug("Failed to close stream after HOP error: \(closeError)")
            }
        }
    }

    private func handleReserve(
        stream: MuxedStream,
        requester: PeerID,
        context: StreamContext
    ) async {
        // Check limits
        let (canReserve, reason) = serverState.withLock { s -> (Bool, HopStatus?) in
            // Check max reservations
            if s.reservations.count >= configuration.maxReservations {
                return (false, .resourceLimitExceeded)
            }

            return (true, nil)
        }

        if !canReserve {
            let denyReason = reason ?? .resourceLimitExceeded
            do {
                try await sendHopStatus(stream: stream, status: denyReason)
            } catch let error {
                logger.debug("Failed to send reservation denied status: \(error)")
            }
            emit(.reservationDenied(from: requester, reason: denyReason))
            return
        }

        // Create reservation
        let expiration = ContinuousClock.now + configuration.reservationDuration
        let addresses = await buildRelayAddresses(for: requester, context: context)
        let reservation = ServerReservation(
            peer: requester,
            expiration: expiration,
            addresses: addresses
        )

        serverState.withLock { s in
            s.reservations[requester] = reservation
        }

        // Build reservation info for response
        let expirationTimestamp = UInt64(Date().timeIntervalSince1970) + UInt64(configuration.reservationDuration.components.seconds)
        let resInfo = ReservationInfo(
            expiration: expirationTimestamp,
            addresses: addresses,
            voucher: nil
        )

        // Send response
        let response = HopMessage.statusResponse(.ok, reservation: resInfo, limit: configuration.circuitLimit)
        let responseData = CircuitRelayProtobuf.encode(response)

        do {
            try await writeMessage(responseData, to: stream)
            emit(.reservationAccepted(from: requester, expiration: expiration))
        } catch let writeError {
            logger.debug("Failed to send reservation response: \(writeError)")
            // Failed to send response, remove reservation
            _ = serverState.withLock { s in
                s.reservations.removeValue(forKey: requester)
            }
        }

        do {
            try await stream.close()
        } catch let closeError {
            logger.debug("Failed to close stream after reserve: \(closeError)")
        }

        // Schedule cleanup
        scheduleReservationCleanup(peer: requester, at: expiration)
    }

    private func handleConnect(
        stream: MuxedStream,
        source: PeerID,
        target: PeerID,
        context: StreamContext
    ) async {
        // Check if target has reservation
        let hasReservation: Bool = serverState.withLock { s in
            guard let res = s.reservations[target] else { return false }
            return res.expiration > ContinuousClock.now
        }

        guard hasReservation else {
            do {
                try await sendHopStatus(stream: stream, status: .noReservation)
            } catch let error {
                logger.debug("Failed to send noReservation status: \(error)")
            }
            return
        }

        // Check circuit limits
        let (canConnect, reason) = serverState.withLock { s -> (Bool, HopStatus?) in
            let sourceCircuits = s.circuitsByPeer[source]?.count ?? 0
            if sourceCircuits >= configuration.maxCircuitsPerPeer {
                return (false, .resourceLimitExceeded)
            }

            if s.activeCircuits.count >= configuration.maxCircuits {
                return (false, .resourceLimitExceeded)
            }

            return (true, nil)
        }

        if !canConnect {
            let denyReason = reason ?? .resourceLimitExceeded
            do {
                try await sendHopStatus(stream: stream, status: denyReason)
            } catch let error {
                logger.debug("Failed to send circuit limit exceeded status: \(error)")
            }
            emit(.circuitFailed(source: source, destination: target, reason: .resourceLimitExceeded))
            return
        }

        // Get opener
        guard let opener = nodeContextRef.withLock({ $0 }) else {
            do {
                try await sendHopStatus(stream: stream, status: .connectionFailed)
            } catch let error {
                logger.debug("Failed to send connectionFailed status (no opener): \(error)")
            }
            return
        }

        // Connect to target using Stop protocol
        do {
            let targetStream = try await opener.newStream(
                to: target,
                protocol: CircuitRelayProtocol.stopProtocolID
            )

            // Send CONNECT to target
            let stopConnect = StopMessage.connect(from: source, limit: configuration.circuitLimit)
            let stopConnectData = CircuitRelayProtobuf.encode(stopConnect)
            try await writeMessage(stopConnectData, to: targetStream)

            // Read target response
            let stopResponseData = try await readMessage(from: targetStream)
            let stopResponse = try CircuitRelayProtobuf.decodeStop(stopResponseData)

            guard stopResponse.status == .ok else {
                do {
                    try await targetStream.close()
                } catch let closeError {
                    logger.debug("Failed to close target stream after rejection: \(closeError)")
                }
                do {
                    try await sendHopStatus(stream: stream, status: .connectionFailed)
                } catch let sendError {
                    logger.debug("Failed to send connectionFailed status: \(sendError)")
                }
                emit(.circuitFailed(source: source, destination: target, reason: .targetRejected))
                return
            }

            // Send OK to source
            let hopResponse = HopMessage.statusResponse(.ok, limit: configuration.circuitLimit)
            let hopResponseData = CircuitRelayProtobuf.encode(hopResponse)
            try await writeMessage(hopResponseData, to: stream)

            // Register circuit
            let circuitID = CircuitID(source: source, destination: target, id: UUID())
            serverState.withLock { s in
                s.activeCircuits[circuitID] = ActiveCircuit(
                    id: circuitID,
                    startTime: .now,
                    bytesTransferred: 0
                )
                s.circuitsByPeer[source, default: []].insert(circuitID)
                s.circuitsByPeer[target, default: []].insert(circuitID)
            }

            emit(.circuitOpened(source: source, destination: target))

            // Start relaying data between streams
            await relayData(from: stream, to: targetStream, circuitID: circuitID)

        } catch let connectError {
            logger.debug("Error connecting to target peer: \(connectError)")
            do {
                try await sendHopStatus(stream: stream, status: .connectionFailed)
            } catch let sendError {
                logger.debug("Failed to send connectionFailed status: \(sendError)")
            }
            emit(.circuitFailed(source: source, destination: target, reason: .targetUnreachable))
        }
    }

    // MARK: - Data Relaying

    private func relayData(from sourceStream: MuxedStream, to targetStream: MuxedStream, circuitID: CircuitID) async {
        // Relay data in both directions concurrently
        await withTaskGroup(of: Void.self) { group in
            // Source -> Target
            group.addTask {
                await self.copyStream(from: sourceStream, to: targetStream, circuitID: circuitID)
            }

            // Target -> Source
            group.addTask {
                await self.copyStream(from: targetStream, to: sourceStream, circuitID: circuitID)
            }
        }

        // Clean up circuit
        let bytesTransferred = serverState.withLock { s -> UInt64 in
            let bytes = s.activeCircuits[circuitID]?.bytesTransferred ?? 0
            s.activeCircuits.removeValue(forKey: circuitID)
            s.circuitsByPeer[circuitID.source]?.remove(circuitID)
            s.circuitsByPeer[circuitID.destination]?.remove(circuitID)
            return bytes
        }

        emit(.circuitCompleted(source: circuitID.source, destination: circuitID.destination, bytesTransferred: bytesTransferred))

        do {
            try await sourceStream.close()
        } catch let error {
            logger.debug("Failed to close source stream after relay: \(error)")
        }
        do {
            try await targetStream.close()
        } catch let error {
            logger.debug("Failed to close target stream after relay: \(error)")
        }
    }

    private func copyStream(from source: MuxedStream, to target: MuxedStream, circuitID: CircuitID) async {
        let startTime = ContinuousClock.now
        let durationLimit = configuration.circuitLimit.duration
        let dataLimit = configuration.circuitLimit.data

        // Track bytes locally to reduce lock contention
        var localBytesTransferred: UInt64 = 0
        let batchSize: UInt64 = 8192  // Sync to shared state every 8KB

        do {
            while true {
                // Check duration limit (no lock needed)
                if let limit = durationLimit {
                    if ContinuousClock.now - startTime >= limit {
                        break
                    }
                }

                // Check data limit using local counter (reduces lock frequency)
                if let limit = dataLimit {
                    // Sync and check periodically
                    if localBytesTransferred >= batchSize {
                        let totalBytes = serverState.withLock { s -> UInt64 in
                            s.activeCircuits[circuitID]?.bytesTransferred += localBytesTransferred
                            localBytesTransferred = 0
                            return s.activeCircuits[circuitID]?.bytesTransferred ?? 0
                        }
                        if totalBytes >= limit {
                            break
                        }
                    }
                }

                // Read and forward
                let data = try await source.read()
                if data.readableBytes == 0 {
                    break
                }

                try await target.write(data)
                localBytesTransferred += UInt64(data.readableBytes)
            }
        } catch {
            // Stream closed or error
        }

        // Final sync of bytes transferred
        if localBytesTransferred > 0 {
            serverState.withLock { s in
                s.activeCircuits[circuitID]?.bytesTransferred += localBytesTransferred
            }
        }
    }

    // MARK: - Helpers

    private func sendHopStatus(stream: MuxedStream, status: HopStatus) async throws {
        let response = HopMessage.statusResponse(status)
        let responseData = CircuitRelayProtobuf.encode(response)
        try await writeMessage(responseData, to: stream)
        try await stream.close()
    }

    private func buildRelayAddresses(for peer: PeerID, context: StreamContext) async -> [Multiaddr] {
        guard let ctx = nodeContextRef.withLock({ $0 }) else { return [] }
        let myPeerID = ctx.localPeer
        let localAddresses = await ctx.listenAddresses()

        // Build addresses: /ip4/.../tcp/.../p2p/{relay}/p2p-circuit/p2p/{peer}
        return localAddresses.compactMap { addr -> Multiaddr? in
            // Only use addresses that have network components
            guard addr.protocols.contains(where: {
                if case .ip4 = $0 { return true }
                if case .ip6 = $0 { return true }
                if case .dns = $0 { return true }
                if case .dns4 = $0 { return true }
                if case .dns6 = $0 { return true }
                return false
            }) else { return nil }

            var protocols = addr.protocols
            protocols.append(.p2p(myPeerID))
            protocols.append(.p2pCircuit)
            protocols.append(.p2p(peer))
            // Use unchecked since base address + 3 components is well under limit
            return Multiaddr(uncheckedProtocols: protocols)
        }
    }

    private func readMessage(from stream: MuxedStream) async throws -> Data {
        do {
            let buffer = try await stream.readLengthPrefixedMessage(maxSize: UInt64(CircuitRelayProtocol.maxMessageSize))
            return Data(buffer: buffer)
        } catch let error as StreamMessageError {
            switch error {
            case .streamClosed, .emptyMessage:
                throw CircuitRelayError.protocolViolation("Stream closed")
            case .messageTooLarge:
                throw CircuitRelayError.protocolViolation("Message too large")
            }
        }
    }

    private func writeMessage(_ data: Data, to stream: MuxedStream) async throws {
        try await stream.writeLengthPrefixedMessage(ByteBuffer(bytes: data))
    }

    private func emit(_ event: CircuitRelayEvent) {
        _ = eventState.withLock { state in
            state.continuation?.yield(event)
        }
    }

    // MARK: - Shutdown

    /// Shuts down the server and finishes the event stream.
    ///
    /// Call this method when the server is no longer needed to properly
    /// terminate any consumers waiting on the `events` stream.
    public func shutdown() {
        let tasks = serverState.withLock { s -> [Task<Void, Never>] in
            let tasks = Array(s.cleanupTasks.values)
            s.cleanupTasks.removeAll()
            return tasks
        }
        for task in tasks {
            task.cancel()
        }
        nodeContextRef.withLock { $0 = nil }
        eventState.withLock { state in
            state.continuation?.finish()
            state.continuation = nil
            state.stream = nil
        }
    }

    private func scheduleReservationCleanup(peer: PeerID, at expiration: ContinuousClock.Instant) {
        let task = Task { [weak self] in
            do {
                try await Task.sleep(until: expiration, clock: .continuous)
            } catch is CancellationError {
                return
            } catch {
                logger.debug("Cleanup sleep interrupted for \(peer): \(error)")
                return
            }
            guard let self else { return }
            self.cleanupExpiredReservation(peer: peer)
            self.serverState.withLock { s in
                _ = s.cleanupTasks.removeValue(forKey: peer)
            }
        }
        serverState.withLock { s in
            // Cancel any existing cleanup task for this peer (reservation renewed)
            s.cleanupTasks[peer]?.cancel()
            s.cleanupTasks[peer] = task
        }
    }

    private func cleanupExpiredReservation(peer: PeerID) {
        serverState.withLock { s in
            if let res = s.reservations[peer], res.expiration <= ContinuousClock.now {
                s.reservations.removeValue(forKey: peer)
            }
        }
    }
}

// MARK: - StreamService

extension RelayServer: StreamService {
    public func handleInboundStream(_ context: StreamContext) async {
        await handleHop(context: context)
    }

    public func attach(to context: any NodeContext) async {
        nodeContextRef.withLock { $0 = context }
    }
    // shutdown(): already defined (sync func satisfies async requirement)
}
