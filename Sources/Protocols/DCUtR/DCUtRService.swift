/// DCUtRService - Direct Connection Upgrade through Relay service.
///
/// Coordinates hole punching to upgrade relayed connections to direct connections.

import Foundation
import Synchronization
import P2PCore
import P2PMux
import P2PProtocols

/// Configuration for DCUtRService.
public struct DCUtRConfiguration: Sendable {
    /// Timeout for hole punch attempts.
    public var timeout: Duration

    /// Maximum number of hole punch attempts per peer.
    public var maxAttempts: Int

    /// Maximum number of concurrent hole-punch upgrades across all peers.
    ///
    /// Bounds the resources an attacker can consume by triggering many
    /// simultaneous upgrades.
    public var maxConcurrentUpgrades: Int

    /// Upper bound for the measured RTT used to schedule the SYNC wait.
    ///
    /// The RTT is attacker-influenced (the remote controls response latency),
    /// so it is clamped to this maximum before being halved to avoid an
    /// attacker forcing arbitrarily long sleeps.
    public var maxEstimatedRTT: Duration

    /// Function to get local addresses for exchange.
    public var getLocalAddresses: @Sendable () -> [Multiaddr]

    /// Dialer function for responder-side hole punching.
    /// Called when the service receives SYNC from initiator.
    public var dialer: (@Sendable (Multiaddr) async throws -> Void)?

    /// Creates a new configuration.
    public init(
        timeout: Duration = .seconds(30),
        maxAttempts: Int = 3,
        maxConcurrentUpgrades: Int = 16,
        maxEstimatedRTT: Duration = .seconds(2),
        getLocalAddresses: @escaping @Sendable () -> [Multiaddr] = { [] },
        dialer: (@Sendable (Multiaddr) async throws -> Void)? = nil
    ) {
        self.timeout = timeout
        self.maxAttempts = maxAttempts
        self.maxConcurrentUpgrades = max(1, maxConcurrentUpgrades)
        self.maxEstimatedRTT = maxEstimatedRTT
        self.getLocalAddresses = getLocalAddresses
        self.dialer = dialer
    }
}

/// DCUtR (Direct Connection Upgrade through Relay) service.
///
/// Coordinates hole punching to upgrade relayed connections to direct connections.
///
/// ## Usage
///
/// ```swift
/// let dcutr = DCUtRService(configuration: .init(
///     getLocalAddresses: { node.listenAddresses }
/// ))
///
/// // Attempt to upgrade a relayed connection
/// try await dcutr.upgradeToDirectConnection(
///     with: remotePeer,
///     using: node,
///     dialer: { addr in try await node.connect(to: addr) }
/// )
/// ```
public final class DCUtRService: EventEmitting, Sendable {

    // MARK: - StreamService

    public var protocolIDs: [String] {
        [DCUtRProtocol.protocolID]
    }

    // MARK: - Properties

    /// Service configuration.
    public let configuration: DCUtRConfiguration

    /// Overridable dialer for responder-side hole punching.
    /// Set via `setDialer()` after construction (e.g., when Node injects the transport dialer).
    private let _dialerOverride: Mutex<(@Sendable (Multiaddr) async throws -> Void)?>

    /// Overridable local address provider.
    /// Set via `setLocalAddressProvider()` after construction (e.g., when traversal wires listen addresses).
    private let _localAddressProvider: Mutex<(@Sendable () -> [Multiaddr])?>

    /// Event channel (dedicated).
    private let channel = EventChannel<DCUtREvent>()

    /// Service state (separated).
    private let serviceState: Mutex<ServiceState>

    private struct ServiceState: Sendable {
        var pendingUpgrades: [PeerID: UpgradeAttempt] = [:]
        /// Count of in-flight upgrades (initiator side) for the global cap.
        var activeUpgrades: Int = 0
    }

    private struct UpgradeAttempt: Sendable {
        let peer: PeerID
        let observedAddresses: [Multiaddr]
        let startTime: ContinuousClock.Instant
        var attemptCount: Int
    }

    // MARK: - Events

    /// Stream of DCUtR events.
    public var events: AsyncStream<DCUtREvent> { channel.stream }

    // MARK: - Initialization

    /// Creates a new DCUtR service.
    ///
    /// - Parameter configuration: Service configuration.
    public init(configuration: DCUtRConfiguration = .init()) {
        self.configuration = configuration
        self._dialerOverride = Mutex(nil)
        self._localAddressProvider = Mutex(nil)
        self.serviceState = Mutex(ServiceState())
    }

    // MARK: - Post-Construction Configuration

    /// Sets the dialer function for responder-side hole punching.
    ///
    /// This resolves the chicken-and-egg problem: DCUtRService is created before
    /// the Node's transport layer is available, so the dialer is injected later.
    ///
    /// - Parameter dialer: Function that dials a given address directly.
    public func setDialer(_ dialer: @escaping @Sendable (Multiaddr) async throws -> Void) {
        _dialerOverride.withLock { $0 = dialer }
    }

    /// Sets the local address provider for address exchange during hole punching.
    ///
    /// Overrides `configuration.getLocalAddresses` with a provider that returns
    /// current listen addresses from the Node.
    ///
    /// - Parameter provider: Function returning the node's current listen addresses.
    public func setLocalAddressProvider(_ provider: @escaping @Sendable () -> [Multiaddr]) {
        _localAddressProvider.withLock { $0 = provider }
    }

    // MARK: - Public API

    /// Initiates a direct connection upgrade with a peer connected via relay.
    ///
    /// This method:
    /// 1. Opens a DCUtR stream over the relayed connection
    /// 2. Exchanges addresses with the remote peer
    /// 3. Coordinates timing for simultaneous dial (hole punching)
    /// 4. Attempts to establish a direct connection
    ///
    /// Retries up to `maxAttempts` times if hole punching fails.
    ///
    /// - Parameters:
    ///   - peer: The peer to upgrade connection with.
    ///   - opener: Stream opener for opening the DCUtR negotiation stream.
    ///   - dialer: Function to dial addresses directly.
    /// - Throws: `DCUtRError.maxAttemptsExceeded` if all attempts fail.
    public func upgradeToDirectConnection(
        with peer: PeerID,
        using opener: any StreamOpener,
        dialer: @escaping @Sendable (Multiaddr) async throws -> Void
    ) async throws {
        // Atomically: reject duplicate per-peer upgrades, enforce the global
        // concurrency cap, and reserve a slot + register the pending attempt.
        let admission: DCUtRError? = serviceState.withLock { state -> DCUtRError? in
            if state.pendingUpgrades[peer] != nil {
                return .holePunchFailed("Upgrade already in progress for peer")
            }
            if state.activeUpgrades >= configuration.maxConcurrentUpgrades {
                return .concurrencyLimitReached
            }
            state.activeUpgrades += 1
            state.pendingUpgrades[peer] = UpgradeAttempt(
                peer: peer,
                observedAddresses: [],
                startTime: .now,
                attemptCount: 0
            )
            return nil
        }
        if let admission {
            throw admission
        }

        defer {
            serviceState.withLock { state in
                state.pendingUpgrades.removeValue(forKey: peer)
                if state.activeUpgrades > 0 { state.activeUpgrades -= 1 }
            }
        }

        var lastError: Error = DCUtRError.allDialsFailed

        for attempt in 1...configuration.maxAttempts {
            serviceState.withLock { state in
                state.pendingUpgrades[peer]?.attemptCount = attempt
            }

            do {
                try await performSingleUpgradeAttempt(
                    with: peer,
                    attempt: attempt,
                    using: opener,
                    dialer: dialer
                )
                // Success - return (defer cleans up pendingUpgrades)
                return
            } catch {
                lastError = error
                emit(.holePunchAttemptFailed(
                    peer: peer,
                    attempt: attempt,
                    maxAttempts: configuration.maxAttempts,
                    reason: error.localizedDescription
                ))

                // Fatal errors - rethrow immediately without wrapping
                if case DCUtRError.noAddresses = error {
                    throw error
                }
                if case DCUtRError.protocolViolation = error {
                    throw error
                }

                // Wait before retry (exponential backoff)
                if attempt < configuration.maxAttempts {
                    let backoff = Duration.seconds(Double(1 << (attempt - 1)))
                    try await Task.sleep(for: backoff)
                }
            }
        }

        emit(.holePunchFailed(peer: peer, reason: "Max attempts exceeded (\(configuration.maxAttempts))"))
        throw DCUtRError.maxAttemptsExceeded(lastError)
    }

    /// Performs a single upgrade attempt.
    private func performSingleUpgradeAttempt(
        with peer: PeerID,
        attempt: Int,
        using opener: any StreamOpener,
        dialer: @escaping @Sendable (Multiaddr) async throws -> Void
    ) async throws {
        emit(.holePunchAttemptStarted(peer: peer, attempt: attempt))

        // Open DCUtR stream over relayed connection
        let stream = try await opener.newStream(to: peer, protocol: DCUtRProtocol.protocolID)

        do {
            // Get our local addresses (prefer override for live Node integration)
            let ourAddresses = (_localAddressProvider.withLock { $0 } ?? configuration.getLocalAddresses)()

            // Measure RTT during CONNECT exchange
            let rttStart = ContinuousClock.now

            // Send CONNECT with our observed addresses
            let connectMsg = DCUtRMessage.connect(addresses: ourAddresses)
            var connectData = ByteBuffer()
            DCUtRProtobuf.encode(connectMsg, into: &connectData)
            try await writeMessage(connectData, to: stream)

            // Receive CONNECT response with their observed addresses
            let responseData = try await readMessage(from: stream)
            let response = try DCUtRProtobuf.decode(responseData)

            // RTT is the time from sending CONNECT to receiving response. The
            // remote controls its response latency, so clamp the measurement to
            // a configured maximum before it is used to schedule the SYNC wait.
            let rawRTT = ContinuousClock.now - rttStart
            let estimatedRTT = min(rawRTT, configuration.maxEstimatedRTT)

            guard response.type == .connect else {
                throw DCUtRError.protocolViolation("Expected CONNECT response")
            }

            let theirAddresses = filterDialableAddresses(response.observedAddresses)
            emit(.addressExchangeCompleted(peer: peer, theirAddresses: theirAddresses))

            if theirAddresses.isEmpty {
                throw DCUtRError.noAddresses
            }

            // Send SYNC to coordinate timing
            let syncMsg = DCUtRMessage.sync()
            var syncData = ByteBuffer()
            DCUtRProtobuf.encode(syncMsg, into: &syncData)
            try await writeMessage(syncData, to: stream)

            // Wait RTT/2 before dialing so both sides start at approximately the same time
            try await Task.sleep(for: estimatedRTT / 2)

            // Close the DCUtR stream - we're done with negotiation
            try await stream.close()

            // Attempt to dial addresses in parallel for better hole punch success rate
            if let successAddress = await dialParallel(addresses: theirAddresses, dialer: dialer) {
                emit(.directConnectionEstablished(peer: peer, address: successAddress))
                return
            }

            // All dials failed
            emit(.holePunchFailed(peer: peer, reason: "All addresses failed"))
            throw DCUtRError.allDialsFailed

        } catch {
            do {
                try await stream.close()
            } catch {
                // Best effort cleanup only.
            }
            if let dcutrError = error as? DCUtRError {
                throw dcutrError
            }
            emit(.holePunchFailed(peer: peer, reason: error.localizedDescription))
            throw DCUtRError.holePunchFailed(error.localizedDescription)
        }
    }

    // MARK: - Protocol Handler

    /// Handles incoming DCUtR requests.
    private func handleDCUtR(context: StreamContext) async {
        let stream = context.stream
        let peer = context.remotePeer

        do {
            // Read CONNECT message
            let connectData = try await readMessage(from: stream)
            let connect = try DCUtRProtobuf.decode(connectData)

            guard connect.type == .connect else {
                throw DCUtRError.protocolViolation("Expected CONNECT")
            }

            let theirAddresses = filterDialableAddresses(connect.observedAddresses)

            // Get our local addresses (prefer override for live Node integration)
            let ourAddresses = (_localAddressProvider.withLock { $0 } ?? configuration.getLocalAddresses)()

            // Send our CONNECT response
            let response = DCUtRMessage.connect(addresses: ourAddresses)
            var responseData = ByteBuffer()
            DCUtRProtobuf.encode(response, into: &responseData)
            try await writeMessage(responseData, to: stream)

            emit(.addressExchangeCompleted(peer: peer, theirAddresses: theirAddresses))

            // Wait for SYNC
            let syncData = try await readMessage(from: stream)
            let sync = try DCUtRProtobuf.decode(syncData)

            guard sync.type == .sync else {
                throw DCUtRError.protocolViolation("Expected SYNC")
            }

            // SYNC received - start dialing on our end
            emit(.holePunchAttemptStarted(peer: peer))

            // Close the stream - negotiation complete
            try await stream.close()

            // Attempt to dial the initiator's addresses in parallel
            // This is the responder side of hole punching
            let effectiveDialer = _dialerOverride.withLock { $0 } ?? configuration.dialer
            if let dialer = effectiveDialer, !theirAddresses.isEmpty {
                if let successAddress = await dialParallel(addresses: theirAddresses, dialer: dialer) {
                    emit(.directConnectionEstablished(peer: peer, address: successAddress))
                    return
                }
                // All dials failed - this is not necessarily an error on responder side
                // as the initiator may have succeeded from their end
                emit(.holePunchFailed(peer: peer, reason: "All dial attempts failed"))
            }

        } catch {
            emit(.holePunchFailed(peer: peer, reason: error.localizedDescription))
            do {
                try await stream.close()
            } catch {
                // Best effort cleanup only.
            }
        }
    }

    // MARK: - Message I/O

    private func readMessage(from stream: MuxedStream) async throws -> ByteBuffer {
        // Apply timeout to prevent indefinite blocking on malicious/stalled peers
        let buffer: ByteBuffer = try await withTimeout(configuration.timeout) {
            do {
                return try await stream.readLengthPrefixedMessage(maxSize: UInt64(DCUtRProtocol.maxMessageSize))
            } catch let error as StreamMessageError {
                switch error {
                case .streamClosed, .emptyMessage:
                    throw DCUtRError.protocolViolation("Stream closed")
                case .messageTooLarge:
                    throw DCUtRError.protocolViolation("Message too large")
                }
            }
        }
        return buffer
    }

    /// Executes an async operation with a timeout.
    private func withTimeout<T: Sendable>(
        _ duration: Duration,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }

            group.addTask {
                try await Task.sleep(for: duration)
                throw DCUtRError.timeout
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func writeMessage(_ data: ByteBuffer, to stream: MuxedStream) async throws {
        // Apply timeout to prevent indefinite blocking
        try await withTimeout(configuration.timeout) {
            try await stream.writeLengthPrefixedMessage(data)
        }
    }

    // MARK: - Parallel Dialing

    /// Dials multiple addresses in parallel, returning the first successful address.
    ///
    /// - Parameters:
    ///   - addresses: The addresses to dial.
    ///   - dialer: The dialer function.
    /// - Returns: The first successfully connected address, or nil if all failed.
    private func dialParallel(
        addresses: [Multiaddr],
        dialer: @escaping @Sendable (Multiaddr) async throws -> Void
    ) async -> Multiaddr? {
        let timeout = configuration.timeout

        return await withTaskGroup(of: Multiaddr?.self) { group in
            for address in addresses {
                // Defense in depth: re-validate each address at dial time. An
                // address that is not a public, dialable IP (private, DNS-form,
                // IPv4-mapped private, etc.) must never be dialed for hole punching.
                guard isDialableForHolePunch(address) else { continue }
                group.addTask {
                    do {
                        // Apply timeout to each dial attempt to prevent stalling
                        try await withThrowingTaskGroup(of: Void.self) { innerGroup in
                            innerGroup.addTask {
                                try await dialer(address)
                            }
                            innerGroup.addTask {
                                try await Task.sleep(for: timeout)
                                throw DCUtRError.timeout
                            }
                            _ = try await innerGroup.next()!
                            innerGroup.cancelAll()
                        }
                        return address
                    } catch {
                        return nil
                    }
                }
            }

            // Return the first successful result
            for await result in group {
                if let address = result {
                    group.cancelAll()  // Cancel remaining dial attempts
                    return address
                }
            }
            return nil
        }
    }

    // MARK: - Address Filtering

    /// Filters addresses to only include publicly routable addresses.
    /// Private/loopback/link-local addresses cannot be dialed across NAT.
    private func filterDialableAddresses(_ addresses: [Multiaddr]) -> [Multiaddr] {
        addresses.filter { isDialableForHolePunch($0) }
    }

    /// Returns `true` only if the address is a concrete, public, dialable IP.
    ///
    /// DNS-form addresses are rejected for hole punching: they cannot be safely
    /// pre-validated (the resolved IP could be private/internal), so a numeric IP
    /// component is required and must be globally routable.
    private func isDialableForHolePunch(_ addr: Multiaddr) -> Bool {
        guard let ip = addr.ipAddress else {
            // No literal IP component (DNS form, /memory, etc.) -> not dialable.
            return false
        }
        return !isPrivateAddress(ip)
    }

    // isPrivateAddress is defined in AddressFiltering.swift (shared within module)

    // MARK: - Shutdown

    /// Shuts down the service and finishes the event stream.
    ///
    /// Call this method when the service is no longer needed to properly
    /// terminate any consumers waiting on the `events` stream.
    public func shutdown() async throws {
        _dialerOverride.withLock { $0 = nil }
        _localAddressProvider.withLock { $0 = nil }
        channel.finish()
        serviceState.withLock { state in
            state.pendingUpgrades.removeAll()
        }
    }

    // MARK: - Event Emission

    private func emit(_ event: DCUtREvent) {
        channel.yield(event)
    }
}

// MARK: - StreamService

extension DCUtRService: LifecycleService, StreamService {
    public func handleInboundStream(_ context: StreamContext) async {
        await handleDCUtR(context: context)
    }
}
