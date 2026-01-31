/// RecordStore - Storage for DHT records with pluggable backends.

import Foundation
import Synchronization

/// Storage for DHT records with TTL support.
///
/// Delegates all storage operations to a `RecordStorage` backend.
/// By default uses `InMemoryRecordStorage`. Pass a custom backend
/// (e.g., `FileRecordStorage`) for persistent storage.
public final class RecordStore: Sendable {

    /// The storage backend.
    private let backend: any RecordStorage

    /// Maximum number of records to store.
    public let maxRecords: Int

    /// Default TTL for records.
    public let defaultTTL: Duration

    /// Creates a new record store with the default in-memory backend.
    ///
    /// - Parameters:
    ///   - maxRecords: Maximum number of records (default: 1024).
    ///   - defaultTTL: Default TTL for records (default: 36 hours).
    public init(
        maxRecords: Int = 1024,
        defaultTTL: Duration = KademliaProtocol.recordTTL
    ) {
        self.maxRecords = maxRecords
        self.defaultTTL = defaultTTL
        self.backend = InMemoryRecordStorage(maxRecords: maxRecords)
    }

    /// Creates a new record store with a custom storage backend.
    ///
    /// - Parameters:
    ///   - backend: The storage backend to use.
    ///   - defaultTTL: Default TTL for records (default: 36 hours).
    public init(
        backend: any RecordStorage,
        defaultTTL: Duration = KademliaProtocol.recordTTL
    ) {
        self.backend = backend
        self.maxRecords = 0  // Managed by backend
        self.defaultTTL = defaultTTL
    }

    /// Stores a record.
    ///
    /// - Parameters:
    ///   - record: The record to store.
    ///   - ttl: Time-to-live (uses default if nil).
    /// - Returns: True if stored, false if rejected (e.g., store full).
    @discardableResult
    public func put(_ record: KademliaRecord, ttl: Duration? = nil) -> Bool {
        let effectiveTTL = ttl ?? defaultTTL
        do {
            try backend.put(record, ttl: effectiveTTL)
            return true
        } catch {
            return false
        }
    }

    /// Retrieves a record by key.
    ///
    /// - Parameter key: The record key.
    /// - Returns: The record if found and not expired.
    public func get(_ key: Data) -> KademliaRecord? {
        do {
            return try backend.get(key)
        } catch {
            return nil
        }
    }

    /// Removes a record.
    ///
    /// - Parameter key: The record key.
    /// - Returns: The removed record, if found.
    @discardableResult
    public func remove(_ key: Data) -> KademliaRecord? {
        do {
            let existing = try backend.get(key)
            try backend.remove(key)
            return existing
        } catch {
            return nil
        }
    }

    /// Checks if a record exists and is not expired.
    ///
    /// - Parameter key: The record key.
    /// - Returns: True if the record exists.
    public func contains(_ key: Data) -> Bool {
        get(key) != nil
    }

    /// Returns all non-expired records.
    public var allRecords: [KademliaRecord] {
        do {
            return try backend.allRecords()
        } catch {
            return []
        }
    }

    /// Returns the number of non-expired records.
    public var count: Int {
        backend.count
    }

    /// Removes all expired records.
    ///
    /// - Returns: Number of records removed.
    @discardableResult
    public func cleanup() -> Int {
        do {
            return try backend.cleanup()
        } catch {
            return 0
        }
    }

    /// Removes all records.
    public func clear() {
        do {
            let records = try backend.allRecords()
            for record in records {
                try backend.remove(record.key)
            }
        } catch {
            // Best effort
        }
    }

    /// Returns records that need to be republished.
    ///
    /// - Parameter threshold: Republish records older than this (default: 1 hour).
    /// - Returns: Records that should be republished.
    public func recordsNeedingRepublish(
        threshold: Duration = KademliaProtocol.recordRepublishInterval
    ) -> [KademliaRecord] {
        do {
            return try backend.recordsNeedingRepublish(threshold: threshold)
        } catch {
            return []
        }
    }
}
