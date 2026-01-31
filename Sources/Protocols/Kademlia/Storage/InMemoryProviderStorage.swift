/// InMemoryProviderStorage - In-memory implementation of ProviderStorage.

import Foundation
import Synchronization
import P2PCore

/// In-memory storage backend for content provider records.
///
/// Stores provider records in nested dictionaries with TTL-based expiration.
/// All operations are thread-safe via `Mutex`.
public final class InMemoryProviderStorage: ProviderStorage, Sendable {

    /// Internal stored provider with expiration metadata.
    private struct StoredProvider: Sendable {
        var record: ProviderRecord
        var expiresAt: ContinuousClock.Instant
    }

    private struct State: Sendable {
        var providers: [Data: [PeerID: StoredProvider]] = [:]
    }

    private let state: Mutex<State>

    /// Maximum providers per content key.
    public let maxProvidersPerKey: Int

    /// Maximum total content keys.
    public let maxKeys: Int

    /// Creates a new in-memory provider storage.
    ///
    /// - Parameters:
    ///   - maxProvidersPerKey: Maximum providers per content key (default: 20).
    ///   - maxKeys: Maximum content keys to track (default: 1024).
    public init(
        maxProvidersPerKey: Int = KademliaProtocol.kValue,
        maxKeys: Int = 1024
    ) {
        self.maxProvidersPerKey = maxProvidersPerKey
        self.maxKeys = maxKeys
        self.state = Mutex(State())
    }

    @discardableResult
    public func addProvider(for key: Data, record: ProviderRecord, ttl: Duration) throws -> Bool {
        let expiresAt = ContinuousClock.now.advanced(by: ttl)

        return state.withLock { s in
            var keyProviders = s.providers[key] ?? [:]

            // If provider already exists, update it
            if var existing = keyProviders[record.peerID] {
                existing.record.addresses = record.addresses
                existing.expiresAt = expiresAt
                keyProviders[record.peerID] = existing
                s.providers[key] = keyProviders
                return true
            }

            // Check if we can add a new provider for this key
            if keyProviders.count >= maxProvidersPerKey {
                let now = ContinuousClock.now
                keyProviders = keyProviders.filter { $0.value.expiresAt > now }

                if keyProviders.count >= maxProvidersPerKey {
                    return false
                }
            }

            // Check if we can add a new key
            if s.providers[key] == nil && s.providers.count >= maxKeys {
                for (k, var ps) in s.providers {
                    let now = ContinuousClock.now
                    ps = ps.filter { $0.value.expiresAt > now }
                    if ps.isEmpty {
                        s.providers.removeValue(forKey: k)
                    } else {
                        s.providers[k] = ps
                    }
                }

                if s.providers.count >= maxKeys {
                    return false
                }
            }

            keyProviders[record.peerID] = StoredProvider(record: record, expiresAt: expiresAt)
            s.providers[key] = keyProviders
            return true
        }
    }

    public func getProviders(for key: Data) throws -> [ProviderRecord] {
        let now = ContinuousClock.now
        return state.withLock { s in
            guard let keyProviders = s.providers[key] else { return [] }
            return keyProviders.values
                .filter { $0.expiresAt > now }
                .map { $0.record }
        }
    }

    public func removeProvider(for key: Data, peerID: PeerID) throws {
        state.withLock { s in
            guard var keyProviders = s.providers[key] else { return }
            keyProviders.removeValue(forKey: peerID)

            if keyProviders.isEmpty {
                s.providers.removeValue(forKey: key)
            } else {
                s.providers[key] = keyProviders
            }
        }
    }

    public func keysNeedingRepublish(localPeerID: PeerID, threshold: Duration) throws -> [Data] {
        let cutoff = ContinuousClock.now - threshold
        let now = ContinuousClock.now

        return state.withLock { s in
            s.providers.compactMap { key, keyProviders in
                guard let stored = keyProviders[localPeerID],
                      stored.expiresAt > now,
                      stored.record.addedAt < cutoff else {
                    return nil
                }
                return key
            }
        }
    }

    @discardableResult
    public func cleanup() throws -> Int {
        let now = ContinuousClock.now
        return state.withLock { s in
            var removed = 0
            for (key, var keyProviders) in s.providers {
                let before = keyProviders.count
                keyProviders = keyProviders.filter { $0.value.expiresAt > now }
                removed += before - keyProviders.count

                if keyProviders.isEmpty {
                    s.providers.removeValue(forKey: key)
                } else {
                    s.providers[key] = keyProviders
                }
            }
            return removed
        }
    }

    public func removeAll() throws {
        state.withLock { s in
            s.providers.removeAll()
        }
    }

    public var totalProviderCount: Int {
        let now = ContinuousClock.now
        return state.withLock { s in
            s.providers.values.reduce(0) { total, keyProviders in
                total + keyProviders.values.filter { $0.expiresAt > now }.count
            }
        }
    }
}
