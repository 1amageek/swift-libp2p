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
    }

    private let state: Mutex<State>

    init() {
        self.state = Mutex(State())
    }

    /// Records that peer promised to deliver these messages.
    func addPromise(
        peer: PeerID,
        messageIDs: [MessageID],
        expires: ContinuousClock.Instant
    ) {
        state.withLock { state in
            for msgID in messageIDs {
                state.promises[msgID, default: [:]][peer] = expires
            }
        }
    }

    /// Called when a message is delivered (from any peer).
    /// Removes all promises for this message.
    func messageDelivered(_ messageID: MessageID) {
        state.withLock { state in
            state.promises.removeValue(forKey: messageID)
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
                var allExpired = true
                for (peer, expiry) in peerMap {
                    if now >= expiry {
                        brokenCounts[peer, default: 0] += 1
                    } else {
                        allExpired = false
                    }
                }
                if allExpired {
                    toRemove.append(msgID)
                }
            }

            for msgID in toRemove {
                state.promises.removeValue(forKey: msgID)
            }
        }

        return brokenCounts
    }

    func clear() {
        state.withLock { $0.promises.removeAll() }
    }
}
