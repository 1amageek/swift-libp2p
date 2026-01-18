/// ConnectionID - Unique identifier for a connection
///
/// Each connection is assigned a unique ID when created.

import Foundation
import Synchronization

/// A unique identifier for a connection.
///
/// ConnectionIDs are generated sequentially and are unique within a process.
/// They are used to track and manage individual connections in the pool.
public struct ConnectionID: Sendable, Hashable {

    /// The underlying identifier value.
    private let value: UInt64

    /// Global counter for generating unique IDs.
    private static let counter = Mutex<UInt64>(0)

    /// Creates a new unique ConnectionID.
    public init() {
        self.value = Self.counter.withLock { count in
            count += 1
            return count
        }
    }

    /// Creates a ConnectionID with a specific value.
    ///
    /// This initializer is intended for testing and serialization.
    /// For normal use, prefer the parameterless initializer.
    ///
    /// - Parameter value: The specific ID value
    internal init(value: UInt64) {
        self.value = value
    }
}

// MARK: - CustomStringConvertible

extension ConnectionID: CustomStringConvertible {
    public var description: String {
        "conn-\(value)"
    }
}

// MARK: - CustomDebugStringConvertible

extension ConnectionID: CustomDebugStringConvertible {
    public var debugDescription: String {
        "ConnectionID(\(value))"
    }
}
