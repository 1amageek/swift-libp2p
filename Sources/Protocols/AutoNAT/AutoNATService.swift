/// AutoNATService - AutoNAT protocol service for detecting NAT status.
///
/// Provides both client and server functionality for the AutoNAT protocol.

import Foundation
import Synchronization
import P2PCore
import P2PMux
import P2PProtocols

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

    /// Creates a new configuration.
    public init(
        minProbes: Int = 3,
        dialTimeout: Duration = .seconds(30),
        maxAddresses: Int = 16,
        getLocalAddresses: @escaping @Sendable () -> [Multiaddr] = { [] },
        dialer: (@Sendable (Multiaddr) async throws -> Void)? = nil
    ) {
        self.minProbes = minProbes
        self.dialTimeout = dialTimeout
        self.maxAddresses = maxAddresses
        self.getLocalAddresses = getLocalAddresses
        self.dialer = dialer
    }
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
/// await autonat.registerHandler(registry: node)
///
/// // Probe to determine NAT status
/// let status = try await autonat.probe(using: node, servers: [peer1, peer2, peer3])
/// ```
public final class AutoNATService: ProtocolService, Sendable {

    // MARK: - ProtocolService

    public var protocolIDs: [String] {
        [AutoNATProtocol.protocolID]
    }

    // MARK: - Properties

    /// Service configuration.
    public let configuration: AutoNATConfiguration

    private let state: Mutex<ServiceState>

    private struct ServiceState: Sendable {
        var statusTracker: NATStatusTracker
        var eventContinuation: AsyncStream<AutoNATEvent>.Continuation?
        var eventStream: AsyncStream<AutoNATEvent>?
    }

    // MARK: - Events

    /// Stream of AutoNAT events.
    public var events: AsyncStream<AutoNATEvent> {
        state.withLock { s in
            if let existing = s.eventStream { return existing }
            let (stream, continuation) = AsyncStream<AutoNATEvent>.makeStream()
            s.eventStream = stream
            s.eventContinuation = continuation
            return stream
        }
    }

    // MARK: - Status

    /// Current NAT status.
    public var status: NATStatus {
        state.withLock { $0.statusTracker.status }
    }

    /// Current confidence level.
    public var confidence: Int {
        state.withLock { $0.statusTracker.confidence }
    }

    // MARK: - Initialization

    /// Creates a new AutoNAT service.
    ///
    /// - Parameter configuration: Service configuration.
    public init(configuration: AutoNATConfiguration = .init()) {
        self.configuration = configuration
        self.state = Mutex(ServiceState(
            statusTracker: NATStatusTracker(minProbes: configuration.minProbes)
        ))
    }

    // MARK: - Handler Registration

    /// Registers the AutoNAT protocol handler.
    ///
    /// - Parameter registry: The handler registry to register with.
    public func registerHandler(registry: any HandlerRegistry) async {
        await registry.handle(AutoNATProtocol.protocolID) { [weak self] context in
            await self?.handleAutoNAT(context: context)
        }
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
                let statusChanged = state.withLock { s in
                    s.statusTracker.recordProbe(result)
                }

                if statusChanged {
                    let newStatus = state.withLock { $0.statusTracker.status }
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
            try? await stream.close()

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
            try await stream.writeLengthPrefixedMessage(requestData)

            // Read response with timeout
            let responseData = try await withTimeout(configuration.dialTimeout) {
                try await stream.readLengthPrefixedMessage(maxSize: UInt64(AutoNATProtocol.maxMessageSize))
            }

            let response = try AutoNATProtobuf.decode(responseData)

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
        state.withLock { s in
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
            // Read request
            let requestData = try await stream.readLengthPrefixedMessage(maxSize: UInt64(AutoNATProtocol.maxMessageSize))
            let request = try AutoNATProtobuf.decode(requestData)

            guard request.type == .dial,
                  let dial = request.dial else {
                try await sendResponse(stream: stream, response: .error(.badRequest, text: "Expected DIAL"))
                return
            }

            let addresses = dial.peer.addresses
            emit(.dialBackRequested(from: remotePeer, addresses: addresses))

            // Validate addresses - only dial addresses matching observed IP
            let validAddresses = filterAddressesByObservedIP(
                addresses: addresses,
                observedAddress: remoteAddress
            )

            guard !validAddresses.isEmpty else {
                emit(.dialBackCompleted(to: remotePeer, result: .dialRefused))
                try await sendResponse(stream: stream, response: .error(.dialRefused, text: "No valid addresses"))
                return
            }

            // Attempt dial-back
            guard let dialer = configuration.dialer else {
                emit(.dialBackCompleted(to: remotePeer, result: .internalError))
                try await sendResponse(stream: stream, response: .error(.internalError, text: "Dialer not configured"))
                return
            }

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

        } catch {
            emit(.error(error.localizedDescription))
            try? await sendResponse(stream: stream, response: .error(.internalError, text: error.localizedDescription))
        }
    }

    // MARK: - Helpers

    /// Sends a dial response.
    private func sendResponse(stream: MuxedStream, response: AutoNATDialResponse) async throws {
        let message = AutoNATMessage.dialResponse(response)
        let data = AutoNATProtobuf.encode(message)
        try await stream.writeLengthPrefixedMessage(data)
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
    private func normalizeIPv6(_ ip: String) -> String {
        // Handle :: expansion by splitting into parts
        let parts = ip.split(separator: ":", omittingEmptySubsequences: false).map(String.init)

        // Check if there's a :: (which produces consecutive empty strings)
        var expandedParts: [String] = []

        // Track if we've found and expanded ::
        var foundDoubleColon = false

        for part in parts {
            if part.isEmpty {
                // Empty string indicates part of ::
                // Check if this is the start of :: (next part is also empty or this is at boundary)
                if !foundDoubleColon {
                    // This is the :: - calculate how many zeros to insert
                    // Count non-empty parts
                    let nonEmptyCount = parts.filter { !$0.isEmpty }.count
                    let zerosNeeded = 8 - nonEmptyCount

                    // Insert zeros
                    for _ in 0..<max(0, zerosNeeded) {
                        expandedParts.append("0")
                    }
                    foundDoubleColon = true

                    // Skip any subsequent empty parts (they're part of the same ::)
                }
                // If we already found ::, skip additional empty parts
            } else {
                expandedParts.append(part)
            }
        }

        // If no :: was found but we have fewer than 8 parts, something is wrong
        // but handle gracefully
        while expandedParts.count < 8 {
            expandedParts.append("0")
        }

        // Pad each part to 4 hex digits and lowercase, take first 8
        let normalized = expandedParts.prefix(8).map { part in
            let padded = String(repeating: "0", count: max(0, 4 - part.count)) + part.lowercased()
            return padded
        }

        return normalized.joined(separator: ":")
    }

    // MARK: - Shutdown

    /// Shuts down the service and finishes the event stream.
    ///
    /// Call this method when the service is no longer needed to properly
    /// terminate any consumers waiting on the `events` stream.
    public func shutdown() {
        state.withLock { s in
            s.eventContinuation?.finish()
            s.eventContinuation = nil
            s.eventStream = nil
        }
    }

    /// Emits an event.
    private func emit(_ event: AutoNATEvent) {
        let continuation = state.withLock { $0.eventContinuation }
        continuation?.yield(event)
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
