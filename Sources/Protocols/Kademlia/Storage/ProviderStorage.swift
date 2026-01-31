/// ProviderStorage - Protocol for Kademlia content provider storage backends.

import Foundation
import P2PCore

/// Storage backend for content provider records.
///
/// Implementations must be thread-safe (`Sendable`).
/// The default in-memory implementation is `InMemoryProviderStorage`.
/// For persistent storage, use `FileProviderStorage`.
public protocol ProviderStorage: Sendable {
    /// Adds a provider for a content key.
    ///
    /// If the provider already exists for this key, updates its addresses and TTL.
    ///
    /// - Parameters:
    ///   - key: The content key (CID or similar).
    ///   - record: The provider record to add.
    ///   - ttl: Time-to-live for the provider record.
    /// - Returns: `true` if the provider was added or updated, `false` if rejected (e.g., storage full).
    /// - Throws: If the storage operation fails.
    @discardableResult
    func addProvider(for key: Data, record: ProviderRecord, ttl: Duration) throws -> Bool

    /// Gets all non-expired providers for a content key.
    ///
    /// - Parameter key: The content key.
    /// - Returns: An array of provider records.
    /// - Throws: If the storage operation fails.
    func getProviders(for key: Data) throws -> [ProviderRecord]

    /// Removes a specific provider for a content key.
    ///
    /// - Parameters:
    ///   - key: The content key.
    ///   - peerID: The provider's peer ID to remove.
    /// - Throws: If the storage operation fails.
    func removeProvider(for key: Data, peerID: PeerID) throws

    /// Returns content keys where the local node is a provider that needs republishing.
    ///
    /// - Parameters:
    ///   - localPeerID: The local peer ID.
    ///   - threshold: The republish interval threshold.
    /// - Returns: Content keys needing republish.
    /// - Throws: If the storage operation fails.
    func keysNeedingRepublish(localPeerID: PeerID, threshold: Duration) throws -> [Data]

    /// Removes all expired provider records.
    ///
    /// - Returns: The number of provider records removed.
    /// - Throws: If the storage operation fails.
    @discardableResult
    func cleanup() throws -> Int

    /// Removes all provider records (expired and non-expired).
    ///
    /// - Throws: If the storage operation fails.
    func removeAll() throws

    /// The total number of non-expired provider records across all keys.
    var totalProviderCount: Int { get }
}
