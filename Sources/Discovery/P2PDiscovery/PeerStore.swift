/// P2PDiscovery - PeerStore
///
/// Manages peer information including addresses and metadata.
/// Provides an in-memory store with LRU eviction.

import Foundation
import P2PCore
import Synchronization

// MARK: - PeerStore Protocol

/// Events emitted by the PeerStore.
public enum PeerStoreEvent: Sendable, Hashable {
    /// An address was added for a peer.
    case addressAdded(PeerID, Multiaddr)
    /// An address was removed from a peer.
    case addressRemoved(PeerID, Multiaddr)
    /// A peer was completely removed.
    case peerRemoved(PeerID)
    /// A peer's address was updated (success/failure recorded).
    case addressUpdated(PeerID, Multiaddr)
}

/// Protocol for storing and managing peer information.
///
/// PeerStore is responsible for:
/// - Storing peer addresses
/// - Tracking connection success/failure
/// - Managing peer metadata
/// - Emitting events on changes
public protocol PeerStore: Sendable {

    /// Returns all addresses known for a peer.
    ///
    /// - Parameter peer: The peer to look up.
    /// - Returns: Array of known addresses, may be empty.
    func addresses(for peer: PeerID) async -> [Multiaddr]

    /// Adds an address for a peer.
    ///
    /// If the address already exists, it updates the lastSeen timestamp.
    ///
    /// - Parameters:
    ///   - address: The address to add.
    ///   - peer: The peer to add the address for.
    func addAddress(_ address: Multiaddr, for peer: PeerID) async

    /// Adds multiple addresses for a peer.
    ///
    /// - Parameters:
    ///   - addresses: The addresses to add.
    ///   - peer: The peer to add the addresses for.
    func addAddresses(_ addresses: [Multiaddr], for peer: PeerID) async

    /// Removes an address from a peer.
    ///
    /// - Parameters:
    ///   - address: The address to remove.
    ///   - peer: The peer to remove the address from.
    func removeAddress(_ address: Multiaddr, for peer: PeerID) async

    /// Removes all information about a peer.
    ///
    /// - Parameter peer: The peer to remove.
    func removePeer(_ peer: PeerID) async

    /// Returns all known peer IDs.
    func allPeers() async -> [PeerID]

    /// Returns the number of known peers.
    func peerCount() async -> Int

    /// Returns detailed record for an address.
    ///
    /// - Parameters:
    ///   - address: The address to look up.
    ///   - peer: The peer the address belongs to.
    /// - Returns: The address record, or nil if not found.
    func addressRecord(_ address: Multiaddr, for peer: PeerID) async -> AddressRecord?

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

    /// Stream of events from the peer store.
    var events: AsyncStream<PeerStoreEvent> { get }
}

// MARK: - Address Record

/// Information about a specific address for a peer.
public struct AddressRecord: Sendable, Hashable {

    /// The address.
    public let address: Multiaddr

    /// When this address was first added.
    public let addedAt: ContinuousClock.Instant

    /// When this address was last seen (added or updated).
    public var lastSeen: ContinuousClock.Instant

    /// When a connection to this address last succeeded, if ever.
    public var lastSuccess: ContinuousClock.Instant?

    /// When a connection to this address last failed, if ever.
    public var lastFailure: ContinuousClock.Instant?

    /// Number of consecutive failures.
    public var failureCount: Int

    /// Creates a new address record.
    public init(
        address: Multiaddr,
        addedAt: ContinuousClock.Instant = .now,
        lastSeen: ContinuousClock.Instant = .now,
        lastSuccess: ContinuousClock.Instant? = nil,
        lastFailure: ContinuousClock.Instant? = nil,
        failureCount: Int = 0
    ) {
        self.address = address
        self.addedAt = addedAt
        self.lastSeen = lastSeen
        self.lastSuccess = lastSuccess
        self.lastFailure = lastFailure
        self.failureCount = failureCount
    }

    /// Whether this address has ever had a successful connection.
    public var hasSucceeded: Bool {
        lastSuccess != nil
    }

    /// Whether this address recently failed (within the last success).
    public var isRecentlyFailed: Bool {
        guard let failure = lastFailure else { return false }
        guard let success = lastSuccess else { return true }
        return failure > success
    }
}

// MARK: - Peer Record

/// Complete record for a peer.
public struct PeerRecord: Sendable {

    /// The peer ID.
    public let peerID: PeerID

    /// Known addresses for this peer.
    public var addresses: [Multiaddr: AddressRecord]

    /// When this peer was first added.
    public let addedAt: ContinuousClock.Instant

    /// When this peer was last seen (any address activity).
    public var lastSeen: ContinuousClock.Instant

    /// Creates a new peer record.
    public init(
        peerID: PeerID,
        addresses: [Multiaddr: AddressRecord] = [:],
        addedAt: ContinuousClock.Instant = .now,
        lastSeen: ContinuousClock.Instant = .now
    ) {
        self.peerID = peerID
        self.addresses = addresses
        self.addedAt = addedAt
        self.lastSeen = lastSeen
    }
}

// MARK: - Memory Peer Store Configuration

/// Configuration for MemoryPeerStore.
public struct MemoryPeerStoreConfiguration: Sendable {

    /// Maximum number of peers to store.
    public var maxPeers: Int

    /// Maximum addresses per peer.
    public var maxAddressesPerPeer: Int

    /// Creates a configuration.
    public init(
        maxPeers: Int = 1000,
        maxAddressesPerPeer: Int = 10
    ) {
        self.maxPeers = maxPeers
        self.maxAddressesPerPeer = maxAddressesPerPeer
    }

    /// Default configuration.
    public static let `default` = MemoryPeerStoreConfiguration()
}

// MARK: - Memory Peer Store

/// In-memory implementation of PeerStore with LRU eviction.
///
/// Thread-safe using actor isolation.
public actor MemoryPeerStore: PeerStore {

    // MARK: - Properties

    private let configuration: MemoryPeerStoreConfiguration
    private var peers: [PeerID: PeerRecord] = [:]

    /// Ordered list of peer IDs for LRU eviction (most recent at end).
    private var accessOrder: [PeerID] = []

    private let eventContinuation: AsyncStream<PeerStoreEvent>.Continuation
    public nonisolated let events: AsyncStream<PeerStoreEvent>

    // MARK: - Initialization

    /// Creates a new memory peer store.
    ///
    /// - Parameter configuration: Configuration options.
    public init(configuration: MemoryPeerStoreConfiguration = .default) {
        self.configuration = configuration

        var continuation: AsyncStream<PeerStoreEvent>.Continuation!
        self.events = AsyncStream { cont in
            continuation = cont
        }
        self.eventContinuation = continuation
    }

    deinit {
        eventContinuation.finish()
    }

    // MARK: - PeerStore Protocol

    public func addresses(for peer: PeerID) async -> [Multiaddr] {
        guard let record = peers[peer] else { return [] }
        touchPeer(peer)
        return Array(record.addresses.keys)
    }

    public func addAddress(_ address: Multiaddr, for peer: PeerID) async {
        await addAddresses([address], for: peer)
    }

    public func addAddresses(_ addresses: [Multiaddr], for peer: PeerID) async {
        let now = ContinuousClock.now

        if var record = peers[peer] {
            // Update existing peer
            for address in addresses {
                if record.addresses[address] != nil {
                    record.addresses[address]?.lastSeen = now
                    eventContinuation.yield(.addressUpdated(peer, address))
                } else {
                    // Add new address if under limit
                    if record.addresses.count < configuration.maxAddressesPerPeer {
                        record.addresses[address] = AddressRecord(address: address, addedAt: now, lastSeen: now)
                        eventContinuation.yield(.addressAdded(peer, address))
                    } else {
                        // Evict least recently seen address
                        evictOldestAddress(from: &record, peer: peer)
                        record.addresses[address] = AddressRecord(address: address, addedAt: now, lastSeen: now)
                        eventContinuation.yield(.addressAdded(peer, address))
                    }
                }
            }
            record.lastSeen = now
            peers[peer] = record
            touchPeer(peer)
        } else {
            // New peer
            evictPeersIfNeeded()

            var newRecord = PeerRecord(peerID: peer, addedAt: now, lastSeen: now)
            for address in addresses.prefix(configuration.maxAddressesPerPeer) {
                newRecord.addresses[address] = AddressRecord(address: address, addedAt: now, lastSeen: now)
                eventContinuation.yield(.addressAdded(peer, address))
            }
            peers[peer] = newRecord
            accessOrder.append(peer)
        }
    }

    public func removeAddress(_ address: Multiaddr, for peer: PeerID) async {
        guard var record = peers[peer] else { return }

        if record.addresses.removeValue(forKey: address) != nil {
            eventContinuation.yield(.addressRemoved(peer, address))

            if record.addresses.isEmpty {
                // Remove peer if no addresses left
                peers.removeValue(forKey: peer)
                accessOrder.removeAll { $0 == peer }
                eventContinuation.yield(.peerRemoved(peer))
            } else {
                peers[peer] = record
            }
        }
    }

    public func removePeer(_ peer: PeerID) async {
        guard let record = peers.removeValue(forKey: peer) else { return }
        accessOrder.removeAll { $0 == peer }

        // Emit address removed events for each address
        for address in record.addresses.keys {
            eventContinuation.yield(.addressRemoved(peer, address))
        }
        eventContinuation.yield(.peerRemoved(peer))
    }

    public func allPeers() async -> [PeerID] {
        Array(peers.keys)
    }

    public func peerCount() async -> Int {
        peers.count
    }

    public func addressRecord(_ address: Multiaddr, for peer: PeerID) async -> AddressRecord? {
        peers[peer]?.addresses[address]
    }

    public func recordSuccess(address: Multiaddr, for peer: PeerID) async {
        guard var record = peers[peer],
              var addrRecord = record.addresses[address] else { return }

        let now = ContinuousClock.now
        addrRecord.lastSuccess = now
        addrRecord.lastSeen = now
        addrRecord.failureCount = 0
        record.addresses[address] = addrRecord
        record.lastSeen = now
        peers[peer] = record

        touchPeer(peer)
        eventContinuation.yield(.addressUpdated(peer, address))
    }

    public func recordFailure(address: Multiaddr, for peer: PeerID) async {
        guard var record = peers[peer],
              var addrRecord = record.addresses[address] else { return }

        let now = ContinuousClock.now
        addrRecord.lastFailure = now
        addrRecord.lastSeen = now
        addrRecord.failureCount += 1
        record.addresses[address] = addrRecord
        record.lastSeen = now
        peers[peer] = record

        eventContinuation.yield(.addressUpdated(peer, address))
    }

    // MARK: - Private Methods

    /// Moves a peer to the end of the access order (most recently used).
    private func touchPeer(_ peer: PeerID) {
        if let index = accessOrder.firstIndex(of: peer) {
            accessOrder.remove(at: index)
            accessOrder.append(peer)
        }
    }

    /// Evicts peers if over the limit.
    private func evictPeersIfNeeded() {
        while peers.count >= configuration.maxPeers, let oldest = accessOrder.first {
            if let record = peers.removeValue(forKey: oldest) {
                accessOrder.removeFirst()
                for address in record.addresses.keys {
                    eventContinuation.yield(.addressRemoved(oldest, address))
                }
                eventContinuation.yield(.peerRemoved(oldest))
            }
        }
    }

    /// Evicts the oldest address from a peer record.
    private func evictOldestAddress(from record: inout PeerRecord, peer: PeerID) {
        guard let oldest = record.addresses.values.min(by: { $0.lastSeen < $1.lastSeen }) else { return }
        record.addresses.removeValue(forKey: oldest.address)
        eventContinuation.yield(.addressRemoved(peer, oldest.address))
    }
}

// MARK: - PeerStore Extension

extension PeerStore {

    /// Convenience method to add addresses from scored candidates.
    public func addCandidate(_ candidate: ScoredCandidate) async {
        await addAddresses(candidate.addresses, for: candidate.peerID)
    }

    /// Convenience method to add addresses from observations.
    public func addObservation(_ observation: Observation) async {
        await addAddresses(observation.hints, for: observation.subject)
    }
}
