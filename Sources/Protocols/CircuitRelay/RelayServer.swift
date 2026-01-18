/// RelayServer - Server for Circuit Relay v2 protocol.
///
/// Accepts reservations and routes circuits between peers.

import Foundation
import Synchronization
import P2PCore
import P2PMux
import P2PProtocols

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
/// await server.registerHandler(registry: node, opener: node)
/// ```
public final class RelayServer: ProtocolService, Sendable {

    // MARK: - ProtocolService

    public var protocolIDs: [String] {
        [CircuitRelayProtocol.hopProtocolID]
    }

    // MARK: - Properties

    /// Server configuration.
    public let configuration: RelayServerConfiguration

    private let state: Mutex<ServerState>

    private struct ServerState: Sendable {
        var reservations: [PeerID: ServerReservation] = [:]
        var activeCircuits: [CircuitID: ActiveCircuit] = [:]
        var circuitsByPeer: [PeerID: Set<CircuitID>] = [:]
        var eventContinuation: AsyncStream<CircuitRelayEvent>.Continuation?
        var eventStream: AsyncStream<CircuitRelayEvent>?
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

    /// Stream opener for connecting to destination peers.
    private let openerRef: Mutex<(any StreamOpener)?> = Mutex(nil)

    /// Local addresses for building relay addresses.
    private let localAddressesRef: Mutex<@Sendable () -> [Multiaddr]> = Mutex({ [] })

    /// Local peer ID for building relay addresses.
    private let localPeerRef: Mutex<PeerID?> = Mutex(nil)

    // MARK: - Events

    /// Stream of relay server events.
    public var events: AsyncStream<CircuitRelayEvent> {
        state.withLock { s in
            if let existing = s.eventStream { return existing }
            let (stream, continuation) = AsyncStream<CircuitRelayEvent>.makeStream()
            s.eventStream = stream
            s.eventContinuation = continuation
            return stream
        }
    }

    // MARK: - Initialization

    /// Creates a new relay server.
    ///
    /// - Parameter configuration: Server configuration.
    public init(configuration: RelayServerConfiguration = .init()) {
        self.configuration = configuration
        self.state = Mutex(ServerState())
    }

    // MARK: - Handler Registration

    /// Registers the hop protocol handler.
    ///
    /// - Parameters:
    ///   - registry: The handler registry to register with.
    ///   - opener: The stream opener for connecting to destination peers.
    ///   - localPeer: The local peer ID.
    ///   - getLocalAddresses: Function to get local addresses.
    public func registerHandler(
        registry: any HandlerRegistry,
        opener: any StreamOpener,
        localPeer: PeerID,
        getLocalAddresses: @escaping @Sendable () -> [Multiaddr]
    ) async {
        openerRef.withLock { $0 = opener }
        localPeerRef.withLock { $0 = localPeer }
        localAddressesRef.withLock { $0 = getLocalAddresses }

        await registry.handle(CircuitRelayProtocol.hopProtocolID) { [weak self] context in
            await self?.handleHop(context: context)
        }
    }

    // MARK: - Statistics

    /// Returns the number of active reservations.
    public var reservationCount: Int {
        state.withLock { $0.reservations.count }
    }

    /// Returns the number of active circuits.
    public var circuitCount: Int {
        state.withLock { $0.activeCircuits.count }
    }

    /// Returns all active reservations.
    public var reservations: [PeerID] {
        state.withLock { Array($0.reservations.keys) }
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

        } catch {
            try? await stream.close()
        }
    }

    private func handleReserve(
        stream: MuxedStream,
        requester: PeerID,
        context: StreamContext
    ) async {
        // Check limits
        let (canReserve, reason) = state.withLock { s -> (Bool, HopStatus?) in
            // Check max reservations
            if s.reservations.count >= configuration.maxReservations {
                return (false, .resourceLimitExceeded)
            }

            return (true, nil)
        }

        guard canReserve else {
            try? await sendHopStatus(stream: stream, status: reason!)
            emit(.reservationDenied(from: requester, reason: reason!))
            return
        }

        // Create reservation
        let expiration = ContinuousClock.now + configuration.reservationDuration
        let addresses = buildRelayAddresses(for: requester, context: context)
        let reservation = ServerReservation(
            peer: requester,
            expiration: expiration,
            addresses: addresses
        )

        state.withLock { s in
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
        } catch {
            // Failed to send response, remove reservation
            _ = state.withLock { s in
                s.reservations.removeValue(forKey: requester)
            }
        }

        try? await stream.close()

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
        let hasReservation: Bool = state.withLock { s in
            guard let res = s.reservations[target] else { return false }
            return res.expiration > ContinuousClock.now
        }

        guard hasReservation else {
            try? await sendHopStatus(stream: stream, status: .noReservation)
            return
        }

        // Check circuit limits
        let (canConnect, reason) = state.withLock { s -> (Bool, HopStatus?) in
            let sourceCircuits = s.circuitsByPeer[source]?.count ?? 0
            if sourceCircuits >= configuration.maxCircuitsPerPeer {
                return (false, .resourceLimitExceeded)
            }

            if s.activeCircuits.count >= configuration.maxCircuits {
                return (false, .resourceLimitExceeded)
            }

            return (true, nil)
        }

        guard canConnect else {
            try? await sendHopStatus(stream: stream, status: reason!)
            return
        }

        // Get opener
        guard let opener = openerRef.withLock({ $0 }) else {
            try? await sendHopStatus(stream: stream, status: .connectionFailed)
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
                try? await targetStream.close()
                try? await sendHopStatus(stream: stream, status: .connectionFailed)
                return
            }

            // Send OK to source
            let hopResponse = HopMessage.statusResponse(.ok, limit: configuration.circuitLimit)
            let hopResponseData = CircuitRelayProtobuf.encode(hopResponse)
            try await writeMessage(hopResponseData, to: stream)

            // Register circuit
            let circuitID = CircuitID(source: source, destination: target, id: UUID())
            state.withLock { s in
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

        } catch {
            try? await sendHopStatus(stream: stream, status: .connectionFailed)
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
        let bytesTransferred = state.withLock { s -> UInt64 in
            let bytes = s.activeCircuits[circuitID]?.bytesTransferred ?? 0
            s.activeCircuits.removeValue(forKey: circuitID)
            s.circuitsByPeer[circuitID.source]?.remove(circuitID)
            s.circuitsByPeer[circuitID.destination]?.remove(circuitID)
            return bytes
        }

        emit(.circuitCompleted(source: circuitID.source, destination: circuitID.destination, bytesTransferred: bytesTransferred))

        try? await sourceStream.close()
        try? await targetStream.close()
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
                        let totalBytes = state.withLock { s -> UInt64 in
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
                if data.isEmpty {
                    break
                }

                try await target.write(data)
                localBytesTransferred += UInt64(data.count)
            }
        } catch {
            // Stream closed or error
        }

        // Final sync of bytes transferred
        if localBytesTransferred > 0 {
            state.withLock { s in
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

    private func buildRelayAddresses(for peer: PeerID, context: StreamContext) -> [Multiaddr] {
        let localPeer = localPeerRef.withLock { $0 }
        let getAddresses = localAddressesRef.withLock { $0 }
        let localAddresses = getAddresses()

        guard let myPeerID = localPeer else { return [] }

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
            return try await stream.readLengthPrefixedMessage(maxSize: UInt64(CircuitRelayProtocol.maxMessageSize))
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
        try await stream.writeLengthPrefixedMessage(data)
    }

    private func emit(_ event: CircuitRelayEvent) {
        let continuation = state.withLock { $0.eventContinuation }
        continuation?.yield(event)
    }

    // MARK: - Shutdown

    /// Shuts down the server and finishes the event stream.
    ///
    /// Call this method when the server is no longer needed to properly
    /// terminate any consumers waiting on the `events` stream.
    public func shutdown() {
        state.withLock { s in
            s.eventContinuation?.finish()
            s.eventContinuation = nil
            s.eventStream = nil
        }
    }

    private func scheduleReservationCleanup(peer: PeerID, at expiration: ContinuousClock.Instant) {
        Task { [weak self] in
            try? await Task.sleep(until: expiration, clock: .continuous)
            self?.cleanupExpiredReservation(peer: peer)
        }
    }

    private func cleanupExpiredReservation(peer: PeerID) {
        state.withLock { s in
            if let res = s.reservations[peer], res.expiration <= ContinuousClock.now {
                s.reservations.removeValue(forKey: peer)
            }
        }
    }
}
