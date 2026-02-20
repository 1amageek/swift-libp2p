/// DialBackoff - Centralized per-peer dial backoff tracker
///
/// Prevents redundant dial attempts by tracking failed dials per peer
/// with exponential backoff. ALL dial paths (ReconnectionPolicy, Discovery
/// auto-connect, manual connect) should check this before dialing.
///
/// This is analogous to go-libp2p's `swarm.DialBackoff`.

import Foundation
import Synchronization
import P2PCore

/// Centralized per-peer dial backoff tracker.
///
/// When a dial attempt fails, the peer is "backed off" for an increasing
/// duration. Subsequent dial attempts to the same peer are suppressed
/// until the backoff expires.
///
/// ## Usage
/// ```swift
/// let backoff = DialBackoff()
///
/// // Before dialing:
/// guard !backoff.shouldBackOff(from: peer) else { return }
///
/// // On failure:
/// backoff.recordFailure(for: peer)
///
/// // On success:
/// backoff.recordSuccess(for: peer)
/// ```
internal final class DialBackoff: Sendable {

    private struct Entry: Sendable {
        var attempts: Int
        var backoffUntil: ContinuousClock.Instant
    }

    private let state: Mutex<[PeerID: Entry]>
    private let backoff: BackoffStrategy

    /// Creates a new dial backoff tracker.
    ///
    /// - Parameter backoff: The backoff strategy for calculating delays.
    ///   Defaults to exponential (100ms base, 2x, 5min max, 10% jitter).
    init(backoff: BackoffStrategy = .default) {
        self.state = Mutex([:])
        self.backoff = backoff
    }

    /// Returns true if a dial to this peer should be suppressed.
    ///
    /// - Parameter peer: The peer to check
    /// - Returns: true if the peer is currently backed off
    func shouldBackOff(from peer: PeerID) -> Bool {
        state.withLock { entries in
            guard let entry = entries[peer] else { return false }
            if ContinuousClock.now >= entry.backoffUntil {
                // Backoff expired — clean up lazily
                entries.removeValue(forKey: peer)
                return false
            }
            return true
        }
    }

    /// Records a failed dial attempt. Increases the backoff duration.
    ///
    /// Each subsequent failure doubles the backoff (per the strategy).
    ///
    /// - Parameter peer: The peer whose dial failed
    func recordFailure(for peer: PeerID) {
        state.withLock { entries in
            let existing = entries[peer]
            let attempts = (existing?.attempts ?? 0) + 1
            let delay = backoff.delay(for: attempts - 1)
            entries[peer] = Entry(
                attempts: attempts,
                backoffUntil: ContinuousClock.now + delay
            )
        }
    }

    /// Records a successful connection. Clears all backoff for the peer.
    ///
    /// - Parameter peer: The peer that connected successfully
    func recordSuccess(for peer: PeerID) {
        state.withLock { entries in
            _ = entries.removeValue(forKey: peer)
        }
    }

    /// Returns the number of consecutive failed attempts for a peer.
    ///
    /// - Parameter peer: The peer to check
    /// - Returns: The failure count (0 if not backed off)
    func failureCount(for peer: PeerID) -> Int {
        state.withLock { entries in
            entries[peer]?.attempts ?? 0
        }
    }

    /// Removes expired backoff entries to reclaim memory.
    ///
    /// Called periodically (e.g., during idle check).
    func cleanup() {
        let now = ContinuousClock.now
        state.withLock { entries in
            entries = entries.filter { $0.value.backoffUntil > now }
        }
    }

    /// Clears all backoff state. Called during shutdown.
    func clear() {
        state.withLock { $0.removeAll() }
    }
}
