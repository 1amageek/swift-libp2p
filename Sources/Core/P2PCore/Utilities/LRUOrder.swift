/// LRU (Least Recently Used) order tracking with O(1) amortized operations.
///
/// Tracks access order for a set of keys using a doubly-linked list backed by
/// a dictionary for O(1) lookups. Used by PeerStore and SeenCache for efficient
/// LRU eviction.
///
/// This is not a full cache - it only tracks ordering. The actual data storage
/// is managed externally.
public struct LRUOrder<Key: Hashable & Sendable>: Sendable {

    /// Linked list node stored in the array.
    private struct Node: Sendable {
        var key: Key
        var prev: Int  // -1 = none
        var next: Int  // -1 = none
    }

    /// Dense node storage.
    private var nodes: [Node] = []

    /// Maps key to index in `nodes`.
    private var indexMap: [Key: Int] = [:]

    /// Free list of recycled node indices.
    private var freeIndices: [Int] = []

    /// Head of the list (oldest / least recently used). -1 = empty.
    private var head: Int = -1

    /// Tail of the list (newest / most recently used). -1 = empty.
    private var tail: Int = -1

    /// Creates an empty LRU order tracker.
    public init() {}

    /// The number of tracked keys.
    public var count: Int {
        indexMap.count
    }

    /// Whether the tracker is empty.
    public var isEmpty: Bool {
        indexMap.isEmpty
    }

    /// The oldest (least recently used) key, or nil if empty.
    public var oldest: Key? {
        guard head >= 0 else { return nil }
        return nodes[head].key
    }

    /// Inserts a key as the most recently used.
    ///
    /// If the key already exists, it is moved to the most recent position.
    /// - Complexity: O(1) amortized
    public mutating func insert(_ key: Key) {
        if let existingIndex = indexMap[key] {
            moveToTail(existingIndex)
            return
        }

        let newIndex: Int
        if let recycled = freeIndices.popLast() {
            nodes[recycled] = Node(key: key, prev: tail, next: -1)
            newIndex = recycled
        } else {
            newIndex = nodes.count
            nodes.append(Node(key: key, prev: tail, next: -1))
        }

        if tail >= 0 {
            nodes[tail].next = newIndex
        } else {
            head = newIndex
        }
        tail = newIndex
        indexMap[key] = newIndex
    }

    /// Touches a key, moving it to the most recently used position.
    ///
    /// Does nothing if the key is not tracked.
    /// - Complexity: O(1)
    public mutating func touch(_ key: Key) {
        guard let index = indexMap[key] else { return }
        moveToTail(index)
    }

    /// Removes a specific key.
    ///
    /// - Returns: True if the key was found and removed.
    /// - Complexity: O(1)
    @discardableResult
    public mutating func remove(_ key: Key) -> Bool {
        guard let index = indexMap.removeValue(forKey: key) else {
            return false
        }
        unlink(index)
        freeIndices.append(index)
        return true
    }

    /// Removes and returns the oldest (least recently used) key.
    ///
    /// - Returns: The oldest key, or nil if empty.
    /// - Complexity: O(1)
    @discardableResult
    public mutating func removeOldest() -> Key? {
        guard head >= 0 else { return nil }
        let key = nodes[head].key
        let oldHead = head
        indexMap.removeValue(forKey: key)
        unlink(oldHead)
        freeIndices.append(oldHead)
        return key
    }

    /// Checks if a key is tracked.
    /// - Complexity: O(1)
    public func contains(_ key: Key) -> Bool {
        indexMap[key] != nil
    }

    /// Removes all tracked keys.
    public mutating func removeAll() {
        nodes.removeAll()
        indexMap.removeAll()
        freeIndices.removeAll()
        head = -1
        tail = -1
    }

    // MARK: - Private

    /// Unlinks a node from the doubly-linked list.
    private mutating func unlink(_ index: Int) {
        let node = nodes[index]
        let prev = node.prev
        let next = node.next

        if prev >= 0 {
            nodes[prev].next = next
        } else {
            head = next
        }

        if next >= 0 {
            nodes[next].prev = prev
        } else {
            tail = prev
        }
    }

    /// Moves a node to the tail (most recently used) position.
    private mutating func moveToTail(_ index: Int) {
        guard index != tail else { return }

        // Unlink from current position
        unlink(index)

        // Append to tail
        nodes[index].prev = tail
        nodes[index].next = -1

        if tail >= 0 {
            nodes[tail].next = index
        } else {
            head = index
        }
        tail = index
    }
}
