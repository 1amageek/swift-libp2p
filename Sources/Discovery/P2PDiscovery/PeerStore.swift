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

    /// Returns all non-expired addresses known for a peer.
    func addresses(for peer: PeerID) async -> [Multiaddr]

    /// Adds multiple addresses for a peer with an optional TTL.
    ///
    /// If an address already exists and the new expiration is later than the current one,
    /// the expiration is extended (Go-compatible: new TTL > old TTL only).
    func addAddresses(_ addresses: [Multiaddr], for peer: PeerID, ttl: Duration?) async

    /// Removes an address from a peer.
    func removeAddress(_ address: Multiaddr, for peer: PeerID) async

    /// Removes all information about a peer.
    func removePeer(_ peer: PeerID) async

    /// Returns all known peer IDs.
    func allPeers() async -> [PeerID]

    /// Returns the number of known peers.
    func peerCount() async -> Int

    /// Returns detailed record for an address.
    func addressRecord(_ address: Multiaddr, for peer: PeerID) async -> AddressRecord?

    /// Returns all address records for a peer in a single lock acquisition.
    func addressRecords(for peer: PeerID) async -> [Multiaddr: AddressRecord]

    /// Records a successful connection to an address.
    func recordSuccess(address: Multiaddr, for peer: PeerID) async

    /// Records a failed connection attempt to an address.
    func recordFailure(address: Multiaddr, for peer: PeerID) async

    /// Stream of events from the peer store.
    ///
    /// Each access returns an independent subscriber stream (multi-consumer).
    var events: AsyncStream<PeerStoreEvent> { get }
}

// MARK: - PeerStore Convenience Extensions

extension PeerStore {

    /// Adds a single address for a peer with no explicit TTL (uses store default).
    public func addAddress(_ address: Multiaddr, for peer: PeerID) async {
        await addAddresses([address], for: peer, ttl: nil)
    }

    /// Adds multiple addresses for a peer with no explicit TTL (uses store default).
    public func addAddresses(_ addresses: [Multiaddr], for peer: PeerID) async {
        await addAddresses(addresses, for: peer, ttl: nil)
    }
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

    /// Expiration time. nil = never expires.
    public var expiresAt: ContinuousClock.Instant?

    /// Creates a new address record.
    public init(
        address: Multiaddr,
        addedAt: ContinuousClock.Instant = .now,
        lastSeen: ContinuousClock.Instant = .now,
        lastSuccess: ContinuousClock.Instant? = nil,
        lastFailure: ContinuousClock.Instant? = nil,
        failureCount: Int = 0,
        expiresAt: ContinuousClock.Instant? = nil
    ) {
        self.address = address
        self.addedAt = addedAt
        self.lastSeen = lastSeen
        self.lastSuccess = lastSuccess
        self.lastFailure = lastFailure
        self.failureCount = failureCount
        self.expiresAt = expiresAt
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

    /// Whether this address has expired.
    public var isExpired: Bool {
        guard let expiresAt else { return false }
        return ContinuousClock.now >= expiresAt
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

    /// Default TTL for addresses when no explicit TTL is provided.
    /// `nil` = addresses never expire.
    public var defaultAddressTTL: Duration?

    /// Interval for background garbage collection of expired addresses.
    /// `nil` = GC disabled.
    public var gcInterval: Duration?

    /// Creates a configuration.
    public init(
        maxPeers: Int = 1000,
        maxAddressesPerPeer: Int = 10,
        defaultAddressTTL: Duration? = .seconds(3600),
        gcInterval: Duration? = .seconds(60)
    ) {
        self.maxPeers = maxPeers
        self.maxAddressesPerPeer = maxAddressesPerPeer
        self.defaultAddressTTL = defaultAddressTTL
        self.gcInterval = gcInterval
    }

    /// Default configuration.
    public static let `default` = MemoryPeerStoreConfiguration()
}

// MARK: - Memory Peer Store

/// In-memory implementation of PeerStore with LRU eviction.
///
/// Uses `Mutex` for thread-safe high-frequency access.
/// Events are distributed via `EventBroadcaster` (multi-consumer).
public final class MemoryPeerStore: PeerStore, Sendable {

    // MARK: - State

    private let configuration: MemoryPeerStoreConfiguration
    private let state: Mutex<State>
    private let broadcaster = EventBroadcaster<PeerStoreEvent>()

    private struct State: Sendable {
        var peers: [PeerID: PeerRecord] = [:]
        var accessOrder = LRUOrder<PeerID>()
        var gcTask: Task<Void, Never>?
    }

    // MARK: - Initialization

    public init(configuration: MemoryPeerStoreConfiguration = .default) {
        self.configuration = configuration
        self.state = Mutex(State())
    }

    deinit {
        state.withLock { $0.gcTask?.cancel() }
        broadcaster.shutdown()
    }

    // MARK: - Lifecycle

    /// Shuts down the peer store: stops GC and terminates all event streams.
    public func shutdown() {
        state.withLock { s in
            s.gcTask?.cancel()
            s.gcTask = nil
        }
        broadcaster.shutdown()
    }

    // MARK: - PeerStore Protocol

    public var events: AsyncStream<PeerStoreEvent> {
        broadcaster.subscribe()
    }

    public func addresses(for peer: PeerID) async -> [Multiaddr] {
        state.withLock { s in
            guard let record = s.peers[peer] else { return [] }
            touchPeer(peer, state: &s)
            return record.addresses.values
                .filter { !$0.isExpired }
                .map(\.address)
        }
    }

    public func addAddresses(_ addresses: [Multiaddr], for peer: PeerID, ttl: Duration?) async {
        let pendingEvents = state.withLock { s -> [PeerStoreEvent] in
            let now = ContinuousClock.now
            let effectiveTTL = ttl ?? configuration.defaultAddressTTL
            let expiresAt = effectiveTTL.map { now + $0 }
            var events: [PeerStoreEvent] = []

            if var record = s.peers[peer] {
                for address in addresses {
                    if var existing = record.addresses[address] {
                        existing.lastSeen = now
                        // Go-compatible: extend TTL only if new expiration is later
                        if let newExpiry = expiresAt {
                            if let oldExpiry = existing.expiresAt {
                                if newExpiry > oldExpiry {
                                    existing.expiresAt = newExpiry
                                }
                            }
                            // else: old was permanent, keep permanent
                        }
                        // nil TTL = upgrade to permanent
                        if expiresAt == nil {
                            existing.expiresAt = nil
                        }
                        record.addresses[address] = existing
                        events.append(.addressUpdated(peer, address))
                    } else {
                        if record.addresses.count < configuration.maxAddressesPerPeer {
                            record.addresses[address] = AddressRecord(
                                address: address, addedAt: now, lastSeen: now, expiresAt: expiresAt
                            )
                            events.append(.addressAdded(peer, address))
                        } else {
                            if let evicted = evictOldestAddress(from: &record) {
                                events.append(.addressRemoved(peer, evicted))
                            }
                            record.addresses[address] = AddressRecord(
                                address: address, addedAt: now, lastSeen: now, expiresAt: expiresAt
                            )
                            events.append(.addressAdded(peer, address))
                        }
                    }
                }
                record.lastSeen = now
                s.peers[peer] = record
                touchPeer(peer, state: &s)
            } else {
                events.append(contentsOf: evictPeersIfNeeded(state: &s))
                var newRecord = PeerRecord(peerID: peer, addedAt: now, lastSeen: now)
                for address in addresses.prefix(configuration.maxAddressesPerPeer) {
                    newRecord.addresses[address] = AddressRecord(
                        address: address, addedAt: now, lastSeen: now, expiresAt: expiresAt
                    )
                    events.append(.addressAdded(peer, address))
                }
                s.peers[peer] = newRecord
                s.accessOrder.insert(peer)
            }
            return events
        }
        for event in pendingEvents {
            broadcaster.emit(event)
        }
    }

    /// Restores addresses from persistent storage with their original metadata.
    ///
    /// Unlike `addAddresses`, this preserves failure counts and does not emit events,
    /// since the data is being loaded (not newly discovered).
    /// This method is intended for use by persistence layers (e.g., FilePeerStore).
    public func restoreAddresses(
        _ restoredAddresses: [(address: Multiaddr, failureCount: Int)],
        for peer: PeerID,
        ttl: Duration?
    ) {
        state.withLock { s in
            let now = ContinuousClock.now
            let effectiveTTL = ttl ?? configuration.defaultAddressTTL
            let expiresAt = effectiveTTL.map { now + $0 }

            if var record = s.peers[peer] {
                for entry in restoredAddresses {
                    if record.addresses.count < configuration.maxAddressesPerPeer {
                        record.addresses[entry.address] = AddressRecord(
                            address: entry.address,
                            addedAt: now,
                            lastSeen: now,
                            failureCount: entry.failureCount,
                            expiresAt: expiresAt
                        )
                    }
                }
                record.lastSeen = now
                s.peers[peer] = record
                touchPeer(peer, state: &s)
            } else {
                var newRecord = PeerRecord(peerID: peer, addedAt: now, lastSeen: now)
                for entry in restoredAddresses.prefix(configuration.maxAddressesPerPeer) {
                    newRecord.addresses[entry.address] = AddressRecord(
                        address: entry.address,
                        addedAt: now,
                        lastSeen: now,
                        failureCount: entry.failureCount,
                        expiresAt: expiresAt
                    )
                }
                s.peers[peer] = newRecord
                s.accessOrder.insert(peer)
            }
        }
    }

    public func removeAddress(_ address: Multiaddr, for peer: PeerID) async {
        let pendingEvents = state.withLock { s -> [PeerStoreEvent] in
            guard var record = s.peers[peer] else { return [] }
            var events: [PeerStoreEvent] = []
            if record.addresses.removeValue(forKey: address) != nil {
                events.append(.addressRemoved(peer, address))
                if record.addresses.isEmpty {
                    s.peers.removeValue(forKey: peer)
                    s.accessOrder.remove(peer)
                    events.append(.peerRemoved(peer))
                } else {
                    s.peers[peer] = record
                }
            }
            return events
        }
        for event in pendingEvents {
            broadcaster.emit(event)
        }
    }

    public func removePeer(_ peer: PeerID) async {
        let pendingEvents = state.withLock { s -> [PeerStoreEvent] in
            guard let record = s.peers.removeValue(forKey: peer) else { return [] }
            s.accessOrder.remove(peer)
            var events: [PeerStoreEvent] = []
            for address in record.addresses.keys {
                events.append(.addressRemoved(peer, address))
            }
            events.append(.peerRemoved(peer))
            return events
        }
        for event in pendingEvents {
            broadcaster.emit(event)
        }
    }

    public func allPeers() async -> [PeerID] {
        state.withLock { Array($0.peers.keys) }
    }

    public func peerCount() async -> Int {
        state.withLock { $0.peers.count }
    }

    public func addressRecord(_ address: Multiaddr, for peer: PeerID) async -> AddressRecord? {
        state.withLock { $0.peers[peer]?.addresses[address] }
    }

    public func addressRecords(for peer: PeerID) async -> [Multiaddr: AddressRecord] {
        state.withLock { $0.peers[peer]?.addresses ?? [:] }
    }

    public func recordSuccess(address: Multiaddr, for peer: PeerID) async {
        let event = state.withLock { s -> PeerStoreEvent? in
            guard var record = s.peers[peer],
                  var addrRecord = record.addresses[address] else { return nil }
            let now = ContinuousClock.now
            addrRecord.lastSuccess = now
            addrRecord.lastSeen = now
            addrRecord.failureCount = 0
            record.addresses[address] = addrRecord
            record.lastSeen = now
            s.peers[peer] = record
            touchPeer(peer, state: &s)
            return .addressUpdated(peer, address)
        }
        if let event {
            broadcaster.emit(event)
        }
    }

    public func recordFailure(address: Multiaddr, for peer: PeerID) async {
        let event = state.withLock { s -> PeerStoreEvent? in
            guard var record = s.peers[peer],
                  var addrRecord = record.addresses[address] else { return nil }
            let now = ContinuousClock.now
            addrRecord.lastFailure = now
            addrRecord.lastSeen = now
            addrRecord.failureCount += 1
            record.addresses[address] = addrRecord
            record.lastSeen = now
            s.peers[peer] = record
            touchPeer(peer, state: &s)
            return .addressUpdated(peer, address)
        }
        if let event {
            broadcaster.emit(event)
        }
    }

    // MARK: - Garbage Collection

    /// Removes all expired addresses and peers with no remaining addresses.
    @discardableResult
    public func cleanup() -> Int {
        let (totalRemoved, pendingEvents) = state.withLock { s -> (Int, [PeerStoreEvent]) in
            var totalRemoved = 0
            var events: [PeerStoreEvent] = []
            var peersToRemove: [PeerID] = []

            for (peerID, var record) in s.peers {
                let expiredAddrs = record.addresses.filter { $0.value.isExpired }
                for (addr, _) in expiredAddrs {
                    record.addresses.removeValue(forKey: addr)
                    events.append(.addressRemoved(peerID, addr))
                }
                totalRemoved += expiredAddrs.count
                if record.addresses.isEmpty {
                    peersToRemove.append(peerID)
                } else if !expiredAddrs.isEmpty {
                    s.peers[peerID] = record
                }
            }

            for peerID in peersToRemove {
                s.peers.removeValue(forKey: peerID)
                s.accessOrder.remove(peerID)
                events.append(.peerRemoved(peerID))
            }
            return (totalRemoved, events)
        }
        for event in pendingEvents {
            broadcaster.emit(event)
        }
        return totalRemoved
    }

    /// Starts the background garbage collection task.
    public func startGC() {
        guard let interval = configuration.gcInterval else { return }
        state.withLock { s in
            guard s.gcTask == nil else { return }
            s.gcTask = Task { [weak self] in
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: interval)
                        self?.cleanup()
                    } catch {
                        break
                    }
                }
            }
        }
    }

    /// Stops the background garbage collection task.
    public func stopGC() {
        state.withLock { s in
            s.gcTask?.cancel()
            s.gcTask = nil
        }
    }

    // MARK: - Private

    private func touchPeer(_ peer: PeerID, state s: inout State) {
        s.accessOrder.touch(peer)
    }

    private func evictPeersIfNeeded(state s: inout State) -> [PeerStoreEvent] {
        var events: [PeerStoreEvent] = []
        while s.peers.count >= configuration.maxPeers, let oldest = s.accessOrder.removeOldest() {
            if let record = s.peers.removeValue(forKey: oldest) {
                for address in record.addresses.keys {
                    events.append(.addressRemoved(oldest, address))
                }
                events.append(.peerRemoved(oldest))
            }
        }
        return events
    }

    private func evictOldestAddress(from record: inout PeerRecord) -> Multiaddr? {
        guard let oldest = record.addresses.values.min(by: { $0.lastSeen < $1.lastSeen }) else {
            return nil
        }
        record.addresses.removeValue(forKey: oldest.address)
        return oldest.address
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
