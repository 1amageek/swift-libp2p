/// Collection extension for efficient partial sorting.
///
/// Provides methods to retrieve k smallest/largest elements without sorting
/// the entire collection (O(n log k) instead of O(n log n)).

extension Collection {
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
    /// - Complexity: O(n log k) where n is the collection count
    ///
    /// Example:
    /// ```swift
    /// let numbers = [5, 2, 8, 1, 9, 3, 7]
    /// let smallest3 = numbers.smallest(3, by: <)  // [1, 2, 3]
    /// ```
    public func smallest(
        _ k: Int,
        by areInIncreasingOrder: (Element, Element) throws -> Bool
    ) rethrows -> [Element] {
        guard k > 0 else { return [] }
        guard !isEmpty else { return [] }

        // For small k, use min-heap approach: O(n log k)
        // For large k (k > count/2), fall back to full sort
        if k >= count {
            return try sorted(by: areInIncreasingOrder)
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

        // Extract elements from heap in sorted order
        var result = heap
        try heapSort(&result, by: areInIncreasingOrder)
        return result
    }
}

// MARK: - Max-Heap Utilities

/// Builds a max-heap from an array in-place.
///
/// After this operation, `array[0]` is the maximum element.
/// - Complexity: O(n)
private func heapify<T>(
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
private func siftDown<T>(
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
private func heapSort<T>(
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

/// Sift down with a size limit (for heap sort).
private func siftDownWithLimit<T>(
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

        if leftChild < limit {
            if try areInIncreasingOrder(array[largest], array[leftChild]) {
                largest = leftChild
            }
        }
        if rightChild < limit {
            if try areInIncreasingOrder(array[largest], array[rightChild]) {
                largest = rightChild
            }
        }

        if largest == index {
            break
        }

        array.swapAt(index, largest)
        index = largest
    }
}
