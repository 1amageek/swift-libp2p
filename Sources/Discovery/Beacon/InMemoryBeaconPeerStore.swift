import Foundation
import Synchronization
import P2PCore

/// In-memory implementation of `BeaconPeerStore` using `Mutex` for thread safety.
///
/// Both the unconfirmed-sighting and confirmed-record maps are attacker-
/// influenced (any beacon source can create entries), so both are bounded to
/// prevent a Sybil memory-DoS. When a map is full, the entry closest to
/// expiry is evicted to make room.
public final class InMemoryBeaconPeerStore: BeaconPeerStore, Sendable {

    /// Default cap on the number of confirmed peer records.
    public static let defaultMaxConfirmedPeers = 4096
    /// Default cap on the number of unconfirmed sightings.
    public static let defaultMaxUnconfirmedSightings = 4096

    private struct StoreState: Sendable {
        var unconfirmed: [UInt16: UnconfirmedSighting] = [:]
        var confirmed: [PeerID: ConfirmedPeerRecord] = [:]
    }

    private let state: Mutex<StoreState>
    private let maxConfirmedPeers: Int
    private let maxUnconfirmedSightings: Int

    public init(
        maxConfirmedPeers: Int = InMemoryBeaconPeerStore.defaultMaxConfirmedPeers,
        maxUnconfirmedSightings: Int = InMemoryBeaconPeerStore.defaultMaxUnconfirmedSightings
    ) {
        precondition(maxConfirmedPeers > 0, "maxConfirmedPeers must be positive")
        precondition(maxUnconfirmedSightings > 0, "maxUnconfirmedSightings must be positive")
        self.maxConfirmedPeers = maxConfirmedPeers
        self.maxUnconfirmedSightings = maxUnconfirmedSightings
        self.state = Mutex(StoreState())
    }

    // MARK: - Unconfirmed

    public func addSighting(_ sighting: UnconfirmedSighting) {
        state.withLock { state in
            // Bound the unconfirmed map. If full and this is a new key, evict
            // the sighting whose most recent observation is oldest before
            // inserting.
            if state.unconfirmed[sighting.truncID] == nil,
               state.unconfirmed.count >= maxUnconfirmedSightings {
                if let oldest = state.unconfirmed.min(by: {
                    Self.isOlder($0.value, than: $1.value)
                }) {
                    state.unconfirmed.removeValue(forKey: oldest.key)
                }
            }
            state.unconfirmed[sighting.truncID] = sighting
        }
    }

    public func sightings(matching truncID: UInt16) -> [UnconfirmedSighting] {
        state.withLock { state in
            if let sighting = state.unconfirmed[truncID] {
                return [sighting]
            }
            return []
        }
    }

    public func promoteSighting(truncID: UInt16, to record: ConfirmedPeerRecord) {
        state.withLock { state in
            state.unconfirmed.removeValue(forKey: truncID)
            if state.confirmed[record.peerID] == nil {
                evictConfirmedIfNeeded(&state)
            }
            state.confirmed[record.peerID] = record
        }
    }

    // MARK: - Confirmed

    public func upsert(_ record: ConfirmedPeerRecord) {
        state.withLock { state in
            if let existing = state.confirmed[record.peerID] {
                guard record.epoch >= existing.epoch else { return }
            } else {
                evictConfirmedIfNeeded(&state)
            }
            state.confirmed[record.peerID] = record
        }
    }

    public func get(_ peerID: PeerID) -> ConfirmedPeerRecord? {
        state.withLock { state in
            state.confirmed[peerID]
        }
    }

    public func allConfirmed() -> [ConfirmedPeerRecord] {
        state.withLock { state in
            Array(state.confirmed.values)
        }
    }

    public func confirmedNewerThan(_ since: ContinuousClock.Instant) -> [ConfirmedPeerRecord] {
        state.withLock { state in
            state.confirmed.values.filter { $0.expiresAt > since }
        }
    }

    public func removeExpired() {
        state.withLock { state in
            let expiredKeys = state.confirmed.filter { !$0.value.isValid }.map(\.key)
            for key in expiredKeys {
                state.confirmed.removeValue(forKey: key)
            }
        }
    }

    // MARK: - Bounding

    /// Number of confirmed records currently stored (for tests and monitoring).
    public func confirmedCount() -> Int {
        state.withLock { $0.confirmed.count }
    }

    /// Number of unconfirmed sightings currently stored (for tests and monitoring).
    public func unconfirmedCount() -> Int {
        state.withLock { $0.unconfirmed.count }
    }

    /// Evicts the confirmed record closest to expiry when the map is at capacity.
    /// Called before inserting a new (not-yet-present) peer.
    private func evictConfirmedIfNeeded(_ state: inout StoreState) {
        guard state.confirmed.count >= maxConfirmedPeers else { return }
        // Prefer evicting already-expired records first; otherwise evict the one
        // whose lease ends soonest.
        if let soonest = state.confirmed.min(by: { $0.value.expiresAt < $1.value.expiresAt }) {
            state.confirmed.removeValue(forKey: soonest.key)
        }
    }

    /// Whether `lhs` is older than `rhs` by most-recent-observation timestamp.
    /// A sighting with no observations is treated as oldest (evicted first).
    private static func isOlder(_ lhs: UnconfirmedSighting, than rhs: UnconfirmedSighting) -> Bool {
        let lhsLatest = lhs.observations.map(\.timestamp).max()
        let rhsLatest = rhs.observations.map(\.timestamp).max()
        switch (lhsLatest, rhsLatest) {
        case (nil, nil): return false
        case (nil, _): return true    // lhs has no observations → older
        case (_, nil): return false   // rhs has no observations → lhs not older
        case (let l?, let r?): return l < r
        }
    }
}
