/// GossipPromises - Tracks IWANT promises and detects broken promises.
import Foundation
import Synchronization
import P2PCore

/// Tracks IWANT promises and detects broken promises.
///
/// When we send an IWANT to a peer, we expect them to deliver the message
/// within a timeout period. If they don't, we record a broken promise
/// which contributes to their behavioral penalty score.
final class GossipPromises: Sendable {
    private struct State: Sendable {
        /// Maps message ID → (peer ID → expiration time).
        var promises: [MessageID: [PeerID: ContinuousClock.Instant]] = [:]
        /// Per-peer count of outstanding promises (for O(1) per-peer bounding).
        var perPeerCount: [PeerID: Int] = [:]
        /// Total number of outstanding (messageID, peer) promises.
        var total: Int = 0
    }

    private let state: Mutex<State>

    init() {
        self.state = Mutex(State())
    }

    /// Records that peer promised to deliver these messages.
    ///
    /// Promises are bounded both globally (`maxTotal`) and per-peer
    /// (`maxPerPeer`). Once a peer or the global table reaches its cap, further
    /// promises from that peer are rejected (dropped explicitly, not silently
    /// accepted into an unbounded map). This prevents a memory-DoS via an
    /// IHAVE flood that would otherwise grow `promises` without limit.
    ///
    /// - Returns: The number of promises actually recorded.
    @discardableResult
    func addPromise(
        peer: PeerID,
        messageIDs: [MessageID],
        expires: ContinuousClock.Instant,
        maxTotal: Int,
        maxPerPeer: Int
    ) -> Int {
        state.withLock { state in
            var added = 0
            for msgID in messageIDs {
                // Respect global and per-peer caps.
                guard state.total < maxTotal else { break }
                guard (state.perPeerCount[peer] ?? 0) < maxPerPeer else { break }

                // Only count a genuinely new (msgID, peer) pair.
                if state.promises[msgID]?[peer] == nil {
                    state.promises[msgID, default: [:]][peer] = expires
                    state.perPeerCount[peer, default: 0] += 1
                    state.total += 1
                    added += 1
                } else {
                    // Refresh expiry without changing counts.
                    state.promises[msgID]?[peer] = expires
                }
            }
            return added
        }
    }

    /// Called when a message is delivered (from any peer).
    /// Removes all promises for this message.
    func messageDelivered(_ messageID: MessageID) {
        state.withLock { state in
            guard let peerMap = state.promises.removeValue(forKey: messageID) else { return }
            for peer in peerMap.keys {
                decrementPeer(peer, in: &state)
            }
        }
    }

    /// Returns peers with broken promises (expired and undelivered).
    /// Called during heartbeat.
    func getBrokenPromises() -> [PeerID: Int] {
        let now = ContinuousClock.now
        var brokenCounts: [PeerID: Int] = [:]

        state.withLock { state in
            var toRemove: [MessageID] = []

            for (msgID, peerMap) in state.promises {
                var remaining = peerMap
                for (peer, expiry) in peerMap {
                    if now >= expiry {
                        brokenCounts[peer, default: 0] += 1
                        // The promise is resolved (as broken); drop it and
                        // keep the counters consistent.
                        remaining.removeValue(forKey: peer)
                        decrementPeer(peer, in: &state)
                    }
                }
                if remaining.isEmpty {
                    toRemove.append(msgID)
                } else {
                    state.promises[msgID] = remaining
                }
            }

            for msgID in toRemove {
                state.promises.removeValue(forKey: msgID)
            }
        }

        return brokenCounts
    }

    /// Current total number of outstanding promises (for diagnostics/tests).
    var count: Int {
        state.withLock { $0.total }
    }

    func clear() {
        state.withLock { state in
            state.promises.removeAll()
            state.perPeerCount.removeAll()
            state.total = 0
        }
    }

    /// Decrements the bookkeeping counters for a peer by one promise.
    private func decrementPeer(_ peer: PeerID, in state: inout State) {
        guard state.total > 0 else { return }
        state.total -= 1
        if let c = state.perPeerCount[peer] {
            if c <= 1 {
                state.perPeerCount.removeValue(forKey: peer)
            } else {
                state.perPeerCount[peer] = c - 1
            }
        }
    }
}
