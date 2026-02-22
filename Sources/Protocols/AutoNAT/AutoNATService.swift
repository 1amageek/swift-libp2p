/// AutoNATService - AutoNAT protocol service for detecting NAT status.
///
/// Provides both client and server functionality for the AutoNAT protocol.

import Foundation
import Synchronization
import P2PCore
import P2PMux
import P2PProtocols

/// Logger for AutoNAT operations.
private let logger = Logger(label: "p2p.autonat")

/// Configuration for AutoNATService.
public struct AutoNATConfiguration: Sendable {
    /// Minimum number of probes to determine status.
    public var minProbes: Int

    /// Timeout for dial-back attempts.
    public var dialTimeout: Duration

    /// Maximum addresses to include in dial request.
    public var maxAddresses: Int

    /// Function to get local addresses.
    public var getLocalAddresses: @Sendable () -> [Multiaddr]

    /// Dialer function for server-side dial-back.
    public var dialer: (@Sendable (Multiaddr) async throws -> Void)?

    // MARK: - Rate Limiting

    /// Maximum requests per peer within the rate limit window.
    /// Default: 10 requests per minute.
    public var maxRequestsPerPeer: Int

    /// Rate limit time window.
    /// Default: 60 seconds.
    public var rateLimitWindow: Duration

    /// Maximum concurrent dial-back operations per peer.
    /// Default: 3.
    public var maxConcurrentDialsPerPeer: Int

    /// Maximum concurrent dial-back operations globally (all peers).
    /// Default: 50.
    public var maxConcurrentDialsGlobal: Int

    /// Maximum total requests globally within the rate limit window.
    /// Default: 500 requests per minute.
    public var maxGlobalRequests: Int

    /// Backoff duration after rate limit is exceeded.
    /// Default: 30 seconds.
    public var rateLimitBackoff: Duration

    // MARK: - Address Validation

    /// Allowed port range for dial-back (nil = all ports allowed).
    /// Use this to restrict dial-backs to specific port ranges.
    public var allowedPortRange: ClosedRange<UInt16>?

    /// Require peer ID in dial request to match the remote peer.
    /// Default: true.
    public var requirePeerIDMatch: Bool

    /// Creates a new configuration.
    public init(
        minProbes: Int = 3,
        dialTimeout: Duration = .seconds(30),
        maxAddresses: Int = 16,
        getLocalAddresses: @escaping @Sendable () -> [Multiaddr] = { [] },
        dialer: (@Sendable (Multiaddr) async throws -> Void)? = nil,
        maxRequestsPerPeer: Int = 10,
        rateLimitWindow: Duration = .seconds(60),
        maxConcurrentDialsPerPeer: Int = 3,
        maxConcurrentDialsGlobal: Int = 50,
        maxGlobalRequests: Int = 500,
        rateLimitBackoff: Duration = .seconds(30),
        allowedPortRange: ClosedRange<UInt16>? = nil,
        requirePeerIDMatch: Bool = true
    ) {
        self.minProbes = minProbes
        self.dialTimeout = dialTimeout
        self.maxAddresses = maxAddresses
        self.getLocalAddresses = getLocalAddresses
        self.dialer = dialer
        self.maxRequestsPerPeer = maxRequestsPerPeer
        self.rateLimitWindow = rateLimitWindow
        self.maxConcurrentDialsPerPeer = maxConcurrentDialsPerPeer
        self.maxConcurrentDialsGlobal = maxConcurrentDialsGlobal
        self.maxGlobalRequests = maxGlobalRequests
        self.rateLimitBackoff = rateLimitBackoff
        self.allowedPortRange = allowedPortRange
        self.requirePeerIDMatch = requirePeerIDMatch
    }
}

// MARK: - Rate Limiting State

/// Per-peer rate limiting state.
private struct PeerRateLimitState: Sendable {
    /// Recent request timestamps within the rate limit window.
    var requestTimes: [ContinuousClock.Instant] = []

    /// Current number of concurrent dial-back operations.
    var concurrentDials: Int = 0

    /// Last rejection timestamp (for backoff).
    var lastRejectedAt: ContinuousClock.Instant?
}

/// Global rate limiting state.
private struct GlobalRateLimitState: Sendable {
    /// Current total concurrent dial-back operations (all peers).
    var totalConcurrentDials: Int = 0

    /// Recent request timestamps within the rate limit window.
    var recentRequestTimes: [ContinuousClock.Instant] = []
}

/// Combined rate limiting state.
private struct RateLimitState: Sendable {
    /// Per-peer state.
    var peers: [PeerID: PeerRateLimitState] = [:]

    /// Global state.
    var global: GlobalRateLimitState = GlobalRateLimitState()
}

/// Result of rate limit check.
/// Internal visibility for testing with @testable import.
enum RateLimitResult {
    case accepted
    case rejected(RateLimitReason)
}

/// AutoNAT service for detecting NAT status.
///
/// Provides both client and server functionality:
/// - **Client**: Probes other peers to determine own NAT status
/// - **Server**: Responds to probe requests by attempting dial-backs
///
/// ## Usage
///
/// ```swift
/// let autonat = AutoNATService(configuration: .init(
///     getLocalAddresses: { node.listenAddresses },
///     dialer: { addr in try await node.connect(to: addr) }
/// ))
///
/// // Probe to determine NAT status
/// let status = try await autonat.probe(using: node, servers: [peer1, peer2, peer3])
/// ```
public final class AutoNATService: EventEmitting, Sendable {

    // MARK: - StreamService

    public var protocolIDs: [String] {
        [AutoNATProtocol.protocolID]
    }

    // MARK: - Properties

    /// Service configuration.
    public let configuration: AutoNATConfiguration

    /// Event channel (dedicated).
    private let channel = EventChannel<AutoNATEvent>()

    /// Service state (separated).
    private let serviceState: Mutex<ServiceState>

    private struct ServiceState: Sendable {
        var statusTracker: NATStatusTracker
    }

    /// Rate limiting state (separated for independent locking).
    private let rateLimitState: Mutex<RateLimitState>

    // MARK: - Events

    /// Stream of AutoNAT events.
    public var events: AsyncStream<AutoNATEvent> { channel.stream }

    // MARK: - Status

    /// Current NAT status.
    public var status: NATStatus {
        serviceState.withLock { $0.statusTracker.status }
    }

    /// Current confidence level.
    public var confidence: Int {
        serviceState.withLock { $0.statusTracker.confidence }
    }

    // MARK: - Initialization

    /// Creates a new AutoNAT service.
    ///
    /// - Parameter configuration: Service configuration.
    public init(configuration: AutoNATConfiguration = .init()) {
        self.configuration = configuration
        self.serviceState = Mutex(ServiceState(
            statusTracker: NATStatusTracker(minProbes: configuration.minProbes)
        ))
        self.rateLimitState = Mutex(RateLimitState())
    }

    // MARK: - Client API

    /// Probes multiple servers to determine NAT status.
    ///
    /// - Parameters:
    ///   - opener: Stream opener for connecting to servers.
    ///   - servers: List of servers to probe.
    /// - Returns: The determined NAT status.
    /// - Throws: `AutoNATError.noServersAvailable` if no servers provided.
    public func probe(
        using opener: any StreamOpener,
        servers: [PeerID]
    ) async throws -> NATStatus {
        guard !servers.isEmpty else {
            throw AutoNATError.noServersAvailable
        }

        // Get local addresses
        let addresses = configuration.getLocalAddresses()
        guard !addresses.isEmpty else {
            throw AutoNATError.badRequest("No local addresses available")
        }

        // Probe servers in parallel
        await withTaskGroup(of: (PeerID, ProbeResult).self) { group in
            for server in servers {
                group.addTask { [weak self] in
                    guard let self = self else {
                        return (server, .error("Service deallocated"))
                    }
                    let result = await self.probeSingleServer(
                        server: server,
                        addresses: addresses,
                        opener: opener
                    )
                    return (server, result)
                }
            }

            for await (server, result) in group {
                emit(.probeCompleted(server: server, result: result))

                // Update status tracker
                let statusChanged = serviceState.withLock { s in
                    s.statusTracker.recordProbe(result)
                }

                if statusChanged {
                    let newStatus = serviceState.withLock { $0.statusTracker.status }
                    emit(.statusChanged(newStatus))
                }
            }
        }

        return status
    }

    /// Probes a single server.
    ///
    /// - Parameters:
    ///   - server: The server to probe.
    ///   - addresses: Local addresses to include in the request.
    ///   - opener: Stream opener for connecting.
    /// - Returns: The probe result.
    public func probeSingleServer(
        server: PeerID,
        addresses: [Multiaddr],
        opener: any StreamOpener
    ) async -> ProbeResult {
        emit(.probeStarted(server: server))

        do {
            let stream = try await opener.newStream(
                to: server,
                protocol: AutoNATProtocol.protocolID
            )

            // Use structured concurrency for cleanup
            let result = await probeWithStream(
                stream: stream,
                addresses: addresses
            )

            // Always close the stream
            do {
                try await stream.close()
            } catch {
                logger.debug("Failed to close AutoNAT stream: \(error)")
            }

            return result

        } catch is TimeoutError {
            return .error("Timeout")
        } catch {
            return .error(error.localizedDescription)
        }
    }

    /// Performs the probe exchange on an established stream.
    private func probeWithStream(
        stream: MuxedStream,
        addresses: [Multiaddr]
    ) async -> ProbeResult {
        do {
            // Send DIAL request
            let limitedAddresses = Array(addresses.prefix(configuration.maxAddresses))
            let request = AutoNATMessage.dial(addresses: limitedAddresses)
            let requestData = AutoNATProtobuf.encode(request)
            try await stream.writeLengthPrefixedMessage(ByteBuffer(bytes: requestData))

            // Read response with timeout
            let responseData = try await withTimeout(configuration.dialTimeout) {
                try await stream.readLengthPrefixedMessage(maxSize: UInt64(AutoNATProtocol.maxMessageSize))
            }

            let response = try AutoNATProtobuf.decode(Data(buffer: responseData))

            guard response.type == .dialResponse,
                  let dialResponse = response.dialResponse else {
                return .error("Invalid response")
            }

            switch dialResponse.status {
            case .ok:
                if let addr = dialResponse.address {
                    return .reachable(addr)
                }
                return .error("OK response without address")
            default:
                return .unreachable(dialResponse.status)
            }

        } catch is TimeoutError {
            return .error("Timeout")
        } catch {
            return .error(error.localizedDescription)
        }
    }

    /// Resets the NAT status tracker.
    public func resetStatus() {
        serviceState.withLock { s in
            s.statusTracker.reset()
        }
        emit(.statusChanged(.unknown))
    }

    // MARK: - Server Handler

    /// Handles incoming AutoNAT requests.
    private func handleAutoNAT(context: StreamContext) async {
        let stream = context.stream
        let remotePeer = context.remotePeer
        let remoteAddress = context.remoteAddress

        do {
            // Rate limiting check
            switch shouldAcceptRequest(from: remotePeer) {
            case .accepted:
                break
            case .rejected(let reason):
                emit(.dialRequestRejected(from: remotePeer, reason: .rateLimited(reason)))
                try await sendResponse(stream: stream, response: .error(.dialRefused, text: reason.description))
                return
            }

            // Read request
            let requestBuffer = try await stream.readLengthPrefixedMessage(maxSize: UInt64(AutoNATProtocol.maxMessageSize))
            let request = try AutoNATProtobuf.decode(Data(buffer: requestBuffer))

            guard request.type == .dial,
                  let dial = request.dial else {
                try await sendResponse(stream: stream, response: .error(.badRequest, text: "Expected DIAL"))
                return
            }

            // Peer ID validation (optional)
            if configuration.requirePeerIDMatch {
                if let requestedPeerID = dial.peer.id, requestedPeerID != remotePeer {
                    emit(.dialRequestRejected(from: remotePeer, reason: .peerIDMismatch))
                    try await sendResponse(stream: stream, response: .error(.badRequest, text: "Peer ID mismatch"))
                    return
                }
            }

            let addresses = dial.peer.addresses
            emit(.dialBackRequested(from: remotePeer, addresses: addresses))

            // Validate addresses - only dial addresses matching observed IP
            var validAddresses = filterAddressesByObservedIP(
                addresses: addresses,
                observedAddress: remoteAddress
            )

            // Filter by allowed port range
            validAddresses = filterAddressesByPort(
                addresses: validAddresses,
                allowedRange: configuration.allowedPortRange
            )

            guard !validAddresses.isEmpty else {
                emit(.dialRequestRejected(from: remotePeer, reason: .noValidAddresses))
                try await sendResponse(stream: stream, response: .error(.dialRefused, text: "No valid addresses"))
                return
            }

            // Attempt dial-back
            guard let dialer = configuration.dialer else {
                emit(.dialBackCompleted(to: remotePeer, result: .internalError))
                try await sendResponse(stream: stream, response: .error(.internalError, text: "Dialer not configured"))
                return
            }

            // Track concurrent dials
            incrementConcurrentDials(for: remotePeer)
            defer { decrementConcurrentDials(for: remotePeer) }

            // Try addresses in parallel for faster dial-back
            let successAddress = await dialBackParallel(
                addresses: validAddresses,
                dialer: dialer,
                timeout: configuration.dialTimeout
            )

            if let addr = successAddress {
                emit(.dialBackCompleted(to: remotePeer, result: .ok))
                try await sendResponse(stream: stream, response: .ok(address: addr))
            } else {
                emit(.dialBackCompleted(to: remotePeer, result: .dialError))
                try await sendResponse(stream: stream, response: .error(.dialError, text: "All dials failed"))
            }

        } catch let handleError {
            emit(.error(handleError.localizedDescription))
            do {
                try await sendResponse(stream: stream, response: .error(.internalError, text: handleError.localizedDescription))
            } catch let sendError {
                logger.debug("Failed to send AutoNAT error response: \(sendError)")
            }
        }
    }

    // MARK: - Helpers

    /// Sends a dial response.
    private func sendResponse(stream: MuxedStream, response: AutoNATDialResponse) async throws {
        let message = AutoNATMessage.dialResponse(response)
        let data = AutoNATProtobuf.encode(message)
        try await stream.writeLengthPrefixedMessage(ByteBuffer(bytes: data))
        try await stream.close()
    }

    /// Filters addresses to only those matching the observed IP.
    ///
    /// This prevents amplification attacks by ensuring we only dial
    /// addresses that the client could actually be listening on.
    private func filterAddressesByObservedIP(
        addresses: [Multiaddr],
        observedAddress: Multiaddr
    ) -> [Multiaddr] {
        // Extract IP from observed address
        guard let observedIP = extractIP(from: observedAddress) else {
            return []
        }

        return addresses.filter { addr in
            guard let addrIP = extractIP(from: addr) else {
                return false
            }
            return normalizeIP(addrIP) == normalizeIP(observedIP)
        }
    }

    /// Extracts the IP address component from a multiaddr.
    private func extractIP(from addr: Multiaddr) -> String? {
        for proto in addr.protocols {
            switch proto {
            case .ip4(let ip): return ip
            case .ip6(let ip): return ip
            default: continue
            }
        }
        return nil
    }

    /// Normalizes an IP address for comparison.
    ///
    /// For IPv6, this expands the address to its full form to handle
    /// different string representations (e.g., `::1` vs `0:0:0:0:0:0:0:1`).
    private func normalizeIP(_ ip: String) -> String {
        // Check if IPv6
        if ip.contains(":") {
            return normalizeIPv6(ip)
        }
        // IPv4 - already normalized
        return ip
    }

    /// Normalizes an IPv6 address to its full expanded form.
    ///
    /// Examples:
    /// - `::1` → `0000:0000:0000:0000:0000:0000:0000:0001`
    /// - `2001:db8::1` → `2001:0db8:0000:0000:0000:0000:0000:0001`
    /// - `::` → `0000:0000:0000:0000:0000:0000:0000:0000`
    /// - `fe80::1%eth0` → `fe80:0000:0000:0000:0000:0000:0000:0001` (zone ID stripped)
    ///
    /// Returns empty string if the address is invalid.
    private func normalizeIPv6(_ ip: String) -> String {
        guard !ip.isEmpty else { return "" }

        // Strip zone identifier (e.g., %eth0, %2) if present
        let ipWithoutZone: String
        if let percentIndex = ip.firstIndex(of: "%") {
            ipWithoutZone = String(ip[..<percentIndex])
        } else {
            ipWithoutZone = ip
        }

        // Validate: must contain only hex digits and colons
        let validChars = CharacterSet(charactersIn: "0123456789abcdefABCDEF:")
        guard ipWithoutZone.unicodeScalars.allSatisfy({ validChars.contains($0) }) else {
            return ""
        }

        // Validate: only one :: allowed in IPv6
        let doubleColonCount = ipWithoutZone.components(separatedBy: "::").count - 1
        guard doubleColonCount <= 1 else { return "" }

        // Parse into 8 groups, expanding :: if present
        let parts: [String]
        if ipWithoutZone.contains("::") {
            // Split by :: (produces at most 2 halves)
            let halves = ipWithoutZone.split(separator: "::", omittingEmptySubsequences: false)
            let left = halves.first.map { $0.split(separator: ":").map(String.init) } ?? []
            let right = halves.count > 1 ? halves[1].split(separator: ":").map(String.init) : []

            // Calculate zeros needed to reach 8 groups
            let missingGroups = 8 - left.count - right.count
            guard missingGroups >= 0 else { return "" }  // Invalid: too many groups

            parts = left + Array(repeating: "0", count: missingGroups) + right
        } else {
            parts = ipWithoutZone.split(separator: ":").map(String.init)
        }

        // Must have exactly 8 groups
        guard parts.count == 8 else { return "" }

        // Normalize each group to 4-digit lowercase hex
        let normalized = parts.compactMap { part -> String? in
            guard let value = UInt16(part, radix: 16) else { return nil }
            return String(format: "%04x", value)
        }

        guard normalized.count == 8 else { return "" }
        return normalized.joined(separator: ":")
    }

    // MARK: - Shutdown

    /// Shuts down the service and finishes the event stream.
    ///
    /// Call this method when the service is no longer needed to properly
    /// terminate any consumers waiting on the `events` stream.
    public func shutdown() async {
        channel.finish()
    }

    /// Emits an event.
    private func emit(_ event: AutoNATEvent) {
        channel.yield(event)
    }

    /// Dials multiple addresses in parallel, returning the first successful address.
    private func dialBackParallel(
        addresses: [Multiaddr],
        dialer: @escaping @Sendable (Multiaddr) async throws -> Void,
        timeout: Duration
    ) async -> Multiaddr? {
        await withTaskGroup(of: Multiaddr?.self) { group in
            for address in addresses {
                group.addTask {
                    do {
                        try await withTimeout(timeout) {
                            try await dialer(address)
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
                    group.cancelAll()
                    return address
                }
            }
            return nil
        }
    }

    // MARK: - Rate Limiting

    /// Checks if a request from the given peer should be accepted.
    ///
    /// - Parameter peer: The peer making the request.
    /// - Returns: The result of the rate limit check.
    ///
    /// Internal visibility for testing with `@testable import`.
    func shouldAcceptRequest(from peer: PeerID) -> RateLimitResult {
        let now = ContinuousClock.now

        return rateLimitState.withLock { state in
            // Clean up expired timestamps from global state
            state.global.recentRequestTimes.removeAll { timestamp in
                now - timestamp > configuration.rateLimitWindow
            }

            // Check global rate limit
            if state.global.recentRequestTimes.count >= configuration.maxGlobalRequests {
                return .rejected(.globalRateLimit)
            }

            // Check global concurrency limit
            if state.global.totalConcurrentDials >= configuration.maxConcurrentDialsGlobal {
                return .rejected(.globalConcurrencyLimit)
            }

            // Get or create per-peer state
            var peerState = state.peers[peer] ?? PeerRateLimitState()

            // Check backoff period
            if let lastRejected = peerState.lastRejectedAt {
                if now - lastRejected < configuration.rateLimitBackoff {
                    return .rejected(.backoff)
                }
            }

            // Clean up expired timestamps from peer state
            peerState.requestTimes.removeAll { timestamp in
                now - timestamp > configuration.rateLimitWindow
            }

            // Check per-peer rate limit
            if peerState.requestTimes.count >= configuration.maxRequestsPerPeer {
                peerState.lastRejectedAt = now
                state.peers[peer] = peerState
                return .rejected(.peerRateLimit)
            }

            // Check per-peer concurrency limit
            if peerState.concurrentDials >= configuration.maxConcurrentDialsPerPeer {
                return .rejected(.peerConcurrencyLimit)
            }

            // Accept - update state
            peerState.requestTimes.append(now)
            state.peers[peer] = peerState
            state.global.recentRequestTimes.append(now)

            return .accepted
        }
    }

    /// Increments the concurrent dial count for a peer.
    ///
    /// - Parameter peer: The peer to increment the count for.
    private func incrementConcurrentDials(for peer: PeerID) {
        let (globalCount, globalRequests) = rateLimitState.withLock { state in
            var peerState = state.peers[peer] ?? PeerRateLimitState()
            peerState.concurrentDials += 1
            state.peers[peer] = peerState
            state.global.totalConcurrentDials += 1
            return (state.global.totalConcurrentDials, state.global.recentRequestTimes.count)
        }
        emit(.rateLimitStateChanged(globalConcurrent: globalCount, globalRequests: globalRequests))
    }

    /// Decrements the concurrent dial count for a peer.
    ///
    /// - Parameter peer: The peer to decrement the count for.
    private func decrementConcurrentDials(for peer: PeerID) {
        let (globalCount, globalRequests) = rateLimitState.withLock { state in
            if var peerState = state.peers[peer] {
                peerState.concurrentDials = max(0, peerState.concurrentDials - 1)
                state.peers[peer] = peerState
            }
            state.global.totalConcurrentDials = max(0, state.global.totalConcurrentDials - 1)
            return (state.global.totalConcurrentDials, state.global.recentRequestTimes.count)
        }
        emit(.rateLimitStateChanged(globalConcurrent: globalCount, globalRequests: globalRequests))
    }

    /// Extracts the port from a multiaddr.
    ///
    /// - Parameter addr: The multiaddr to extract from.
    /// - Returns: The port number, or nil if not found.
    private func extractPort(from addr: Multiaddr) -> UInt16? {
        for proto in addr.protocols {
            switch proto {
            case .tcp(let port), .udp(let port):
                return port
            default:
                continue
            }
        }
        return nil
    }

    /// Filters addresses by allowed port range.
    ///
    /// - Parameters:
    ///   - addresses: The addresses to filter.
    ///   - allowedRange: The allowed port range (nil = all ports allowed).
    /// - Returns: Filtered addresses.
    private func filterAddressesByPort(
        addresses: [Multiaddr],
        allowedRange: ClosedRange<UInt16>?
    ) -> [Multiaddr] {
        guard let range = allowedRange else {
            return addresses
        }

        return addresses.filter { addr in
            guard let port = extractPort(from: addr) else {
                return false
            }
            return range.contains(port)
        }
    }
}

// MARK: - StreamService

extension AutoNATService: StreamService {
    public func handleInboundStream(_ context: StreamContext) async {
        await handleAutoNAT(context: context)
    }
}

// MARK: - Timeout Helper

/// Timeout error.
private struct TimeoutError: Error {}

/// Executes an operation with a timeout.
private func withTimeout<T: Sendable>(
    _ timeout: Duration,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }

        group.addTask {
            try await Task.sleep(for: timeout)
            throw TimeoutError()
        }

        guard let result = try await group.next() else {
            throw TimeoutError()
        }

        group.cancelAll()
        return result
    }
}
