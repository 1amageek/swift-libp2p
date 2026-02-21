/// SmartDialer - Ranked parallel dialing with group delays (Happy Eyeballs).
///
/// Uses DialRanker to group and prioritize addresses, then dials groups
/// sequentially with delays between them. Within each group, addresses
/// are dialed concurrently. The first successful connection wins.

import P2PCore

/// Configuration for SmartDialer.
public struct SmartDialerConfiguration: Sendable {
    /// Overall dial timeout.
    public var dialTimeout: Duration

    /// Maximum number of concurrent dial attempts across all groups.
    public var maxConcurrentDials: Int

    /// Maximum number of addresses to dial concurrently per connection attempt (C1).
    /// This limits how many addresses from a ranked group are tried simultaneously.
    /// Default: 8 (rust-libp2p default).
    public var dialConcurrencyFactor: Int

    public init(
        dialTimeout: Duration = .seconds(30),
        maxConcurrentDials: Int = 16,
        dialConcurrencyFactor: Int = 8
    ) {
        self.dialTimeout = dialTimeout
        self.maxConcurrentDials = maxConcurrentDials
        self.dialConcurrencyFactor = dialConcurrencyFactor
    }
}

/// Dials addresses using ranked groups with Happy Eyeballs-style delays.
public final class SmartDialer: Sendable {

    /// The dial ranker for grouping addresses.
    public let dialRanker: any DialRanker

    /// Optional black hole detector for filtering unreachable paths.
    public let blackHoleDetector: BlackHoleDetector?

    /// Configuration.
    public let configuration: SmartDialerConfiguration

    /// Creates a new SmartDialer.
    ///
    /// - Parameters:
    ///   - dialRanker: Ranker for address prioritization.
    ///   - blackHoleDetector: Optional detector to filter black-holed paths.
    ///   - configuration: Dial configuration.
    public init(
        dialRanker: any DialRanker,
        blackHoleDetector: BlackHoleDetector? = nil,
        configuration: SmartDialerConfiguration = .init()
    ) {
        self.dialRanker = dialRanker
        self.blackHoleDetector = blackHoleDetector
        self.configuration = configuration
    }

    /// Dials the given addresses using ranked groups.
    ///
    /// Addresses are ranked into groups by the DialRanker. Groups are started
    /// sequentially with the specified delay between each. Within a group,
    /// all addresses are dialed concurrently. The first successful connection
    /// is returned and all remaining attempts are cancelled.
    ///
    /// - Parameters:
    ///   - addresses: Addresses to dial.
    ///   - dialFn: Closure that performs the actual dial for an address.
    /// - Returns: The peer ID and address of the successful connection.
    /// - Throws: The last error if all dial attempts fail.
    public func dialRanked(
        addresses: [Multiaddr],
        dialFn: @Sendable @escaping (Multiaddr) async throws -> PeerID
    ) async throws -> (PeerID, Multiaddr) {
        // Filter through black hole detector
        let filtered: [Multiaddr]
        if let detector = blackHoleDetector {
            filtered = detector.filterAddresses(addresses)
        } else {
            filtered = addresses
        }

        guard !filtered.isEmpty else {
            throw SmartDialerError.noAddresses
        }

        // Rank into groups
        let groups = dialRanker.rankAddresses(filtered)
        guard !groups.isEmpty else {
            throw SmartDialerError.noAddresses
        }

        // Execute groups with delays using a task group
        return try await withThrowingTaskGroup(of: (PeerID, Multiaddr).self) { group in

            // Timeout task
            group.addTask { [configuration] in
                try await Task.sleep(for: configuration.dialTimeout)
                throw SmartDialerError.timeout
            }

            // Dial task: launch groups sequentially with delays
            group.addTask { [configuration] in
                var dialCount = 0

                for dialGroup in groups {
                    try Task.checkCancellation()

                    // Wait for group delay
                    if dialGroup.delay > .zero {
                        try await Task.sleep(for: dialGroup.delay)
                    }

                    // Launch addresses in this group concurrently,
                    // limited by dialConcurrencyFactor (C1)
                    let concurrencyLimit = configuration.dialConcurrencyFactor
                    let result: (PeerID, Multiaddr)? = try await withThrowingTaskGroup(
                        of: (PeerID, Multiaddr)?.self
                    ) { innerGroup in
                        for addr in dialGroup.addresses.prefix(concurrencyLimit) {
                            guard dialCount < configuration.maxConcurrentDials else { break }
                            dialCount += 1

                            innerGroup.addTask {
                                do {
                                    let peerID = try await dialFn(addr)
                                    return (peerID, addr)
                                } catch {
                                    return nil
                                }
                            }
                        }

                        // Check results as they arrive
                        for try await maybeResult in innerGroup {
                            if let result = maybeResult {
                                innerGroup.cancelAll()
                                return result
                            }
                        }
                        return nil
                    }

                    if let result {
                        return result
                    }
                }

                // All groups exhausted
                throw SmartDialerError.allDialsFailed
            }

            // Wait for the first success
            guard let result = try await group.next() else {
                throw SmartDialerError.allDialsFailed
            }
            group.cancelAll()
            return result
        }
    }
}

/// Errors from SmartDialer.
public enum SmartDialerError: Error, Sendable {
    /// No addresses available after filtering.
    case noAddresses

    /// All dial attempts failed.
    case allDialsFailed

    /// Dial timed out.
    case timeout
}
