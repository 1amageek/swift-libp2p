/// RecordStore - Storage for DHT records with pluggable backends.

import Foundation
import Synchronization
import P2PCore

private let recordStoreLogger = Logger(label: "p2p.kademlia.recordstore")

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

    /// Stores a record, propagating any backend failure.
    ///
    /// - Parameters:
    ///   - record: The record to store.
    ///   - ttl: Time-to-live (uses default if nil).
    /// - Throws: A backend error (e.g. `KademliaError.storeFull`) if the record
    ///   could not be stored. The caller MUST decide how to handle failure
    ///   rather than treating a failed store as success.
    public func putThrowing(_ record: KademliaRecord, ttl: Duration? = nil) throws {
        let effectiveTTL = ttl ?? defaultTTL
        try backend.put(record, ttl: effectiveTTL)
    }

    /// Stores a record (non-throwing convenience).
    ///
    /// - Parameters:
    ///   - record: The record to store.
    ///   - ttl: Time-to-live (uses default if nil).
    /// - Returns: True if stored, false if the backend rejected it (e.g. full).
    ///   The error is logged (not silently swallowed). Prefer `putThrowing`
    ///   on paths where the result matters.
    @discardableResult
    public func put(_ record: KademliaRecord, ttl: Duration? = nil) -> Bool {
        do {
            try putThrowing(record, ttl: ttl)
            return true
        } catch {
            recordStoreLogger.warning("RecordStore.put failed: \(error)")
            return false
        }
    }

    /// Retrieves a record by key, propagating any backend failure.
    ///
    /// - Parameter key: The record key.
    /// - Returns: The record if found and not expired (nil if absent).
    /// - Throws: A backend error if the lookup failed.
    public func getThrowing(_ key: Data) throws -> KademliaRecord? {
        try backend.get(key)
    }

    /// Retrieves a record by key (non-throwing convenience).
    ///
    /// - Parameter key: The record key.
    /// - Returns: The record if found and not expired. Backend errors are
    ///   logged and surface as `nil`.
    public func get(_ key: Data) -> KademliaRecord? {
        do {
            return try getThrowing(key)
        } catch {
            recordStoreLogger.warning("RecordStore.get failed: \(error)")
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
            recordStoreLogger.warning("RecordStore.remove failed: \(error)")
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
            recordStoreLogger.warning("RecordStore.allRecords failed: \(error)")
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
            recordStoreLogger.warning("RecordStore.cleanup failed: \(error)")
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
            recordStoreLogger.warning("RecordStore.clear failed: \(error)")
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
            recordStoreLogger.warning("RecordStore.recordsNeedingRepublish failed: \(error)")
            return []
        }
    }
}
