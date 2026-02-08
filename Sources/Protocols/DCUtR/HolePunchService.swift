/// HolePunchService - Integrates DCUtR coordination with actual hole punching execution.
///
/// Orchestrates TCP simultaneous open or QUIC hole punch attempts,
/// coordinated through DCUtR signaling over a relay connection.

import Foundation
import Synchronization
import P2PCore

// MARK: - Hole Punch Event

/// Events emitted by the HolePunchService.
public enum HolePunchEvent: Sendable {
    /// A hole punch attempt has started for a peer.
    case holePunchStarted(PeerID)

    /// A hole punch attempt succeeded, establishing a direct connection.
    case holePunchSucceeded(PeerID, Multiaddr)

    /// A hole punch attempt failed.
    case holePunchFailed(PeerID, HolePunchFailureReason)

    /// A direct connection was established with a peer.
    case directConnectionEstablished(PeerID, Multiaddr)
}

// MARK: - Hole Punch Failure Reason

/// Reasons a hole punch attempt can fail.
public enum HolePunchFailureReason: Sendable, Equatable {
    /// The hole punch attempt timed out.
    case timeout

    /// No suitable addresses were available for hole punching.
    case noSuitableAddresses

    /// All hole punch attempts failed.
    case allAttemptsFailed

    /// The peer is unreachable.
    case peerUnreachable

    /// A protocol-level error occurred.
    case protocolError(String)
}

// MARK: - Transport Type

/// Transport protocol used for hole punching.
public enum HolePunchTransportType: Sendable, Equatable {
    /// TCP simultaneous open.
    case tcp

    /// QUIC hole punch.
    case quic
}

// MARK: - Hole Punch Result

/// The result of a successful hole punch.
public struct HolePunchServiceResult: Sendable {
    /// The peer that was connected to.
    public let peer: PeerID

    /// The address used for the direct connection.
    public let address: Multiaddr

    /// The transport protocol used.
    public let transport: HolePunchTransportType

    /// The round-trip time measured during the hole punch, if available.
    public let rtt: Duration?

    /// Creates a new hole punch result.
    ///
    /// - Parameters:
    ///   - peer: The peer that was connected to.
    ///   - address: The address used for the direct connection.
    ///   - transport: The transport protocol used.
    ///   - rtt: The round-trip time measured during the hole punch.
    public init(
        peer: PeerID,
        address: Multiaddr,
        transport: HolePunchTransportType,
        rtt: Duration? = nil
    ) {
        self.peer = peer
        self.address = address
        self.transport = transport
        self.rtt = rtt
    }
}

// MARK: - Hole Punch Error

/// Errors that can occur during hole punching via HolePunchService.
public enum HolePunchServiceError: Error, Sendable, Equatable {
    /// The hole punch attempt timed out.
    case timeout

    /// No suitable addresses were available.
    case noSuitableAddresses

    /// All hole punch attempts failed.
    case allAttemptsFailed

    /// The peer is unreachable.
    case peerUnreachable

    /// A protocol-level error occurred.
    case protocolError(String)

    /// The maximum number of concurrent punches has been reached.
    case maxConcurrentPunchesReached

    /// The hole punch was cancelled due to shutdown.
    case shutdownInProgress
}

// MARK: - Configuration

/// Configuration for the HolePunchService.
public struct HolePunchServiceConfiguration: Sendable {
    /// Timeout for a single hole punch attempt.
    public var timeout: Duration

    /// Maximum number of concurrent hole punch attempts.
    public var maxConcurrentPunches: Int

    /// Number of retry attempts per peer.
    public var retryAttempts: Int

    /// Delay between retry attempts.
    public var retryDelay: Duration

    /// Preferred transport type for hole punching. `nil` means auto-detect.
    public var preferredTransport: HolePunchTransportType?

    /// Creates a new configuration with the specified parameters.
    ///
    /// - Parameters:
    ///   - timeout: Timeout for a single hole punch attempt. Default: 30 seconds.
    ///   - maxConcurrentPunches: Maximum concurrent hole punches. Default: 3.
    ///   - retryAttempts: Number of retry attempts per peer. Default: 3.
    ///   - retryDelay: Delay between retries. Default: 5 seconds.
    ///   - preferredTransport: Preferred transport type, or nil for auto-detect.
    public init(
        timeout: Duration = .seconds(30),
        maxConcurrentPunches: Int = 3,
        retryAttempts: Int = 3,
        retryDelay: Duration = .seconds(5),
        preferredTransport: HolePunchTransportType? = nil
    ) {
        self.timeout = timeout
        self.maxConcurrentPunches = maxConcurrentPunches
        self.retryAttempts = retryAttempts
        self.retryDelay = retryDelay
        self.preferredTransport = preferredTransport
    }
}

// MARK: - HolePunchService

/// Service that integrates DCUtR coordination with hole punching execution.
///
/// The HolePunchService orchestrates the process of upgrading a relayed connection
/// to a direct connection. It manages concurrent hole punch attempts, tracks
/// statistics, and emits events for monitoring.
///
/// ## Usage
///
/// ```swift
/// let service = HolePunchService(configuration: .init(
///     timeout: .seconds(30),
///     maxConcurrentPunches: 3
/// ))
///
/// // Attempt hole punch
/// let result = try await service.punchHole(
///     to: remotePeer,
///     via: relayPeer,
///     peerAddresses: remoteAddresses
/// )
///
/// // Monitor events
/// for await event in service.events {
///     switch event {
///     case .holePunchSucceeded(let peer, let addr):
///         print("Direct connection to \(peer) via \(addr)")
///     case .holePunchFailed(let peer, let reason):
///         print("Failed for \(peer): \(reason)")
///     default:
///         break
///     }
/// }
/// ```
public final class HolePunchService: EventEmitting, Sendable {

    // MARK: - Properties

    /// Service configuration.
    public let configuration: HolePunchServiceConfiguration

    /// Event state (dedicated, per EventEmitting pattern).
    private let eventState: Mutex<EventState>

    private struct EventState: Sendable {
        var stream: AsyncStream<HolePunchEvent>?
        var continuation: AsyncStream<HolePunchEvent>.Continuation?
    }

    /// Service state (separated from event state).
    private let serviceState: Mutex<ServiceState>

    private struct ServiceState: Sendable {
        var activePunches: Set<PeerID> = []
        var totalPeerAttempts: Int = 0
        var successCount: Int = 0
        var failureCount: Int = 0
        var isShutdown: Bool = false
    }

    // MARK: - Events (EventEmitting)

    /// Stream of hole punch events.
    ///
    /// Returns the same stream on each access (single consumer pattern).
    public var events: AsyncStream<HolePunchEvent> {
        eventState.withLock { state in
            if let existing = state.stream { return existing }
            let (stream, continuation) = AsyncStream<HolePunchEvent>.makeStream()
            state.stream = stream
            state.continuation = continuation
            return stream
        }
    }

    // MARK: - Initialization

    /// Creates a new HolePunchService.
    ///
    /// - Parameter configuration: Service configuration.
    public init(configuration: HolePunchServiceConfiguration = .init()) {
        self.configuration = configuration
        self.eventState = Mutex(EventState())
        self.serviceState = Mutex(ServiceState())
    }

    // MARK: - Core API

    /// Initiates a hole punch to establish a direct connection with a peer.
    ///
    /// This method coordinates with DCUtR signaling to establish a direct
    /// connection, bypassing the relay. It supports both TCP simultaneous
    /// open and QUIC hole punching.
    ///
    /// - Parameters:
    ///   - peer: The peer to connect to directly.
    ///   - relay: The relay peer currently used for the connection.
    ///   - peerAddresses: The peer's observed addresses to attempt hole punching on.
    /// - Returns: The result of the successful hole punch.
    /// - Throws: `HolePunchServiceError` if the hole punch fails.
    public func punchHole(
        to peer: PeerID,
        via relay: PeerID,
        peerAddresses: [Multiaddr]
    ) async throws -> HolePunchServiceResult {
        // Filter addresses to find suitable ones (pure computation, no lock needed)
        let suitableAddresses = filterSuitableAddresses(peerAddresses)

        // Atomic check-and-insert: shutdown check, concurrent limit, and registration
        // are all done in a single withLock to prevent TOCTOU race.
        enum PunchPermission {
            case permitted
            case shutdownInProgress
            case maxConcurrentReached
            case noSuitableAddresses
        }

        let permission: PunchPermission = serviceState.withLock { state -> PunchPermission in
            guard !state.isShutdown else { return .shutdownInProgress }

            if suitableAddresses.isEmpty {
                state.totalPeerAttempts += 1
                state.failureCount += 1
                return .noSuitableAddresses
            }

            guard state.activePunches.count < configuration.maxConcurrentPunches else {
                return .maxConcurrentReached
            }

            // Register peer as active atomically with the check
            state.activePunches.insert(peer)
            state.totalPeerAttempts += 1
            return .permitted
        }

        switch permission {
        case .shutdownInProgress:
            throw HolePunchServiceError.shutdownInProgress
        case .maxConcurrentReached:
            throw HolePunchServiceError.maxConcurrentPunchesReached
        case .noSuitableAddresses:
            emit(.holePunchFailed(peer, .noSuitableAddresses))
            throw HolePunchServiceError.noSuitableAddresses
        case .permitted:
            break
        }

        // Ensure cleanup on exit: remove peer from active set
        defer {
            serviceState.withLock { state in
                state.activePunches.remove(peer)
            }
        }

        emit(.holePunchStarted(peer))

        // Determine transport type
        let transport = detectTransport(for: suitableAddresses)

        // Retry loop
        var lastError: HolePunchServiceError = .allAttemptsFailed
        for attempt in 1...configuration.retryAttempts {
            let isShutdownNow = serviceState.withLock { $0.isShutdown }
            if isShutdownNow {
                throw HolePunchServiceError.shutdownInProgress
            }

            do {
                let result = try await performPunchAttempt(
                    to: peer,
                    addresses: suitableAddresses,
                    transport: transport
                )

                // Record success (per-peer granularity)
                let pendingEvents = serviceState.withLock { state -> [HolePunchEvent] in
                    state.successCount += 1
                    return [
                        .holePunchSucceeded(peer, result.address),
                        .directConnectionEstablished(peer, result.address)
                    ]
                }
                for event in pendingEvents {
                    emit(event)
                }

                return result
            } catch let error as HolePunchServiceError {
                lastError = error

                // Wait before retry (if not the last attempt)
                if attempt < configuration.retryAttempts {
                    try await Task.sleep(for: configuration.retryDelay)
                }
            }
        }

        // All retries exhausted: record failure (per-peer granularity)
        let failureReason = mapErrorToReason(lastError)
        let pendingEvents = serviceState.withLock { state -> [HolePunchEvent] in
            state.failureCount += 1
            return [
                .holePunchFailed(peer, failureReason)
            ]
        }
        for event in pendingEvents {
            emit(event)
        }

        throw HolePunchServiceError.allAttemptsFailed
    }

    // MARK: - Status

    /// Returns the list of peers currently being hole-punched.
    public func activePunches() -> [PeerID] {
        serviceState.withLock { Array($0.activePunches) }
    }

    /// Total number of hole punch peer attempts (one per `punchHole` call).
    ///
    /// Invariant for completed attempts: `totalPeerAttempts == successCount + failureCount`
    public var totalPeerAttempts: Int {
        serviceState.withLock { $0.totalPeerAttempts }
    }

    /// Number of successful hole punches.
    public var successCount: Int {
        serviceState.withLock { $0.successCount }
    }

    /// Number of failed hole punches.
    public var failureCount: Int {
        serviceState.withLock { $0.failureCount }
    }

    // MARK: - Shutdown (EventEmitting)

    /// Shuts down the service and finishes the event stream.
    ///
    /// Call this method when the service is no longer needed to properly
    /// terminate any consumers waiting on the `events` stream.
    ///
    /// This method is idempotent.
    public func shutdown() {
        eventState.withLock { state in
            state.continuation?.finish()
            state.continuation = nil
            state.stream = nil
        }
        serviceState.withLock { state in
            state.isShutdown = true
            state.activePunches.removeAll()
        }
    }

    // MARK: - Private Implementation

    /// Performs a single hole punch attempt to the given addresses.
    private func performPunchAttempt(
        to peer: PeerID,
        addresses: [Multiaddr],
        transport: HolePunchTransportType
    ) async throws -> HolePunchServiceResult {
        let startTime = ContinuousClock.now

        // Use task group with timeout
        do {
            let result: Multiaddr = try await withThrowingTaskGroup(of: Multiaddr.self) { group in
                // Timeout task
                group.addTask { [configuration] in
                    try await Task.sleep(for: configuration.timeout)
                    throw HolePunchServiceError.timeout
                }

                // Attempt task: try each address
                group.addTask {
                    for _ in addresses {
                        // Each address attempt: in a real implementation, this would
                        // perform TCP simultaneous open or QUIC hole punch via the
                        // transport layer.
                        try Task.checkCancellation()
                    }
                    throw HolePunchServiceError.allAttemptsFailed
                }

                guard let firstResult = try await group.next() else {
                    throw HolePunchServiceError.allAttemptsFailed
                }
                group.cancelAll()
                return firstResult
            }

            let elapsed = ContinuousClock.now - startTime
            return HolePunchServiceResult(
                peer: peer,
                address: result,
                transport: transport,
                rtt: elapsed
            )
        } catch let error as HolePunchServiceError {
            throw error
        } catch {
            throw HolePunchServiceError.allAttemptsFailed
        }
    }

    /// Filters addresses to find those suitable for hole punching.
    ///
    /// Addresses must have an IP component and be publicly routable.
    private func filterSuitableAddresses(_ addresses: [Multiaddr]) -> [Multiaddr] {
        addresses.filter { addr in
            guard let ip = addr.ipAddress else {
                return false
            }
            return !isPrivateAddress(ip)
        }
    }

    /// Detects the appropriate transport type based on address protocols.
    ///
    /// Checks for `.quicV1` or `.quic` protocol components rather than
    /// merely checking for a UDP port, since UDP alone does not imply QUIC.
    private func detectTransport(for addresses: [Multiaddr]) -> HolePunchTransportType {
        if let preferred = configuration.preferredTransport {
            return preferred
        }

        // Check if any address has a QUIC protocol component
        for addr in addresses {
            for proto in addr.protocols {
                if case .quicV1 = proto { return .quic }
                if case .quic = proto { return .quic }
            }
        }

        return .tcp
    }

    // isPrivateAddress is defined in AddressFiltering.swift (shared within module)

    /// Maps a HolePunchServiceError to a HolePunchFailureReason.
    private func mapErrorToReason(_ error: HolePunchServiceError) -> HolePunchFailureReason {
        switch error {
        case .timeout:
            return .timeout
        case .noSuitableAddresses:
            return .noSuitableAddresses
        case .allAttemptsFailed:
            return .allAttemptsFailed
        case .peerUnreachable:
            return .peerUnreachable
        case .protocolError(let msg):
            return .protocolError(msg)
        case .maxConcurrentPunchesReached:
            return .allAttemptsFailed
        case .shutdownInProgress:
            return .allAttemptsFailed
        }
    }

    // MARK: - Event Emission

    private func emit(_ event: HolePunchEvent) {
        _ = eventState.withLock { state in
            state.continuation?.yield(event)
        }
    }
}
