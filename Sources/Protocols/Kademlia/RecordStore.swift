/// RecordStore - Storage for DHT records.

import Foundation
import Synchronization

/// Storage for DHT records with TTL support.
public final class RecordStore: Sendable {
    /// Internal record with metadata.
    private struct StoredRecord: Sendable {
        let record: KademliaRecord
        let expiresAt: ContinuousClock.Instant
    }

    /// The stored records.
    private let records: Mutex<[Data: StoredRecord]>

    /// Maximum number of records to store.
    public let maxRecords: Int

    /// Default TTL for records.
    public let defaultTTL: Duration

    /// Creates a new record store.
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
        self.records = Mutex([:])
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
        let expiresAt = ContinuousClock.now.advanced(by: effectiveTTL)

        return records.withLock { records in
            // If already exists, update it
            if records[record.key] != nil {
                records[record.key] = StoredRecord(record: record, expiresAt: expiresAt)
                return true
            }

            // Check capacity
            if records.count >= maxRecords {
                // Try to evict expired records first
                let now = ContinuousClock.now
                records = records.filter { $0.value.expiresAt > now }

                // If still full, reject
                if records.count >= maxRecords {
                    return false
                }
            }

            records[record.key] = StoredRecord(record: record, expiresAt: expiresAt)
            return true
        }
    }

    /// Retrieves a record by key.
    ///
    /// - Parameter key: The record key.
    /// - Returns: The record if found and not expired.
    public func get(_ key: Data) -> KademliaRecord? {
        records.withLock { records in
            guard let stored = records[key] else { return nil }

            // Check expiration
            if stored.expiresAt <= ContinuousClock.now {
                records.removeValue(forKey: key)
                return nil
            }

            return stored.record
        }
    }

    /// Removes a record.
    ///
    /// - Parameter key: The record key.
    /// - Returns: The removed record, if found.
    @discardableResult
    public func remove(_ key: Data) -> KademliaRecord? {
        records.withLock { records in
            records.removeValue(forKey: key)?.record
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
        let now = ContinuousClock.now
        return records.withLock { records in
            records.values
                .filter { $0.expiresAt > now }
                .map { $0.record }
        }
    }

    /// Returns the number of non-expired records.
    public var count: Int {
        let now = ContinuousClock.now
        return records.withLock { records in
            records.values.filter { $0.expiresAt > now }.count
        }
    }

    /// Removes all expired records.
    ///
    /// - Returns: Number of records removed.
    @discardableResult
    public func cleanup() -> Int {
        let now = ContinuousClock.now
        return records.withLock { records in
            let before = records.count
            records = records.filter { $0.value.expiresAt > now }
            return before - records.count
        }
    }

    /// Removes all records.
    public func clear() {
        records.withLock { records in
            records.removeAll()
        }
    }

    /// Returns records that need to be republished.
    ///
    /// - Parameter threshold: Republish records older than this (default: 1 hour).
    /// - Returns: Records that should be republished.
    public func recordsNeedingRepublish(
        threshold: Duration = KademliaProtocol.recordRepublishInterval
    ) -> [KademliaRecord] {
        let cutoff = ContinuousClock.now - threshold
        let now = ContinuousClock.now
        let ttl = self.defaultTTL

        return records.withLock { records in
            records.values
                .filter { stored in
                    // Not expired and needs republish
                    stored.expiresAt > now &&
                    (stored.expiresAt - ttl) < cutoff
                }
                .map { $0.record }
        }
    }
}
