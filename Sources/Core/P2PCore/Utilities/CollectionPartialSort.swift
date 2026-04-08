/// Collection extension for efficient partial sorting.
///
/// Provides methods to retrieve k smallest/largest elements without sorting
/// the entire collection (O(n log k) instead of O(n log n)).

extension Collection {
    @usableFromInline
    internal static var insertionOptimizedThreshold: Int { 32 }

    /// Returns the k smallest elements according to the given predicate.
    ///
    /// This is more efficient than `sorted(by:).prefix(k)` when k << count,
    /// using O(n log k) time and O(k) space instead of O(n log n) time.
    ///
    /// - Parameters:
    ///   - k: Maximum number of elements to return
    ///   - areInIncreasingOrder: Comparison predicate (same as `sorted(by:)`)
    /// - Returns: Array of up to k smallest elements, sorted
    ///
    /// Uses an adaptive strategy:
    /// - `k == 1` uses a single linear pass.
    /// - Small `k` uses an insertion-optimized top-k buffer.
    /// - Larger `k` falls back to a max-heap.
    ///
    /// Example:
    /// ```swift
    /// let numbers = [5, 2, 8, 1, 9, 3, 7]
    /// let smallest3 = numbers.smallest(3, by: <)  // [1, 2, 3]
    /// ```
    @inlinable
    public func smallest(
        _ k: Int,
        by areInIncreasingOrder: (Element, Element) throws -> Bool
    ) rethrows -> [Element] {
        guard k > 0 else { return [] }
        guard !isEmpty else { return [] }

        if k >= count {
            return try sorted(by: areInIncreasingOrder)
        }
        if k == 1 {
            var iterator = makeIterator()
            guard var minimum = iterator.next() else { return [] }
            while let element = iterator.next() {
                if try areInIncreasingOrder(element, minimum) {
                    minimum = element
                }
            }
            return [minimum]
        }
        if k <= Self.insertionOptimizedThreshold {
            return try insertionOptimizedSmallest(k, by: areInIncreasingOrder)
        }

        // Build a max-heap of size k (stores k smallest elements)
        // Heap invariant: heap[0] is the largest among the k smallest
        var heap: [Element] = []
        heap.reserveCapacity(k)

        for element in self {
            if heap.count < k {
                // Heap not full yet - insert and maintain heap property
                heap.append(element)
                if heap.count == k {
                    // Build max-heap (largest at index 0)
                    try heapify(&heap, by: areInIncreasingOrder)
                }
            } else {
                // Heap full - replace root if new element is smaller
                if try areInIncreasingOrder(element, heap[0]) {
                    heap[0] = element
                    try siftDown(&heap, startIndex: 0, by: areInIncreasingOrder)
                }
            }
        }

        // For the small fixed-size heaps used here, in-place heap sort avoids
        // the extra comparator overhead that `Array.sort` tends to add.
        var result = heap
        try heapSort(&result, by: areInIncreasingOrder)
        return result
    }

    @usableFromInline
    internal func insertionOptimizedSmallest(
        _ k: Int,
        by areInIncreasingOrder: (Element, Element) throws -> Bool
    ) rethrows -> [Element] {
        var result: [Element] = []
        result.reserveCapacity(k)

        for element in self {
            if result.count < k {
                let insertionIndex = try binarySearchInsertionIndex(
                    of: element,
                    in: result,
                    by: areInIncreasingOrder
                )
                result.insert(element, at: insertionIndex)
                continue
            }

            guard let currentLargest = result.last,
                  try areInIncreasingOrder(element, currentLargest) else {
                continue
            }

            let insertionIndex = try binarySearchInsertionIndex(
                of: element,
                in: result,
                by: areInIncreasingOrder
            )
            result.insert(element, at: insertionIndex)
            result.removeLast()
        }

        return result
    }
}

extension Array {
    @usableFromInline
    internal static var fullSortPreferredCountThreshold: Int { 2_048 }

    /// Returns the k smallest elements according to the given predicate.
    ///
    /// Arrays get an additional fast path that uses `Array.sorted(by:)` for
    /// small and medium inputs, which the optimizer handles much better than
    /// the generic `Collection.sorted(by:)` path.
    @inlinable
    public func smallest(
        _ k: Int,
        by areInIncreasingOrder: (Element, Element) throws -> Bool
    ) rethrows -> [Element] {
        guard k > 0 else { return [] }
        guard !isEmpty else { return [] }

        if k >= count {
            return try sorted(by: areInIncreasingOrder)
        }
        if k == 1 {
            var minimum = self[0]
            for element in dropFirst() {
                if try areInIncreasingOrder(element, minimum) {
                    minimum = element
                }
            }
            return [minimum]
        }
        if count <= Self.fullSortPreferredCountThreshold {
            return try Array(sorted(by: areInIncreasingOrder).prefix(k))
        }

        return try ArraySlice(self).smallest(k, by: areInIncreasingOrder)
    }
}

extension Array where Element: Comparable {
    /// Returns the k smallest elements using the element's natural order.
    @inlinable
    public func smallest(_ k: Int) -> [Element] {
        guard k > 0 else { return [] }
        guard !isEmpty else { return [] }

        if k >= count {
            return sorted()
        }
        if k == 1 {
            var minimum = self[0]
            for element in dropFirst() {
                if element < minimum {
                    minimum = element
                }
            }
            return [minimum]
        }
        if count <= Self.fullSortPreferredCountThreshold {
            return Array(sorted().prefix(k))
        }

        return ArraySlice(self).smallest(k, by: <)
    }
}

@usableFromInline
internal func binarySearchInsertionIndex<T>(
    of value: T,
    in sortedValues: [T],
    by areInIncreasingOrder: (T, T) throws -> Bool
) rethrows -> Int {
    var low = 0
    var high = sortedValues.count

    while low < high {
        let mid = (low + high) / 2
        if try areInIncreasingOrder(sortedValues[mid], value) {
            low = mid + 1
        } else {
            high = mid
        }
    }

    return low
}

// MARK: - Max-Heap Utilities

/// Builds a max-heap from an array in-place.
///
/// After this operation, `array[0]` is the maximum element.
/// - Complexity: O(n)
@usableFromInline
internal func heapify<T>(
    _ array: inout [T],
    by areInIncreasingOrder: (T, T) throws -> Bool
) rethrows {
    guard array.count > 1 else { return }

    // Start from last non-leaf node and sift down
    for i in stride(from: array.count / 2 - 1, through: 0, by: -1) {
        try siftDown(&array, startIndex: i, by: areInIncreasingOrder)
    }
}

/// Restores max-heap property by moving element at `startIndex` downward.
///
/// Assumes subtrees are already valid max-heaps.
/// - Complexity: O(log n)
@usableFromInline
internal func siftDown<T>(
    _ array: inout [T],
    startIndex: Int,
    by areInIncreasingOrder: (T, T) throws -> Bool
) rethrows {
    var index = startIndex
    let count = array.count

    while true {
        let leftChild = 2 * index + 1
        let rightChild = 2 * index + 2
        var largest = index

        // Find largest among node and its children
        if leftChild < count {
            if try areInIncreasingOrder(array[largest], array[leftChild]) {
                largest = leftChild
            }
        }
        if rightChild < count {
            if try areInIncreasingOrder(array[largest], array[rightChild]) {
                largest = rightChild
            }
        }

        if largest == index {
            break  // Heap property satisfied
        }

        array.swapAt(index, largest)
        index = largest
    }
}

/// Sorts a max-heap in-place in ascending order.
///
/// - Complexity: O(n log n)
@usableFromInline
internal func heapSort<T>(
    _ array: inout [T],
    by areInIncreasingOrder: (T, T) throws -> Bool
) rethrows {
    guard array.count > 1 else { return }

    // Build max-heap first
    try heapify(&array, by: areInIncreasingOrder)

    // Repeatedly extract max and rebuild heap
    for i in stride(from: array.count - 1, through: 1, by: -1) {
        array.swapAt(0, i)
        try siftDownWithLimit(&array, startIndex: 0, limit: i, by: areInIncreasingOrder)
    }
}

/// Restores heap order within a truncated prefix, used during heap sort.
@usableFromInline
internal func siftDownWithLimit<T>(
    _ array: inout [T],
    startIndex: Int,
    limit: Int,
    by areInIncreasingOrder: (T, T) throws -> Bool
) rethrows {
    var index = startIndex

    while true {
        let leftChild = 2 * index + 1
        let rightChild = 2 * index + 2
        var largest = index

        if leftChild < limit, try areInIncreasingOrder(array[largest], array[leftChild]) {
            largest = leftChild
        }
        if rightChild < limit, try areInIncreasingOrder(array[largest], array[rightChild]) {
            largest = rightChild
        }

        if largest == index {
            break
        }

        array.swapAt(index, largest)
        index = largest
    }
}
