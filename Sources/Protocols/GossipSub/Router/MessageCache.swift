/// MessageCache - Message caching for GossipSub IHAVE/IWANT
import Foundation
import Synchronization

/// A time-based cache for GossipSub messages.
///
/// Messages are stored in "windows" based on heartbeat intervals.
/// This enables efficient IHAVE gossip and IWANT responses.
final class MessageCache: Sendable {

    // MARK: - Types

    /// A cached message entry.
    struct CachedMessage: Sendable {
        let message: GossipSubMessage
        let receivedAt: ContinuousClock.Instant
    }

    /// Internal state.
    private struct State: Sendable {
        /// Message windows (index 0 is most recent).
        var windows: [[MessageID]]

        /// All cached messages by ID.
        var messages: [MessageID: CachedMessage]

        init(windowCount: Int) {
            self.windows = Array(repeating: [], count: windowCount)
            self.messages = [:]
        }
    }

    // MARK: - Properties

    /// Number of windows to keep (mcache_len).
    private let windowCount: Int

    /// Number of windows to include in gossip (mcache_gossip).
    private let gossipWindowCount: Int

    /// Internal state protected by mutex.
    private let state: Mutex<State>

    // MARK: - Initialization

    /// Creates a new message cache.
    ///
    /// - Parameters:
    ///   - windowCount: Total number of windows to keep
    ///   - gossipWindowCount: Number of windows to include in gossip
    init(windowCount: Int = 5, gossipWindowCount: Int = 3) {
        self.windowCount = windowCount
        self.gossipWindowCount = min(gossipWindowCount, windowCount)
        self.state = Mutex(State(windowCount: windowCount))
    }

    // MARK: - Public API

    /// Adds a message to the cache.
    ///
    /// - Parameter message: The message to cache
    func put(_ message: GossipSubMessage) {
        state.withLock { state in
            let id = message.id

            // Don't add duplicates
            guard state.messages[id] == nil else { return }

            // Add to current window (index 0)
            state.windows[0].append(id)

            // Store message
            state.messages[id] = CachedMessage(
                message: message,
                receivedAt: .now
            )
        }
    }

    /// Gets a message by ID.
    ///
    /// - Parameter id: The message ID
    /// - Returns: The message if found
    func get(_ id: MessageID) -> GossipSubMessage? {
        state.withLock { $0.messages[id]?.message }
    }

    /// Gets multiple messages by ID.
    ///
    /// - Parameter ids: The message IDs
    /// - Returns: Dictionary of found messages
    func getMultiple(_ ids: [MessageID]) -> [MessageID: GossipSubMessage] {
        state.withLock { state in
            var result: [MessageID: GossipSubMessage] = [:]
            for id in ids {
                if let cached = state.messages[id] {
                    result[id] = cached.message
                }
            }
            return result
        }
    }

    /// Returns message IDs for gossip (from recent windows).
    ///
    /// - Parameter topic: The topic to get IDs for
    /// - Returns: Array of message IDs
    func getGossipIDs(for topic: Topic) -> [MessageID] {
        state.withLock { state in
            var ids: [MessageID] = []

            // Collect IDs from gossip windows
            for i in 0..<gossipWindowCount where i < state.windows.count {
                for id in state.windows[i] {
                    // Check if message belongs to topic
                    if let cached = state.messages[id], cached.message.topic == topic {
                        ids.append(id)
                    }
                }
            }

            return ids
        }
    }

    /// Checks if a message is in the cache.
    ///
    /// - Parameter id: The message ID
    /// - Returns: True if the message is cached
    func contains(_ id: MessageID) -> Bool {
        state.withLock { $0.messages[id] != nil }
    }

    /// Shifts the cache windows (called on heartbeat).
    ///
    /// This moves all windows one position and drops the oldest.
    func shift() {
        state.withLock { state in
            // Get IDs from oldest window to remove
            if state.windows.count > 0 {
                let oldestWindow = state.windows.removeLast()

                // Remove messages from oldest window
                for id in oldestWindow {
                    state.messages.removeValue(forKey: id)
                }

                // Add new empty window at front
                state.windows.insert([], at: 0)
            }
        }
    }

    /// Returns the number of cached messages.
    var count: Int {
        state.withLock { $0.messages.count }
    }

    /// Returns all message IDs in the cache.
    var allMessageIDs: [MessageID] {
        state.withLock { Array($0.messages.keys) }
    }

    /// Clears all cached messages.
    func clear() {
        state.withLock { state in
            state.windows = Array(repeating: [], count: windowCount)
            state.messages.removeAll()
        }
    }
}

// MARK: - SeenCache

/// A cache for tracking seen message IDs.
///
/// Used for deduplication to avoid processing the same message twice.
final class SeenCache: Sendable {

    /// An entry in the seen cache.
    private struct Entry: Sendable {
        let seenAt: ContinuousClock.Instant
    }

    /// Internal state.
    private struct State: Sendable {
        var entries: [MessageID: Entry]
        var order: [MessageID]  // For LRU eviction
    }

    /// Maximum number of entries.
    private let maxSize: Int

    /// Time to live for entries.
    private let ttl: Duration

    /// Internal state.
    private let state: Mutex<State>

    /// Creates a new seen cache.
    ///
    /// - Parameters:
    ///   - maxSize: Maximum number of entries
    ///   - ttl: Time to live for entries
    init(maxSize: Int = 10000, ttl: Duration = .seconds(120)) {
        self.maxSize = maxSize
        self.ttl = ttl
        self.state = Mutex(State(entries: [:], order: []))
    }

    /// Marks a message as seen.
    ///
    /// - Parameter id: The message ID
    /// - Returns: True if the message was not previously seen
    @discardableResult
    func add(_ id: MessageID) -> Bool {
        state.withLock { state in
            let now = ContinuousClock.now

            // Check if already seen
            if let existing = state.entries[id] {
                // Check if expired
                if now - existing.seenAt > ttl {
                    state.entries[id] = Entry(seenAt: now)
                    // Move to end of order
                    if let index = state.order.firstIndex(of: id) {
                        state.order.remove(at: index)
                        state.order.append(id)
                    }
                    return true  // Treated as new (expired)
                }
                return false  // Already seen
            }

            // New entry
            state.entries[id] = Entry(seenAt: now)
            state.order.append(id)

            // Evict if over capacity
            while state.entries.count > maxSize, !state.order.isEmpty {
                let oldestID = state.order.removeFirst()
                state.entries.removeValue(forKey: oldestID)
            }

            return true
        }
    }

    /// Checks if a message has been seen.
    ///
    /// - Parameter id: The message ID
    /// - Returns: True if seen and not expired
    func contains(_ id: MessageID) -> Bool {
        state.withLock { state in
            guard let entry = state.entries[id] else {
                return false
            }
            // Check expiration
            return ContinuousClock.now - entry.seenAt <= ttl
        }
    }

    /// Removes expired entries.
    func cleanup() {
        state.withLock { state in
            let now = ContinuousClock.now
            var newOrder: [MessageID] = []

            for id in state.order {
                if let entry = state.entries[id] {
                    if now - entry.seenAt <= ttl {
                        newOrder.append(id)
                    } else {
                        state.entries.removeValue(forKey: id)
                    }
                }
            }

            state.order = newOrder
        }
    }

    /// Returns the number of entries.
    var count: Int {
        state.withLock { $0.entries.count }
    }

    /// Clears all entries.
    func clear() {
        state.withLock { state in
            state.entries.removeAll()
            state.order.removeAll()
        }
    }
}
