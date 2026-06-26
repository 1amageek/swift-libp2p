/// RelayClient - Client for Circuit Relay v2 protocol.
///
/// Allows making reservations on relays and connecting to peers through relays.

import Foundation
import NIOCore
import Synchronization
import P2PCore
import P2PMux
import P2PProtocols

/// Logger for RelayClient operations.
private let logger = Logger(label: "p2p.circuit-relay.client")

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

    /// Whether a valid signed reservation voucher is required.
    ///
    /// When `true`, a reservation lacking a voucher is rejected. When `false`,
    /// an absent voucher is tolerated, but a *present* voucher is always
    /// verified (an invalid voucher is rejected regardless of this flag).
    public var requireVoucher: Bool

    /// Maximum number of queued incoming relayed connections awaiting accept.
    ///
    /// Beyond this bound the oldest queued connection is closed and dropped to
    /// prevent unbounded memory growth from connections that are never accepted.
    public var maxQueuedIncomingConnections: Int

    /// Creates a new configuration.
    public init(
        reservationTimeout: Duration = .seconds(30),
        connectTimeout: Duration = .seconds(30),
        autoRenewReservations: Bool = true,
        renewalBuffer: Duration = .seconds(300),
        requireVoucher: Bool = false,
        maxQueuedIncomingConnections: Int = 256
    ) {
        self.reservationTimeout = reservationTimeout
        self.connectTimeout = connectTimeout
        self.autoRenewReservations = autoRenewReservations
        self.renewalBuffer = renewalBuffer
        self.requireVoucher = requireVoucher
        self.maxQueuedIncomingConnections = max(1, maxQueuedIncomingConnections)
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
public final class RelayClient: EventEmitting, Sendable {

    // MARK: - StreamService

    public var protocolIDs: [String] {
        [CircuitRelayProtocol.stopProtocolID]
    }

    // MARK: - Properties

    /// Client configuration.
    public let configuration: RelayClientConfiguration

    /// Event channel (dedicated).
    private let channel = EventChannel<CircuitRelayEvent>()

    /// Client state (separated).
    private let clientState: Mutex<ClientState>

    /// Registered listeners per relay peer for direct connection routing.
    private let listeners: Mutex<[PeerID: WeakListenerRef]>

    /// The local peer ID, used to verify that a reservation voucher was issued
    /// to this peer. Set via `setLocalPeer(_:)` when an identity is available.
    private let localPeerRef: Mutex<PeerID?> = Mutex(nil)

    private struct ClientState: Sendable {
        var reservations: [PeerID: Reservation] = [:]
        var reservationOpeners: [PeerID: OpenerRef] = [:]
        var renewalTasks: [PeerID: Task<Void, Never>] = [:]
        var incomingConnections: [RelayedConnection] = []
        var connectionWaiters: [WaiterKey: ConnectionWaiter] = [:]
        var nextWaiterID: UInt64 = 0
        var isShutdown = false
    }

    /// Reference to stream opener for renewal.
    ///
    /// This holds a strong reference to the opener. The reference is cleaned up when:
    /// - The reservation expires
    /// - The reservation is cancelled via `cancelReservation(on:)`
    /// - The client is shut down
    private final class OpenerRef: Sendable {
        let opener: any StreamOpener
        init(_ opener: any StreamOpener) {
            self.opener = opener
        }
    }

    /// Weak reference to listener for routing without retain cycles.
    /// Uses Mutex to safely wrap the mutable weak reference.
    private final class WeakListenerRef: Sendable {
        private let ref: Mutex<WeakRef>

        private struct WeakRef: Sendable {
            weak var value: RelayListener?
        }

        init(_ listener: RelayListener) {
            self.ref = Mutex(WeakRef(value: listener))
        }

        var listener: RelayListener? {
            ref.withLock { $0.value }
        }
    }

    private struct WaiterKey: Hashable, Sendable {
        let id: UInt64
    }

    private struct ConnectionWaiter: Sendable {
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
    public var events: AsyncStream<CircuitRelayEvent> { channel.stream }

    // MARK: - Initialization

    /// Creates a new relay client.
    ///
    /// - Parameter configuration: Client configuration.
    public init(configuration: RelayClientConfiguration = .init()) {
        self.configuration = configuration
        self.clientState = Mutex(ClientState())
        self.listeners = Mutex([:])
    }

    /// Sets the local peer ID used for reservation voucher verification.
    ///
    /// When set, vouchers must name this peer as the reservation holder.
    public func setLocalPeer(_ peer: PeerID) {
        localPeerRef.withLock { $0 = peer }
    }

    /// Verifies a reservation voucher.
    ///
    /// - If no voucher is present and `requireVoucher` is `true`, throws.
    /// - If a voucher is present, the envelope signature must verify, the
    ///   signer must be the relay, and (when a local peer is configured) the
    ///   voucher must name the local peer as the reservation holder.
    private func verifyVoucher(_ voucherData: Data?, relay: PeerID) throws {
        guard let voucherData else {
            if configuration.requireVoucher {
                throw CircuitRelayError.invalidVoucher("Reservation has no voucher")
            }
            return
        }

        let voucher: ReservationVoucher
        do {
            let envelope = try Envelope.unmarshal(voucherData)
            voucher = try envelope.record(as: ReservationVoucher.self)
            // The envelope must be signed by the relay itself.
            guard envelope.peerID == relay else {
                throw CircuitRelayError.invalidVoucher(
                    "Voucher signer \(envelope.peerID) is not the relay \(relay)"
                )
            }
        } catch let error as CircuitRelayError {
            throw error
        } catch {
            throw CircuitRelayError.invalidVoucher("Voucher verification failed: \(error)")
        }

        // The voucher must bind the relay we are talking to.
        guard voucher.relay == relay else {
            throw CircuitRelayError.invalidVoucher(
                "Voucher relay \(voucher.relay) does not match \(relay)"
            )
        }

        // If we know our own identity, the voucher must be issued to us.
        if let localPeer = localPeerRef.withLock({ $0 }) {
            guard voucher.peer == localPeer else {
                throw CircuitRelayError.invalidVoucher(
                    "Voucher peer \(voucher.peer) does not match local peer \(localPeer)"
                )
            }
        }
    }

    // MARK: - Listener Registration

    /// Registers a listener for a specific relay.
    ///
    /// When connections arrive from this relay, they will be routed
    /// directly to the registered listener.
    ///
    /// - Parameters:
    ///   - listener: The listener to register.
    ///   - relay: The relay peer ID.
    func registerListener(_ listener: RelayListener, for relay: PeerID) {
        listeners.withLock { $0[relay] = WeakListenerRef(listener) }
    }

    /// Unregisters a listener for a specific relay.
    ///
    /// - Parameter relay: The relay peer ID.
    func unregisterListener(for relay: PeerID) {
        _ = listeners.withLock { $0.removeValue(forKey: relay) }
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
        try throwIfShutdown()

        // Open stream to relay with Hop protocol
        let stream = try await opener.newStream(
            to: relay,
            protocol: CircuitRelayProtocol.hopProtocolID
        )

        do {
            try throwIfShutdown()

            // Send RESERVE message
            let request = HopMessage.reserve()
            var requestData = ByteBuffer()
            CircuitRelayProtobuf.encode(request, into: &requestData)
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

            // Verify the reservation voucher (if present / required).
            try verifyVoucher(resInfo.voucher, relay: relay)

            // Create reservation
            let expiration = ContinuousClock.Instant.now + .seconds(Int64(resInfo.expiration) - Int64(Date().timeIntervalSince1970))
            let reservation = Reservation(
                relay: relay,
                expiration: expiration,
                addresses: resInfo.addresses,
                voucher: resInfo.voucher
            )

            // Store reservation and opener reference for renewal
            let stored = clientState.withLock { s -> Bool in
                guard !s.isShutdown else { return false }
                s.reservations[relay] = reservation
                s.reservationOpeners[relay] = OpenerRef(opener)
                return true
            }
            guard stored else {
                throw CircuitRelayError.circuitClosed
            }

            emit(.reservationCreated(relay: relay, reservation: reservation))

            // Schedule renewal or expiration
            scheduleRenewalOrExpiration(relay: relay, at: expiration)

            try await stream.close()
            return reservation

        } catch {
            do {
                try await stream.close()
            } catch let closeError {
                logger.debug("Failed to close stream during reserve cleanup: \(closeError)")
            }
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
        try throwIfShutdown()

        // Open stream to relay with Hop protocol
        let stream = try await opener.newStream(
            to: relay,
            protocol: CircuitRelayProtocol.hopProtocolID
        )

        do {
            try throwIfShutdown()

            // Send CONNECT message
            let request = HopMessage.connect(to: target)
            var requestData = ByteBuffer()
            CircuitRelayProtobuf.encode(request, into: &requestData)
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

            try throwIfShutdown()
            emit(.circuitEstablished(relay: relay, remote: target))

            return connection

        } catch {
            do {
                try await stream.close()
            } catch let closeError {
                logger.debug("Failed to close stream during connect cleanup: \(closeError)")
            }
            throw error
        }
    }

    /// Returns the current reservation on a relay, if any.
    ///
    /// - Parameter relay: The relay peer ID.
    /// - Returns: The reservation, or nil if none exists or it has expired.
    public func reservation(on relay: PeerID) -> Reservation? {
        clientState.withLock { s in
            guard let res = s.reservations[relay], res.isValid else {
                return nil
            }
            return res
        }
    }

    /// Returns all active reservations.
    public var activeReservations: [Reservation] {
        clientState.withLock { s in
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
        let queued: RelayedConnection? = try clientState.withLock { s throws(CircuitRelayError) in
            guard !s.isShutdown else {
                throw CircuitRelayError.circuitClosed
            }
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

        // Check for cancellation before waiting
        try Task.checkCancellation()

        // No queued connection, wait for one
        let timeout = configuration.connectTimeout

        // First create the waiter key outside the continuation
        let waiterKey = clientState.withLock { s -> WaiterKey in
            let key = WaiterKey(id: s.nextWaiterID)
            s.nextWaiterID += 1
            return key
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Create timeout task with the key
                let timeoutTask = Task { [weak self, waiterKey] in
                    guard let self = self else { return }
                    guard await self.waitUnlessCancelled(for: timeout, context: "connection wait timeout") else {
                        return
                    }
                    guard !Task.isCancelled else { return }

                    // Check if waiter is still pending
                    let waiter: ConnectionWaiter? = self.clientState.withLock { s in
                        s.connectionWaiters.removeValue(forKey: waiterKey)
                    }
                    if let waiter = waiter {
                        waiter.continuation.resume(throwing: CircuitRelayError.timeout)
                    }
                }

                // Register waiter and check for cancellation atomically
                let registration = clientState.withLock { s -> Result<Bool, CircuitRelayError> in
                    guard !s.isShutdown else {
                        return .failure(.circuitClosed)
                    }
                    let waiter = ConnectionWaiter(
                        relay: relay,
                        remote: remote,
                        continuation: continuation,
                        timeoutTask: timeoutTask
                    )
                    s.connectionWaiters[waiterKey] = waiter

                    // Check if cancelled AFTER registration (race window closed)
                    return .success(Task.isCancelled)
                }

                let alreadyCancelled: Bool
                switch registration {
                case .success(let value):
                    alreadyCancelled = value
                case .failure(let error):
                    timeoutTask.cancel()
                    continuation.resume(throwing: error)
                    return
                }

                // If we were cancelled during registration, clean up immediately
                if alreadyCancelled {
                    let waiter: ConnectionWaiter? = clientState.withLock { s in
                        s.connectionWaiters.removeValue(forKey: waiterKey)
                    }
                    if let waiter = waiter {
                        waiter.timeoutTask.cancel()
                        waiter.continuation.resume(throwing: CancellationError())
                    }
                }
            }
        } onCancel: { [weak self, waiterKey] in
            // Immediately cancel the waiter when task is cancelled
            guard let self = self else { return }
            let waiter: ConnectionWaiter? = self.clientState.withLock { s in
                s.connectionWaiters.removeValue(forKey: waiterKey)
            }
            if let waiter = waiter {
                waiter.timeoutTask.cancel()
                waiter.continuation.resume(throwing: CancellationError())
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
            var responseData = ByteBuffer()
            CircuitRelayProtobuf.encode(response, into: &responseData)
            try await writeMessage(responseData, to: stream)

            // Create relayed connection
            let connection = RelayedConnection(
                stream: stream,
                relay: context.remotePeer,
                remotePeer: peerInfo.id,
                limit: connect.limit ?? .default
            )

            guard !clientState.withLock({ $0.isShutdown }) else {
                try await connection.close()
                return
            }

            // Route to registered listener if exists (Listener Registry pattern)
            let registeredListener: RelayListener? = listeners.withLock { l in
                l[connection.relay]?.listener
            }

            if let listener = registeredListener {
                // Direct routing to registered listener
                guard listener.enqueue(connection) else {
                    try await connection.close()
                    return
                }
            } else {
                // Fallback: Deliver to pending waiter or shared queue
                let (matchedWaiter, evicted): (ConnectionWaiter?, RelayedConnection?) = clientState.withLock { s in
                    guard !s.isShutdown else {
                        return (nil, connection)
                    }
                    // Find a waiter that matches this connection
                    for (key, waiter) in s.connectionWaiters {
                        if waiter.matches(connection) {
                            s.connectionWaiters.removeValue(forKey: key)
                            return (waiter, nil)
                        }
                    }
                    // No matching waiter, queue the connection (bounded).
                    s.incomingConnections.append(connection)
                    var dropped: RelayedConnection? = nil
                    if s.incomingConnections.count > configuration.maxQueuedIncomingConnections {
                        // Drop the oldest queued connection to bound memory.
                        dropped = s.incomingConnections.removeFirst()
                    }
                    return (nil, dropped)
                }

                if let waiter = matchedWaiter {
                    waiter.cancel()  // Cancel the timeout task
                    waiter.continuation.resume(returning: connection)
                }
                if let evicted {
                    // Close the dropped connection outside the lock.
                    do {
                        try await evicted.close()
                    } catch {
                        logger.debug("Failed to close evicted queued relay connection: \(error)")
                    }
                }
            }

            emit(.circuitEstablished(relay: context.remotePeer, remote: peerInfo.id))

        } catch let handleError {
            logger.debug("Error handling STOP message: \(handleError)")
            // Send error status
            let response = StopMessage.statusResponse(.connectionFailed)
            var responseData = ByteBuffer()
            CircuitRelayProtobuf.encode(response, into: &responseData)
            do {
                try await writeMessage(responseData, to: stream)
            } catch let writeError {
                logger.debug("Failed to send error response: \(writeError)")
            }
            do {
                try await stream.close()
            } catch let closeError {
                logger.debug("Failed to close stream after STOP error: \(closeError)")
            }
        }
    }

    // MARK: - Message I/O

    @discardableResult
    private func waitUnlessCancelled(for duration: Duration, context: String) async -> Bool {
        do {
            try await Task.sleep(for: duration)
            return true
        } catch is CancellationError {
            return false
        } catch {
            logger.debug("Sleep interrupted (\(context)): \(error)")
            return false
        }
    }

    @discardableResult
    private func waitUntilUnlessCancelled(
        _ deadline: ContinuousClock.Instant,
        context: String
    ) async -> Bool {
        do {
            try await Task.sleep(until: deadline, clock: .continuous)
            return true
        } catch is CancellationError {
            return false
        } catch {
            logger.debug("Sleep interrupted (\(context)): \(error)")
            return false
        }
    }

    private func readMessage(from stream: MuxedStream) async throws -> ByteBuffer {
        do {
            let buffer = try await stream.readLengthPrefixedMessage(maxSize: UInt64(CircuitRelayProtocol.maxMessageSize))
            return buffer
        } catch let error as StreamMessageError {
            switch error {
            case .streamClosed, .emptyMessage:
                throw CircuitRelayError.protocolViolation("Stream closed")
            case .messageTooLarge:
                throw CircuitRelayError.protocolViolation("Message too large")
            }
        }
    }

    private func writeMessage(_ data: ByteBuffer, to stream: MuxedStream) async throws {
        try await stream.writeLengthPrefixedMessage(data)
    }

    // MARK: - Event Emission

    private func emit(_ event: CircuitRelayEvent) {
        channel.yield(event)
    }

    private func throwIfShutdown() throws {
        if clientState.withLock({ $0.isShutdown }) {
            throw CircuitRelayError.circuitClosed
        }
    }

    // MARK: - Shutdown

    /// Shuts down the client and finishes the event stream.
    ///
    /// Call this method when the client is no longer needed to properly
    /// terminate any consumers waiting on the `events` stream.
    public func shutdown() async throws {
        let shutdownState = clientState.withLock { s -> (
            renewalTasks: [Task<Void, Never>],
            waiters: [ConnectionWaiter],
            queuedConnections: [RelayedConnection]
        ) in
            guard !s.isShutdown else {
                return ([], [], [])
            }
            s.isShutdown = true
            let renewalTasks = Array(s.renewalTasks.values)
            let waiters = Array(s.connectionWaiters.values)
            let queuedConnections = s.incomingConnections
            s.renewalTasks.removeAll()
            s.reservations.removeAll()
            s.reservationOpeners.removeAll()
            s.connectionWaiters.removeAll()
            s.incomingConnections.removeAll()
            return (renewalTasks, waiters, queuedConnections)
        }

        for task in shutdownState.renewalTasks {
            task.cancel()
        }
        for waiter in shutdownState.waiters {
            waiter.timeoutTask.cancel()
            waiter.continuation.resume(throwing: CircuitRelayError.circuitClosed)
        }
        for connection in shutdownState.queuedConnections {
            do {
                try await connection.close()
            } catch {
                logger.debug("Failed to close queued relay connection during shutdown: \(error)")
            }
        }

        channel.finish()
    }

    // MARK: - Reservation Management

    /// Schedules renewal or expiration handling for a reservation.
    private func scheduleRenewalOrExpiration(relay: PeerID, at expiration: ContinuousClock.Instant) {
        // Cancel any existing renewal task for this relay
        let shouldSchedule = clientState.withLock { s -> Bool in
            guard !s.isShutdown else { return false }
            s.renewalTasks[relay]?.cancel()
            s.renewalTasks.removeValue(forKey: relay)
            return s.reservations[relay] != nil
        }
        guard shouldSchedule else { return }

        let task = Task { [weak self, configuration] in
            guard let self = self else { return }
            guard !self.clientState.withLock({ $0.isShutdown }) else { return }

            if configuration.autoRenewReservations {
                // Schedule renewal before expiration
                let renewalTime = expiration - configuration.renewalBuffer
                let now = ContinuousClock.now

                if renewalTime > now {
                    guard await self.waitUntilUnlessCancelled(
                        renewalTime,
                        context: "reservation renewal scheduling"
                    ) else {
                        return
                    }
                }

                // Check for cancellation
                guard !Task.isCancelled else { return }
                guard !self.clientState.withLock({ $0.isShutdown }) else { return }

                // Attempt renewal
                do {
                    try await self.renewReservation(on: relay)
                    // Renewal succeeded - new task will be scheduled by renewReservation
                } catch {
                    // Renewal failed - emit event and wait for expiration
                    let relayError: CircuitRelayError
                    if let circuitError = error as? CircuitRelayError {
                        relayError = circuitError
                    } else {
                        relayError = .reservationFailed(status: .reservationRefused)
                    }
                    self.emit(.reservationRenewalFailed(relay: relay, error: relayError))

                    // Wait for actual expiration
                    let now = ContinuousClock.now
                    if expiration > now {
                        guard await self.waitUntilUnlessCancelled(
                            expiration,
                            context: "reservation expiration after renewal failure"
                        ) else {
                            return
                        }
                    }
                    guard !Task.isCancelled else { return }
                    guard !self.clientState.withLock({ $0.isShutdown }) else { return }
                    self.handleReservationExpired(relay: relay)
                }
            } else {
                // No auto-renewal: just wait for expiration
                let now = ContinuousClock.now
                if expiration > now {
                    guard await self.waitUntilUnlessCancelled(
                        expiration,
                        context: "reservation expiration without auto-renewal"
                    ) else {
                        return
                    }
                }
                guard !Task.isCancelled else { return }
                guard !self.clientState.withLock({ $0.isShutdown }) else { return }
                self.handleReservationExpired(relay: relay)
            }
        }

        // Store the task
        let retained = clientState.withLock { s -> Bool in
            guard !s.isShutdown, s.reservations[relay] != nil else { return false }
            s.renewalTasks[relay] = task
            return true
        }
        if !retained {
            task.cancel()
        }
    }

    /// Renews an existing reservation on a relay.
    ///
    /// - Parameter relay: The relay peer to renew reservation on.
    /// - Throws: `CircuitRelayError` if renewal fails.
    private func renewReservation(on relay: PeerID) async throws {
        try throwIfShutdown()

        // Get the stored opener
        let openerRef: OpenerRef? = clientState.withLock { s in
            s.reservationOpeners[relay]
        }

        guard let openerRef = openerRef else {
            throw CircuitRelayError.reservationFailed(status: .reservationRefused)
        }

        let opener = openerRef.opener

        // Open stream to relay with Hop protocol
        let stream = try await opener.newStream(
            to: relay,
            protocol: CircuitRelayProtocol.hopProtocolID
        )

        do {
            try throwIfShutdown()

            // Send RESERVE message
            let request = HopMessage.reserve()
            var requestData = ByteBuffer()
            CircuitRelayProtobuf.encode(request, into: &requestData)
            try await writeMessage(requestData, to: stream)

            // Read response
            let responseData = try await readMessage(from: stream)
            let response = try CircuitRelayProtobuf.decodeHop(responseData)

            guard response.type == .status else {
                throw CircuitRelayError.protocolViolation("Expected STATUS response")
            }

            guard response.status == .ok else {
                let status = response.status ?? .reservationRefused
                throw CircuitRelayError.reservationFailed(status: status)
            }

            guard let resInfo = response.reservation else {
                throw CircuitRelayError.protocolViolation("Missing reservation in response")
            }

            // Create new reservation
            let expiration = ContinuousClock.Instant.now + .seconds(Int64(resInfo.expiration) - Int64(Date().timeIntervalSince1970))
            let reservation = Reservation(
                relay: relay,
                expiration: expiration,
                addresses: resInfo.addresses,
                voucher: resInfo.voucher
            )

            // Update stored reservation
            let updated = clientState.withLock { s -> Bool in
                guard !s.isShutdown, s.reservationOpeners[relay] != nil else { return false }
                s.reservations[relay] = reservation
                return true
            }
            guard updated else {
                throw CircuitRelayError.circuitClosed
            }

            emit(.reservationRenewed(relay: relay, newExpiration: expiration))

            // Schedule next renewal/expiration
            scheduleRenewalOrExpiration(relay: relay, at: expiration)

            try await stream.close()

        } catch {
            do {
                try await stream.close()
            } catch let closeError {
                logger.debug("Failed to close stream during renewal cleanup: \(closeError)")
            }
            throw error
        }
    }

    private func handleReservationExpired(relay: PeerID) {
        let removed: Bool = clientState.withLock { s in
            guard !s.isShutdown else { return false }
            if let res = s.reservations[relay], !res.isValid {
                s.reservations.removeValue(forKey: relay)
                s.reservationOpeners.removeValue(forKey: relay)
                s.renewalTasks.removeValue(forKey: relay)
                return true
            }
            return false
        }

        if removed {
            emit(.reservationExpired(relay: relay))
        }
    }

    /// Cancels a reservation and its renewal task.
    ///
    /// - Parameter relay: The relay peer to cancel reservation for.
    public func cancelReservation(on relay: PeerID) {
        clientState.withLock { s in
            s.reservations.removeValue(forKey: relay)
            s.reservationOpeners.removeValue(forKey: relay)
            s.renewalTasks[relay]?.cancel()
            s.renewalTasks.removeValue(forKey: relay)
        }
    }
}

// MARK: - StreamService

extension RelayClient: LifecycleService, StreamService {
    public func handleInboundStream(_ context: StreamContext) async {
        await handleStop(context: context)
    }
}
