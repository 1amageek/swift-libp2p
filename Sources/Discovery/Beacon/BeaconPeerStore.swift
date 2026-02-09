import Foundation
import P2PCore

/// Two-layer peer record store: unconfirmed sightings (local only) + confirmed records (propagatable).
public protocol BeaconPeerStore: Sendable {
    // MARK: - Unconfirmed (local only)

    /// Adds or replaces an unconfirmed sighting keyed by truncated ID.
    func addSighting(_ sighting: UnconfirmedSighting)

    /// Returns sightings matching the given truncated ID.
    func sightings(matching truncID: UInt16) -> [UnconfirmedSighting]

    /// Promotes an unconfirmed sighting to a confirmed record, removing the sighting entry.
    func promoteSighting(truncID: UInt16, to record: ConfirmedPeerRecord)

    // MARK: - Confirmed (propagatable)

    /// Inserts or updates a confirmed record. Only updates if new epoch >= existing epoch.
    func upsert(_ record: ConfirmedPeerRecord)

    /// Retrieves a confirmed record by peer ID.
    func get(_ peerID: PeerID) -> ConfirmedPeerRecord?

    /// Returns all confirmed records.
    func allConfirmed() -> [ConfirmedPeerRecord]

    /// Returns confirmed records updated after the given instant.
    func confirmedNewerThan(_ since: ContinuousClock.Instant) -> [ConfirmedPeerRecord]

    /// Removes confirmed records whose TTL has expired.
    func removeExpired()
}
