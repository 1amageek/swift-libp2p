import Foundation
import Synchronization
import P2PCore

/// In-memory implementation of `BeaconPeerStore` using `Mutex` for thread safety.
public final class InMemoryBeaconPeerStore: BeaconPeerStore, Sendable {

    private struct StoreState: Sendable {
        var unconfirmed: [UInt16: UnconfirmedSighting] = [:]
        var confirmed: [PeerID: ConfirmedPeerRecord] = [:]
    }

    private let state: Mutex<StoreState>

    public init() {
        self.state = Mutex(StoreState())
    }

    // MARK: - Unconfirmed

    public func addSighting(_ sighting: UnconfirmedSighting) {
        state.withLock { state in
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
            state.confirmed[record.peerID] = record
        }
    }

    // MARK: - Confirmed

    public func upsert(_ record: ConfirmedPeerRecord) {
        state.withLock { state in
            if let existing = state.confirmed[record.peerID] {
                guard record.epoch >= existing.epoch else { return }
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
}
