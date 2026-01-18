/// RelayClient - Client for Circuit Relay v2 protocol.
///
/// Allows making reservations on relays and connecting to peers through relays.

import Foundation
import Synchronization
import P2PCore
import P2PMux
import P2PProtocols

/// Configuration for RelayClient.
public struct RelayClientConfiguration: Sendable {
    /// Timeout for reservation requests.
    public var reservationTimeout: Duration

    /// Timeout for connect requests.
    public var connectTimeout: Duration

    /// Whether to automatically renew reservations before expiry.
    public var autoRenewReservations: Bool

    /// Time before expiry to start renewal.
    public var renewalBuffer: Duration

    /// Creates a new configuration.
    public init(
        reservationTimeout: Duration = .seconds(30),
        connectTimeout: Duration = .seconds(30),
        autoRenewReservations: Bool = true,
        renewalBuffer: Duration = .seconds(300)
    ) {
        self.reservationTimeout = reservationTimeout
        self.connectTimeout = connectTimeout
        self.autoRenewReservations = autoRenewReservations
        self.renewalBuffer = renewalBuffer
    }
}

/// Client for Circuit Relay v2 protocol.
///
/// Allows making reservations on relays and connecting to peers through relays.
///
/// ## Usage
///
/// ```swift
/// let client = RelayClient()
/// await client.registerHandler(registry: node)
///
/// // Make a reservation on a relay
/// let reservation = try await client.reserve(on: relayPeer, using: node)
///
/// // Connect to a peer through a relay
/// let connection = try await client.connectThrough(
///     relay: relayPeer,
///     to: targetPeer,
///     using: node
/// )
/// ```
public final class RelayClient: ProtocolService, Sendable {

    // MARK: - ProtocolService

    public var protocolIDs: [String] {
        [CircuitRelayProtocol.stopProtocolID]
    }

    // MARK: - Properties

    /// Client configuration.
    public let configuration: RelayClientConfiguration

    private let state: Mutex<ClientState>

    private struct ClientState: Sendable {
        var reservations: [PeerID: Reservation] = [:]
        var incomingConnections: [RelayedConnection] = []
        var connectionWaiters: [WaiterKey: ConnectionWaiter] = [:]
        var nextWaiterID: UInt64 = 0
        var eventContinuation: AsyncStream<CircuitRelayEvent>.Continuation?
        var eventStream: AsyncStream<CircuitRelayEvent>?
    }

    private struct WaiterKey: Hashable, Sendable {
        let id: UInt64
    }

    private struct ConnectionWaiter: @unchecked Sendable {
        let relay: PeerID?
        let remote: PeerID?
        let continuation: CheckedContinuation<RelayedConnection, any Error>
        let timeoutTask: Task<Void, Never>

        func matches(_ connection: RelayedConnection) -> Bool {
            (relay == nil || connection.relay == relay) &&
            (remote == nil || connection.remotePeer == remote)
        }

        func cancel() {
            timeoutTask.cancel()
        }
    }

    // MARK: - Events

    /// Stream of relay client events.
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

    /// Creates a new relay client.
    ///
    /// - Parameter configuration: Client configuration.
    public init(configuration: RelayClientConfiguration = .init()) {
        self.configuration = configuration
        self.state = Mutex(ClientState())
    }

    // MARK: - Handler Registration

    /// Registers the stop protocol handler for incoming relayed connections.
    ///
    /// - Parameter registry: The handler registry to register with.
    public func registerHandler(registry: any HandlerRegistry) async {
        await registry.handle(CircuitRelayProtocol.stopProtocolID) { [weak self] context in
            await self?.handleStop(context: context)
        }
    }

    // MARK: - Public API

    /// Makes a reservation on a relay to receive incoming relayed connections.
    ///
    /// - Parameters:
    ///   - relay: The relay peer to reserve on.
    ///   - opener: The stream opener to use.
    /// - Returns: The reservation details.
    /// - Throws: `CircuitRelayError.reservationFailed` if the reservation is denied.
    public func reserve(
        on relay: PeerID,
        using opener: any StreamOpener
    ) async throws -> Reservation {
        // Open stream to relay with Hop protocol
        let stream = try await opener.newStream(
            to: relay,
            protocol: CircuitRelayProtocol.hopProtocolID
        )

        do {
            // Send RESERVE message
            let request = HopMessage.reserve()
            let requestData = CircuitRelayProtobuf.encode(request)
            try await writeMessage(requestData, to: stream)

            // Read response
            let responseData = try await readMessage(from: stream)
            let response = try CircuitRelayProtobuf.decodeHop(responseData)

            guard response.type == .status else {
                throw CircuitRelayError.protocolViolation("Expected STATUS response")
            }

            guard response.status == .ok else {
                let status = response.status ?? .reservationRefused
                emit(.reservationFailed(relay: relay, error: .reservationFailed(status: status)))
                throw CircuitRelayError.reservationFailed(status: status)
            }

            guard let resInfo = response.reservation else {
                throw CircuitRelayError.protocolViolation("Missing reservation in response")
            }

            // Create reservation
            let expiration = ContinuousClock.Instant.now + .seconds(Int64(resInfo.expiration) - Int64(Date().timeIntervalSince1970))
            let reservation = Reservation(
                relay: relay,
                expiration: expiration,
                addresses: resInfo.addresses,
                voucher: resInfo.voucher
            )

            // Store reservation
            _ = state.withLock { s in
                s.reservations[relay] = reservation
            }

            emit(.reservationCreated(relay: relay, reservation: reservation))

            // Schedule expiration check
            scheduleExpirationCheck(relay: relay, at: expiration)

            try await stream.close()
            return reservation

        } catch {
            try? await stream.close()
            throw error
        }
    }

    /// Connects to a target peer through a relay.
    ///
    /// - Parameters:
    ///   - relay: The relay peer to connect through.
    ///   - target: The target peer to connect to.
    ///   - opener: The stream opener to use.
    /// - Returns: A relayed connection to the target.
    /// - Throws: `CircuitRelayError.connectionFailed` if the connection fails.
    public func connectThrough(
        relay: PeerID,
        to target: PeerID,
        using opener: any StreamOpener
    ) async throws -> RelayedConnection {
        // Open stream to relay with Hop protocol
        let stream = try await opener.newStream(
            to: relay,
            protocol: CircuitRelayProtocol.hopProtocolID
        )

        do {
            // Send CONNECT message
            let request = HopMessage.connect(to: target)
            let requestData = CircuitRelayProtobuf.encode(request)
            try await writeMessage(requestData, to: stream)

            // Read response
            let responseData = try await readMessage(from: stream)
            let response = try CircuitRelayProtobuf.decodeHop(responseData)

            guard response.type == .status else {
                throw CircuitRelayError.protocolViolation("Expected STATUS response")
            }

            guard response.status == .ok else {
                let status = response.status ?? .connectionFailed
                throw CircuitRelayError.connectionFailed(status: status)
            }

            // Create relayed connection (stream is now the circuit)
            let connection = RelayedConnection(
                stream: stream,
                relay: relay,
                remotePeer: target,
                limit: response.limit ?? .default
            )

            emit(.circuitEstablished(relay: relay, remote: target))

            return connection

        } catch {
            try? await stream.close()
            throw error
        }
    }

    /// Returns the current reservation on a relay, if any.
    ///
    /// - Parameter relay: The relay peer ID.
    /// - Returns: The reservation, or nil if none exists or it has expired.
    public func reservation(on relay: PeerID) -> Reservation? {
        state.withLock { s in
            guard let res = s.reservations[relay], res.isValid else {
                return nil
            }
            return res
        }
    }

    /// Returns all active reservations.
    public var activeReservations: [Reservation] {
        state.withLock { s in
            Array(s.reservations.values.filter { $0.isValid })
        }
    }

    /// Accepts the next incoming relayed connection, or waits for one.
    ///
    /// - Parameters:
    ///   - relay: Optional relay to filter by.
    ///   - remote: Optional remote peer to filter by.
    /// - Returns: The incoming relayed connection.
    public func acceptConnection(
        relay: PeerID? = nil,
        remote: PeerID? = nil
    ) async throws -> RelayedConnection {
        // Check for queued connections first
        let queued: RelayedConnection? = state.withLock { s in
            if let idx = s.incomingConnections.firstIndex(where: { conn in
                (relay == nil || conn.relay == relay) &&
                (remote == nil || conn.remotePeer == remote)
            }) {
                return s.incomingConnections.remove(at: idx)
            }
            return nil
        }

        if let conn = queued {
            return conn
        }

        // No queued connection, wait for one
        let timeout = configuration.connectTimeout
        return try await withCheckedThrowingContinuation { continuation in
            // First create the waiter key
            let waiterKey = state.withLock { s -> WaiterKey in
                let key = WaiterKey(id: s.nextWaiterID)
                s.nextWaiterID += 1
                return key
            }

            // Create timeout task with the key
            let timeoutTask = Task { [weak self, waiterKey] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }

                // Check if waiter is still pending
                if let self = self {
                    let waiter: ConnectionWaiter? = self.state.withLock { s in
                        s.connectionWaiters.removeValue(forKey: waiterKey)
                    }
                    if let waiter = waiter {
                        waiter.continuation.resume(throwing: CircuitRelayError.timeout)
                    }
                }
            }

            // Now store the waiter with the timeout task
            state.withLock { s in
                let waiter = ConnectionWaiter(
                    relay: relay,
                    remote: remote,
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )
                s.connectionWaiters[waiterKey] = waiter
            }
        }
    }

    // MARK: - Stop Protocol Handler

    /// Handles incoming STOP messages (relayed connections from other peers).
    private func handleStop(context: StreamContext) async {
        let stream = context.stream

        do {
            // Read CONNECT message
            let connectData = try await readMessage(from: stream)
            let connect = try CircuitRelayProtobuf.decodeStop(connectData)

            guard connect.type == .connect else {
                throw CircuitRelayError.protocolViolation("Expected CONNECT")
            }

            guard let peerInfo = connect.peer else {
                throw CircuitRelayError.protocolViolation("Missing peer in CONNECT")
            }

            // Send STATUS OK
            let response = StopMessage.statusResponse(.ok)
            let responseData = CircuitRelayProtobuf.encode(response)
            try await writeMessage(responseData, to: stream)

            // Create relayed connection
            let connection = RelayedConnection(
                stream: stream,
                relay: context.remotePeer,
                remotePeer: peerInfo.id,
                limit: connect.limit ?? .default
            )

            // Deliver to pending waiter or queue
            let matchedWaiter: ConnectionWaiter? = state.withLock { s in
                // Find a waiter that matches this connection
                for (key, waiter) in s.connectionWaiters {
                    if waiter.matches(connection) {
                        s.connectionWaiters.removeValue(forKey: key)
                        return waiter
                    }
                }
                // No matching waiter, queue the connection
                s.incomingConnections.append(connection)
                return nil
            }

            if let waiter = matchedWaiter {
                waiter.cancel()  // Cancel the timeout task
                waiter.continuation.resume(returning: connection)
            }

            emit(.circuitEstablished(relay: context.remotePeer, remote: peerInfo.id))

        } catch {
            // Send error status
            let response = StopMessage.statusResponse(.connectionFailed)
            let responseData = CircuitRelayProtobuf.encode(response)
            try? await writeMessage(responseData, to: stream)
            try? await stream.close()
        }
    }

    // MARK: - Message I/O

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

    // MARK: - Event Emission

    private func emit(_ event: CircuitRelayEvent) {
        let continuation = state.withLock { $0.eventContinuation }
        continuation?.yield(event)
    }

    // MARK: - Shutdown

    /// Shuts down the client and finishes the event stream.
    ///
    /// Call this method when the client is no longer needed to properly
    /// terminate any consumers waiting on the `events` stream.
    public func shutdown() {
        state.withLock { s in
            s.eventContinuation?.finish()
            s.eventContinuation = nil
            s.eventStream = nil
        }
    }

    // MARK: - Reservation Management

    private func scheduleExpirationCheck(relay: PeerID, at expiration: ContinuousClock.Instant) {
        Task { [weak self] in
            let now = ContinuousClock.now
            if expiration > now {
                try? await Task.sleep(until: expiration, clock: .continuous)
            }
            self?.handleReservationExpired(relay: relay)
        }
    }

    private func handleReservationExpired(relay: PeerID) {
        let removed: Bool = state.withLock { s in
            if let res = s.reservations[relay], !res.isValid {
                s.reservations.removeValue(forKey: relay)
                return true
            }
            return false
        }

        if removed {
            emit(.reservationExpired(relay: relay))
        }
    }
}
