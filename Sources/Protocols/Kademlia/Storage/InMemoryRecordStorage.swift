/// InMemoryRecordStorage - In-memory implementation of RecordStorage.

import Foundation
import Synchronization

/// In-memory storage backend for Kademlia DHT records.
///
/// Stores records in a dictionary with TTL-based expiration.
/// All operations are thread-safe via `Mutex`.
public final class InMemoryRecordStorage: RecordStorage, Sendable {

    /// Internal record with expiration metadata.
    private struct StoredRecord: Sendable {
        let record: KademliaRecord
        let storedAt: ContinuousClock.Instant
        let expiresAt: ContinuousClock.Instant
    }

    private struct State: Sendable {
        var records: [Data: StoredRecord] = [:]
    }

    private let state: Mutex<State>

    /// Maximum number of records to store.
    public let maxRecords: Int

    /// Creates a new in-memory record storage.
    ///
    /// - Parameter maxRecords: Maximum number of records (default: 1024).
    public init(maxRecords: Int = 1024) {
        self.maxRecords = maxRecords
        self.state = Mutex(State())
    }

    public func put(_ record: KademliaRecord, ttl: Duration) throws {
        let now = ContinuousClock.now
        let expiresAt = now.advanced(by: ttl)
        let stored = StoredRecord(record: record, storedAt: now, expiresAt: expiresAt)

        state.withLock { s in
            // If already exists, update it
            if s.records[record.key] != nil {
                s.records[record.key] = stored
                return
            }

            // Check capacity
            if s.records.count >= maxRecords {
                // Try to evict expired records first
                s.records = s.records.filter { $0.value.expiresAt > now }

                // If still full, do not store
                if s.records.count >= maxRecords {
                    return
                }
            }

            s.records[record.key] = stored
        }
    }

    public func get(_ key: Data) throws -> KademliaRecord? {
        state.withLock { s in
            guard let stored = s.records[key] else { return nil }

            if stored.expiresAt <= ContinuousClock.now {
                s.records.removeValue(forKey: key)
                return nil
            }

            return stored.record
        }
    }

    public func remove(_ key: Data) throws {
        state.withLock { s in
            _ = s.records.removeValue(forKey: key)
        }
    }

    public func allRecords() throws -> [KademliaRecord] {
        let now = ContinuousClock.now
        return state.withLock { s in
            s.records.values
                .filter { $0.expiresAt > now }
                .map { $0.record }
        }
    }

    public func recordsNeedingRepublish(threshold: Duration) throws -> [KademliaRecord] {
        let now = ContinuousClock.now
        let cutoff = now - threshold
        return state.withLock { s in
            s.records.values
                .filter { stored in
                    stored.expiresAt > now && stored.storedAt < cutoff
                }
                .map { $0.record }
        }
    }

    @discardableResult
    public func cleanup() throws -> Int {
        let now = ContinuousClock.now
        return state.withLock { s in
            let before = s.records.count
            s.records = s.records.filter { $0.value.expiresAt > now }
            return before - s.records.count
        }
    }

    public var count: Int {
        let now = ContinuousClock.now
        return state.withLock { s in
            s.records.values.filter { $0.expiresAt > now }.count
        }
    }
}
