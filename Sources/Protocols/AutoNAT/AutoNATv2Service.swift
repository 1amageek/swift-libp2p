/// AutoNATv2Service - AutoNAT v2 protocol service for nonce-based reachability verification.
///
/// AutoNAT v2 improves on v1 with:
/// 1. Nonce-based verification: Server dials back and sends a nonce to prove reachability
/// 2. Amplification attack prevention: Rate limiting per server (configurable cooldown)
/// 3. Address-specific checks: Can verify specific addresses, not just general reachability

import Foundation
import Synchronization
import P2PCore
import P2PMux
import P2PProtocols

/// Logger for AutoNAT v2 operations.
private let logger = Logger(label: "p2p.autonat.v2")

/// AutoNAT v2 service for nonce-based reachability verification.
///
/// Provides both client and server functionality:
/// - **Client**: Requests reachability checks from servers with nonce verification
/// - **Server**: Responds to check requests by dialing back and sending the nonce
///
/// ## Protocol Flow
///
/// ```
/// Client                           Server
///    |                                |
///    |-- open stream ---------------->|
///    |-- DialRequest(addr, nonce) --->|
///    |                                | (dial addr)
///    |                                | (send nonce via dial-back)
///    |<-- DialResponse(status) -------|
///    |-- close stream ----------------|
/// ```
///
/// ## Usage
///
/// ```swift
/// let autonat = AutoNATv2Service(cooldownDuration: .seconds(30))
///
/// // Listen for events
/// for await event in autonat.events {
///     switch event {
///     case .reachabilityChanged(let reachability):
///         print("Reachability: \(reachability)")
///     case .checkCompleted(let address, let result):
///         print("Check for \(address): \(result)")
///     case .checkFailed(let address, let error):
///         print("Check for \(address) failed: \(error)")
///     }
/// }
/// ```
public final class AutoNATv2Service: EventEmitting, Sendable {

    // MARK: - Types

    /// Events emitted by the AutoNAT v2 service.
    public enum Event: Sendable {
        /// Overall reachability status changed.
        case reachabilityChanged(Reachability)

        /// A reachability check for a specific address completed successfully.
        case checkCompleted(address: Multiaddr, result: Reachability)

        /// A reachability check for a specific address failed.
        case checkFailed(address: Multiaddr, error: Error)
    }

    /// Reachability status of the node.
    public enum Reachability: Sendable, Equatable {
        /// Reachability has not been determined yet.
        case unknown

        /// The node is publicly reachable.
        case publiclyReachable

        /// The node is only reachable on private networks (behind NAT).
        case privateOnly
    }

    /// A pending reachability check awaiting nonce verification.
    struct PendingCheck: Sendable {
        /// The address being checked.
        let address: Multiaddr

        /// The nonce sent to the server.
        let nonce: UInt64

        /// When this check was initiated.
        let timestamp: ContinuousClock.Instant
    }

    // MARK: - EventEmitting State

    private let eventState: Mutex<EventState>

    private struct EventState: Sendable {
        var stream: AsyncStream<Event>?
        var continuation: AsyncStream<Event>.Continuation?
    }

    // MARK: - Service State

    private let serviceState: Mutex<ServiceState>

    private struct ServiceState: Sendable {
        /// Current overall reachability.
        var currentReachability: Reachability = .unknown

        /// Last time we requested a check from each peer (for cooldown).
        var lastCheckByPeer: [PeerID: ContinuousClock.Instant] = [:]

        /// Pending checks indexed by nonce.
        var pendingChecks: [UInt64: PendingCheck] = [:]

        /// Counter for successful reachability checks.
        var reachableCount: Int = 0

        /// Counter for unreachable checks.
        var unreachableCount: Int = 0
    }

    // MARK: - Properties

    /// The protocol ID for AutoNAT v2.
    public let protocolID: String = "/libp2p/autonat/2/dial-request"

    /// The dial-back protocol ID (used when server dials back to send nonce).
    public let dialBackProtocolID: String = "/libp2p/autonat/2/dial-back"

    /// The minimum cooldown between requests to the same peer.
    public let cooldownDuration: Duration

    /// Duration after which pending checks expire.
    public let checkTimeout: Duration

    // MARK: - Initialization

    /// Creates a new AutoNAT v2 service.
    ///
    /// - Parameters:
    ///   - cooldownDuration: Minimum time between requests to the same peer. Default: 30 seconds.
    ///   - checkTimeout: Duration after which pending checks expire. Default: 60 seconds.
    public init(
        cooldownDuration: Duration = .seconds(30),
        checkTimeout: Duration = .seconds(60)
    ) {
        self.cooldownDuration = cooldownDuration
        self.checkTimeout = checkTimeout
        self.eventState = Mutex(EventState())
        self.serviceState = Mutex(ServiceState())
    }

    // MARK: - EventEmitting

    /// Stream of AutoNAT v2 events (single consumer).
    public var events: AsyncStream<Event> {
        eventState.withLock { state in
            if let existing = state.stream { return existing }
            let (stream, continuation) = AsyncStream<Event>.makeStream()
            state.stream = stream
            state.continuation = continuation
            return stream
        }
    }

    /// Shuts down the service and finishes the event stream.
    public func shutdown() {
        eventState.withLock { state in
            state.continuation?.finish()
            state.continuation = nil
            state.stream = nil
        }
        serviceState.withLock { state in
            state.pendingChecks.removeAll()
            state.lastCheckByPeer.removeAll()
            state.currentReachability = .unknown
            state.reachableCount = 0
            state.unreachableCount = 0
        }
    }

    // MARK: - Client API

    /// Requests a reachability check for a specific address from a peer.
    ///
    /// - Parameters:
    ///   - address: The address to verify reachability for.
    ///   - peer: The peer to request the check from.
    ///   - opener: Stream opener to create a stream to the peer.
    /// - Returns: The reachability result for the address.
    /// - Throws: `AutoNATv2Error` if the check cannot be performed.
    public func requestCheck(
        address: Multiaddr,
        from peer: PeerID,
        using opener: any StreamOpener
    ) async throws -> Reachability {
        // Enforce cooldown
        guard canRequestFrom(peer: peer) else {
            throw AutoNATv2Error.rateLimited(peer: peer)
        }

        // Generate nonce and register pending check
        let nonce = generateNonce()
        registerPendingCheck(address: address, nonce: nonce)

        // Record this request for cooldown tracking
        recordRequest(from: peer)

        do {
            // Use a task group to enforce I/O timeout
            let dialResp: AutoNATv2Message.DialResponse = try await withThrowingTaskGroup(
                of: AutoNATv2Message.DialResponse.self
            ) { group in
                // Timeout task
                group.addTask { [checkTimeout] in
                    try await Task.sleep(for: checkTimeout)
                    throw AutoNATv2Error.timeout
                }

                // I/O task
                group.addTask { [protocolID] in
                    let stream = try await opener.newStream(to: peer, protocol: protocolID)

                    defer {
                        Task {
                            do {
                                try await stream.close()
                            } catch {
                                logger.debug("Failed to close AutoNAT v2 stream: \(error)")
                            }
                        }
                    }

                    // Send dial request
                    let request = AutoNATv2Message.dialRequest(
                        .init(address: address, nonce: nonce)
                    )
                    let requestData = AutoNATv2Codec.encode(request)
                    try await stream.writeLengthPrefixedMessage(ByteBuffer(bytes: requestData))

                    // Read response
                    let responseBuffer = try await stream.readLengthPrefixedMessage(
                        maxSize: UInt64(AutoNATProtocol.maxMessageSize)
                    )
                    let response = try AutoNATv2Codec.decode(Data(buffer: responseBuffer))

                    guard case .dialResponse(let dialResp) = response else {
                        throw AutoNATv2Error.protocolViolation("Expected DialResponse, got different message type")
                    }

                    return dialResp
                }

                // Wait for the first task to complete, cancel the other
                guard let result = try await group.next() else {
                    throw AutoNATv2Error.timeout
                }
                group.cancelAll()
                return result
            }

            // Remove the pending check
            removePendingCheck(nonce: nonce)

            // Determine reachability from response
            let reachability: Reachability
            switch dialResp.status {
            case .ok:
                reachability = .publiclyReachable
            case .dialError, .dialBackError:
                reachability = .privateOnly
            case .badRequest, .internalError:
                let events = [Event.checkFailed(
                    address: address,
                    error: AutoNATv2Error.dialBackFailed("Server returned status: \(dialResp.status)")
                )]
                emitAll(events)
                return .unknown
            }

            // Update state and emit events
            let events = updateReachability(address: address, result: reachability)
            emitAll(events)

            return reachability

        } catch {
            removePendingCheck(nonce: nonce)
            let events = [Event.checkFailed(address: address, error: error)]
            emitAll(events)
            throw error
        }
    }

    /// Returns the current reachability status.
    public var currentReachability: Reachability {
        serviceState.withLock { $0.currentReachability }
    }

    // MARK: - Server API

    /// Handles an incoming AutoNAT v2 stream (server-side).
    ///
    /// - Parameters:
    ///   - context: The stream context.
    ///   - dialer: A function to dial-back the client address and send the nonce.
    public func handleIncomingStream(
        context: StreamContext,
        dialer: @escaping @Sendable (Multiaddr, UInt64) async throws -> Void
    ) async {
        let stream = context.stream

        do {
            // Read dial request
            let requestBuffer = try await stream.readLengthPrefixedMessage(
                maxSize: UInt64(AutoNATProtocol.maxMessageSize)
            )
            let message = try AutoNATv2Codec.decode(Data(buffer: requestBuffer))

            guard case .dialRequest(let request) = message else {
                let errorResponse = AutoNATv2Message.dialResponse(
                    .init(status: .badRequest)
                )
                let data = AutoNATv2Codec.encode(errorResponse)
                try await stream.writeLengthPrefixedMessage(ByteBuffer(bytes: data))
                return
            }

            // Attempt dial-back
            do {
                try await dialer(request.address, request.nonce)

                // Dial-back succeeded
                let response = AutoNATv2Message.dialResponse(
                    .init(status: .ok, address: request.address)
                )
                let data = AutoNATv2Codec.encode(response)
                try await stream.writeLengthPrefixedMessage(ByteBuffer(bytes: data))
            } catch {
                // Dial-back failed
                let response = AutoNATv2Message.dialResponse(
                    .init(status: .dialError, address: request.address)
                )
                let data = AutoNATv2Codec.encode(response)
                try await stream.writeLengthPrefixedMessage(ByteBuffer(bytes: data))
            }

        } catch let handleError {
            logger.debug("Error handling AutoNAT v2 request: \(handleError)")
            do {
                let errorResponse = AutoNATv2Message.dialResponse(
                    .init(status: .internalError)
                )
                let data = AutoNATv2Codec.encode(errorResponse)
                try await stream.writeLengthPrefixedMessage(ByteBuffer(bytes: data))
            } catch {
                logger.debug("Failed to send AutoNAT v2 error response: \(error)")
            }
        }
    }

    // MARK: - Nonce Management

    /// Generates a cryptographically random nonce.
    ///
    /// - Returns: A random 64-bit nonce.
    func generateNonce() -> UInt64 {
        UInt64.random(in: UInt64.min...UInt64.max)
    }

    /// Registers a pending check with the given nonce.
    ///
    /// - Parameters:
    ///   - address: The address being checked.
    ///   - nonce: The nonce for verification.
    func registerPendingCheck(address: Multiaddr, nonce: UInt64) {
        serviceState.withLock { state in
            state.pendingChecks[nonce] = PendingCheck(
                address: address,
                nonce: nonce,
                timestamp: .now
            )
        }
    }

    /// Verifies a nonce received via dial-back matches a pending check.
    ///
    /// If the nonce is valid, the pending check is removed.
    ///
    /// - Parameters:
    ///   - nonce: The nonce to verify.
    ///   - address: The address associated with the nonce.
    /// - Returns: `true` if the nonce is valid and matches a pending check for the address.
    func verifyNonce(_ nonce: UInt64, for address: Multiaddr) -> Bool {
        serviceState.withLock { state in
            guard let check = state.pendingChecks[nonce] else {
                return false
            }

            // Verify address matches
            guard check.address == address else {
                return false
            }

            // Check expiry
            let elapsed = ContinuousClock.now - check.timestamp
            guard elapsed < checkTimeout else {
                state.pendingChecks.removeValue(forKey: nonce)
                return false
            }

            // Valid - remove the check
            state.pendingChecks.removeValue(forKey: nonce)
            return true
        }
    }

    /// Removes a pending check by nonce (e.g., on failure or timeout).
    func removePendingCheck(nonce: UInt64) {
        _ = serviceState.withLock { state in
            state.pendingChecks.removeValue(forKey: nonce)
        }
    }

    /// Removes expired pending checks.
    ///
    /// - Returns: The number of expired checks that were removed.
    @discardableResult
    func cleanupExpiredChecks() -> Int {
        serviceState.withLock { state in
            let now = ContinuousClock.now
            let expiredNonces = state.pendingChecks.compactMap { (nonce, check) -> UInt64? in
                let elapsed = now - check.timestamp
                return elapsed >= checkTimeout ? nonce : nil
            }

            for nonce in expiredNonces {
                state.pendingChecks.removeValue(forKey: nonce)
            }

            return expiredNonces.count
        }
    }

    /// Returns the number of currently pending checks.
    var pendingCheckCount: Int {
        serviceState.withLock { $0.pendingChecks.count }
    }

    // MARK: - Rate Limiting

    /// Checks whether a request can be made to the given peer (cooldown check).
    ///
    /// - Parameter peer: The peer to check.
    /// - Returns: `true` if the cooldown has elapsed or no previous request was made.
    func canRequestFrom(peer: PeerID) -> Bool {
        serviceState.withLock { state in
            guard let lastCheck = state.lastCheckByPeer[peer] else {
                return true
            }
            let elapsed = ContinuousClock.now - lastCheck
            return elapsed >= cooldownDuration
        }
    }

    /// Records that a request was made to the given peer.
    ///
    /// - Parameter peer: The peer the request was made to.
    private func recordRequest(from peer: PeerID) {
        serviceState.withLock { state in
            state.lastCheckByPeer[peer] = .now
        }
    }

    // MARK: - Private Helpers

    /// Emits an event.
    private func emit(_ event: Event) {
        _ = eventState.withLock { state in
            state.continuation?.yield(event)
        }
    }

    /// Emits multiple events (collected outside a Mutex lock).
    private func emitAll(_ events: [Event]) {
        for event in events {
            emit(event)
        }
    }

    /// Updates the reachability state based on a check result and returns events to emit.
    ///
    /// This method collects events inside the lock and returns them for emission outside.
    private func updateReachability(address: Multiaddr, result: Reachability) -> [Event] {
        serviceState.withLock { state -> [Event] in
            var events: [Event] = []

            // Record the check result
            events.append(.checkCompleted(address: address, result: result))

            switch result {
            case .publiclyReachable:
                state.reachableCount += 1
            case .privateOnly:
                state.unreachableCount += 1
            case .unknown:
                break
            }

            // Determine overall reachability
            let totalChecks = state.reachableCount + state.unreachableCount
            guard totalChecks >= 3 else {
                return events
            }

            let oldReachability = state.currentReachability
            if state.reachableCount > state.unreachableCount {
                state.currentReachability = .publiclyReachable
            } else if state.unreachableCount > state.reachableCount {
                state.currentReachability = .privateOnly
            }

            if state.currentReachability != oldReachability {
                events.append(.reachabilityChanged(state.currentReachability))
            }

            return events
        }
    }

    /// Resets the reachability counters and status.
    public func resetReachability() {
        let events: [Event] = serviceState.withLock { state in
            state.currentReachability = .unknown
            state.reachableCount = 0
            state.unreachableCount = 0
            return [.reachabilityChanged(.unknown)]
        }
        emitAll(events)
    }
}
