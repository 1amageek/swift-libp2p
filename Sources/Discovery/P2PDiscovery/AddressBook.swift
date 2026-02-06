/// P2PDiscovery - AddressBook
///
/// Manages address prioritization and selection for peers.
/// Wraps PeerStore to provide intelligent address ordering.

import Foundation
import P2PCore

// MARK: - Transport Priority

/// Transport types for priority ordering.
public enum TransportType: String, Sendable, Hashable, CaseIterable {
    case tcp
    case quic
    case udp
    case webSocket = "ws"
    case webSocketSecure = "wss"
    case webRTC = "webrtc"
    case memory
    case unknown

    /// Extracts transport type from a Multiaddr.
    public static func from(_ address: Multiaddr) -> TransportType {
        let protocols = address.protocols
        for proto in protocols {
            switch proto {
            case .tcp:
                // Check for WebSocket
                if protocols.contains(where: {
                    if case .ws = $0 { return true }
                    return false
                }) {
                    return .webSocket
                }
                if protocols.contains(where: {
                    if case .wss = $0 { return true }
                    return false
                }) {
                    return .webSocketSecure
                }
                return .tcp
            case .udp:
                // Check for QUIC
                if protocols.contains(where: {
                    if case .quic = $0 { return true }
                    if case .quicV1 = $0 { return true }
                    return false
                }) {
                    return .quic
                }
                return .udp
            case .memory:
                return .memory
            default:
                continue
            }
        }
        return .unknown
    }
}

// MARK: - AddressBook Configuration

/// Configuration for the address book.
public struct AddressBookConfiguration: Sendable {

    /// Transport priority order (first = highest priority).
    public var transportPriority: [TransportType]

    /// Maximum number of consecutive failures before an address is deprioritized.
    public var maxFailureCount: Int

    /// Time after which an address is considered stale.
    public var addressTTL: Duration

    /// Weight for transport priority in scoring (0.0-1.0).
    public var transportWeight: Double

    /// Weight for success history in scoring (0.0-1.0).
    public var successWeight: Double

    /// Weight for recency in scoring (0.0-1.0).
    public var recencyWeight: Double

    /// Creates a configuration.
    public init(
        transportPriority: [TransportType] = [.tcp, .quic, .udp, .webSocket, .webSocketSecure, .memory],
        maxFailureCount: Int = 3,
        addressTTL: Duration = .seconds(3600),
        transportWeight: Double = 0.4,
        successWeight: Double = 0.4,
        recencyWeight: Double = 0.2
    ) {
        self.transportPriority = transportPriority
        self.maxFailureCount = maxFailureCount
        self.addressTTL = addressTTL
        self.transportWeight = transportWeight
        self.successWeight = successWeight
        self.recencyWeight = recencyWeight
    }

    /// Default configuration.
    public static let `default` = AddressBookConfiguration()
}

// MARK: - AddressBook Protocol

/// Protocol for managing address prioritization.
///
/// AddressBook wraps a PeerStore to provide:
/// - Intelligent address sorting based on transport type and success history
/// - Automatic failure tracking
/// - Best address selection
public protocol AddressBook: Sendable {

    /// The underlying peer store.
    var peerStore: any PeerStore { get }

    /// Returns the best address for a peer.
    ///
    /// - Parameter peer: The peer to look up.
    /// - Returns: The highest-priority address, or nil if none available.
    func bestAddress(for peer: PeerID) async -> Multiaddr?

    /// Returns addresses sorted by priority (best first).
    ///
    /// - Parameter peer: The peer to look up.
    /// - Returns: Sorted array of addresses.
    func sortedAddresses(for peer: PeerID) async -> [Multiaddr]

    /// Records a successful connection to an address.
    ///
    /// - Parameters:
    ///   - address: The address that succeeded.
    ///   - peer: The peer the address belongs to.
    func recordSuccess(address: Multiaddr, for peer: PeerID) async

    /// Records a failed connection attempt to an address.
    ///
    /// - Parameters:
    ///   - address: The address that failed.
    ///   - peer: The peer the address belongs to.
    func recordFailure(address: Multiaddr, for peer: PeerID) async

    /// Calculates the priority score for an address.
    ///
    /// - Parameters:
    ///   - address: The address to score.
    ///   - peer: The peer the address belongs to.
    /// - Returns: Score from 0.0 (worst) to 1.0 (best).
    func score(address: Multiaddr, for peer: PeerID) async -> Double
}

// MARK: - Default AddressBook

/// Default implementation of AddressBook.
///
/// Uses configurable weights to calculate address priority based on:
/// 1. Transport type (configurable order)
/// 2. Connection success history
/// 3. Recency of last activity
public final class DefaultAddressBook: AddressBook, Sendable {

    // MARK: - Properties

    public let peerStore: any PeerStore
    private let configuration: AddressBookConfiguration

    // MARK: - Initialization

    /// Creates a new address book.
    ///
    /// - Parameters:
    ///   - peerStore: The underlying peer store.
    ///   - configuration: Configuration options.
    public init(
        peerStore: any PeerStore,
        configuration: AddressBookConfiguration = .default
    ) {
        self.peerStore = peerStore
        self.configuration = configuration
    }

    // MARK: - AddressBook Protocol

    public func bestAddress(for peer: PeerID) async -> Multiaddr? {
        let sorted = await sortedAddresses(for: peer)
        return sorted.first
    }

    public func sortedAddresses(for peer: PeerID) async -> [Multiaddr] {
        let addresses = await peerStore.addresses(for: peer)

        // Batch fetch all address records in a single lock acquisition
        let records = await peerStore.addressRecords(for: peer)

        // Calculate scores using pre-fetched records
        var scoredAddresses: [(address: Multiaddr, score: Double)] = []
        scoredAddresses.reserveCapacity(addresses.count)
        for address in addresses {
            let record = records[address]
            let transportScore = calculateTransportScore(for: address)
            let successScore = calculateSuccessScore(record: record)
            let recencyScore = calculateRecencyScore(record: record)
            let addressScore = transportScore * configuration.transportWeight
                + successScore * configuration.successWeight
                + recencyScore * configuration.recencyWeight
            scoredAddresses.append((address, addressScore))
        }

        // Sort by score descending
        scoredAddresses.sort { $0.score > $1.score }

        return scoredAddresses.map { $0.address }
    }

    public func recordSuccess(address: Multiaddr, for peer: PeerID) async {
        await peerStore.recordSuccess(address: address, for: peer)
    }

    public func recordFailure(address: Multiaddr, for peer: PeerID) async {
        await peerStore.recordFailure(address: address, for: peer)
    }

    public func score(address: Multiaddr, for peer: PeerID) async -> Double {
        let record = await peerStore.addressRecord(address, for: peer)

        let transportScore = calculateTransportScore(for: address)
        let successScore = calculateSuccessScore(record: record)
        let recencyScore = calculateRecencyScore(record: record)

        // Weighted combination
        let total = configuration.transportWeight * transportScore
            + configuration.successWeight * successScore
            + configuration.recencyWeight * recencyScore

        return min(max(total, 0.0), 1.0)
    }

    // MARK: - Private Methods

    /// Calculates transport priority score.
    private func calculateTransportScore(for address: Multiaddr) -> Double {
        let transportType = TransportType.from(address)

        // Guard against empty priority list (would cause division by zero)
        guard !configuration.transportPriority.isEmpty else {
            return 0.5  // Neutral score if no priority configured
        }

        if let index = configuration.transportPriority.firstIndex(of: transportType) {
            // Higher score for earlier in the priority list
            let position = Double(index)
            let total = Double(configuration.transportPriority.count)
            return 1.0 - (position / total)
        }

        // Unknown transport gets lowest score
        return 0.0
    }

    /// Calculates success history score.
    private func calculateSuccessScore(record: AddressRecord?) -> Double {
        guard let record = record else { return 0.5 }  // No history = neutral

        // Guard against zero maxFailureCount (would cause division by zero)
        let maxFailures = max(1, configuration.maxFailureCount)

        // Penalize for failures
        if record.failureCount >= maxFailures {
            return 0.0
        }

        // Bonus for having succeeded
        if record.hasSucceeded {
            // Recent success = higher score
            if !record.isRecentlyFailed {
                return 1.0
            } else {
                // Has succeeded but recently failed
                let failurePenalty = Double(record.failureCount) / Double(maxFailures)
                return 0.7 - (0.4 * failurePenalty)
            }
        }

        // Never succeeded, but not many failures
        let failurePenalty = Double(record.failureCount) / Double(maxFailures)
        return 0.5 - (0.3 * failurePenalty)
    }

    /// Calculates recency score.
    private func calculateRecencyScore(record: AddressRecord?) -> Double {
        guard let record = record else { return 0.5 }  // No history = neutral

        let now = ContinuousClock.now
        let elapsed = now - record.lastSeen

        // Convert to seconds for comparison
        let elapsedSeconds = elapsed.components.seconds
        let ttlSeconds = configuration.addressTTL.components.seconds

        // Guard against zero TTL (would cause division by zero)
        guard ttlSeconds > 0 else {
            return 0.0  // If TTL is 0, consider everything stale
        }

        if elapsedSeconds >= ttlSeconds {
            return 0.0  // Stale
        }

        // Linear decay from 1.0 to 0.0 over TTL
        return 1.0 - (Double(elapsedSeconds) / Double(ttlSeconds))
    }
}

// MARK: - AddressBook Extensions

extension AddressBook {

    /// Adds an address and returns sorted addresses.
    ///
    /// Convenience method that adds an address to the underlying peer store
    /// and returns the updated sorted list.
    public func addAndSort(address: Multiaddr, for peer: PeerID) async -> [Multiaddr] {
        await peerStore.addAddress(address, for: peer)
        return await sortedAddresses(for: peer)
    }

    /// Adds multiple addresses and returns sorted addresses.
    public func addAndSort(addresses: [Multiaddr], for peer: PeerID) async -> [Multiaddr] {
        await peerStore.addAddresses(addresses, for: peer)
        return await sortedAddresses(for: peer)
    }

    /// Returns whether a peer has any known addresses.
    public func hasAddresses(for peer: PeerID) async -> Bool {
        let addresses = await peerStore.addresses(for: peer)
        return !addresses.isEmpty
    }
}
