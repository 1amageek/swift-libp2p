/// RecordStorage - Protocol for Kademlia DHT record storage backends.

import Foundation

/// Storage backend for Kademlia DHT records.
///
/// Implementations must be thread-safe (`Sendable`).
/// The default in-memory implementation is `InMemoryRecordStorage`.
/// For persistent storage, use `FileRecordStorage`.
public protocol RecordStorage: Sendable {
    /// Stores a record with the given TTL.
    ///
    /// If a record with the same key already exists, it is replaced.
    ///
    /// - Parameters:
    ///   - record: The record to store.
    ///   - ttl: Time-to-live for the record.
    /// - Throws: If the storage operation fails.
    func put(_ record: KademliaRecord, ttl: Duration) throws

    /// Retrieves a record by key.
    ///
    /// Returns `nil` if the record does not exist or has expired.
    ///
    /// - Parameter key: The record key.
    /// - Returns: The record if found and not expired, or `nil`.
    /// - Throws: If the storage operation fails.
    func get(_ key: Data) throws -> KademliaRecord?

    /// Removes a record by key.
    ///
    /// - Parameter key: The record key.
    /// - Throws: If the storage operation fails.
    func remove(_ key: Data) throws

    /// Returns all non-expired records.
    ///
    /// - Returns: An array of all valid records.
    /// - Throws: If the storage operation fails.
    func allRecords() throws -> [KademliaRecord]

    /// Returns records that need to be republished.
    ///
    /// A record needs republishing if it was stored longer ago than `threshold`.
    ///
    /// - Parameter threshold: The republish interval threshold.
    /// - Returns: Records older than the threshold that have not expired.
    /// - Throws: If the storage operation fails.
    func recordsNeedingRepublish(threshold: Duration) throws -> [KademliaRecord]

    /// Removes all expired records.
    ///
    /// - Returns: The number of records removed.
    /// - Throws: If the storage operation fails.
    @discardableResult
    func cleanup() throws -> Int

    /// The number of non-expired records currently stored.
    var count: Int { get }
}
