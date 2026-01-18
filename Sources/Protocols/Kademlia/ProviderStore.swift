/// ProviderStore - Storage for content provider records.

import Foundation
import Synchronization
import P2PCore

/// A provider record.
public struct ProviderRecord: Sendable, Equatable {
    /// The provider's peer ID.
    public let peerID: PeerID

    /// Known addresses for the provider.
    public var addresses: [Multiaddr]

    /// When this provider record was added.
    public let addedAt: ContinuousClock.Instant

    /// Creates a provider record.
    public init(peerID: PeerID, addresses: [Multiaddr] = []) {
        self.peerID = peerID
        self.addresses = addresses
        self.addedAt = .now
    }
}

/// Storage for content providers with TTL support.
public final class ProviderStore: Sendable {
    /// Internal stored provider with expiration.
    private struct StoredProvider: Sendable {
        var record: ProviderRecord
        var expiresAt: ContinuousClock.Instant
    }

    /// Providers indexed by content key.
    private let providers: Mutex<[Data: [PeerID: StoredProvider]]>

    /// Maximum providers per key.
    public let maxProvidersPerKey: Int

    /// Maximum total keys.
    public let maxKeys: Int

    /// Default TTL for provider records.
    public let defaultTTL: Duration

    /// Creates a new provider store.
    ///
    /// - Parameters:
    ///   - maxProvidersPerKey: Maximum providers per content key (default: 20).
    ///   - maxKeys: Maximum content keys to track (default: 1024).
    ///   - defaultTTL: Default TTL for provider records (default: 24 hours).
    public init(
        maxProvidersPerKey: Int = KademliaProtocol.kValue,
        maxKeys: Int = 1024,
        defaultTTL: Duration = KademliaProtocol.providerTTL
    ) {
        self.maxProvidersPerKey = maxProvidersPerKey
        self.maxKeys = maxKeys
        self.defaultTTL = defaultTTL
        self.providers = Mutex([:])
    }

    /// Adds a provider for a content key.
    ///
    /// - Parameters:
    ///   - key: The content key (CID or similar).
    ///   - peerID: The provider's peer ID.
    ///   - addresses: Known addresses for the provider.
    ///   - ttl: Time-to-live (uses default if nil).
    /// - Returns: True if added, false if rejected.
    @discardableResult
    public func addProvider(
        for key: Data,
        peerID: PeerID,
        addresses: [Multiaddr] = [],
        ttl: Duration? = nil
    ) -> Bool {
        let effectiveTTL = ttl ?? defaultTTL
        let expiresAt = ContinuousClock.now.advanced(by: effectiveTTL)

        return providers.withLock { providers in
            // Get or create provider set for this key
            var keyProviders = providers[key] ?? [:]

            // If provider already exists, update it
            if var existing = keyProviders[peerID] {
                existing.record.addresses = addresses
                existing.expiresAt = expiresAt
                keyProviders[peerID] = existing
                providers[key] = keyProviders
                return true
            }

            // Check if we can add a new provider for this key
            if keyProviders.count >= maxProvidersPerKey {
                // Try to evict expired providers
                let now = ContinuousClock.now
                keyProviders = keyProviders.filter { $0.value.expiresAt > now }

                if keyProviders.count >= maxProvidersPerKey {
                    return false
                }
            }

            // Check if we can add a new key
            if providers[key] == nil && providers.count >= maxKeys {
                // Try to cleanup expired keys
                for (k, var ps) in providers {
                    let now = ContinuousClock.now
                    ps = ps.filter { $0.value.expiresAt > now }
                    if ps.isEmpty {
                        providers.removeValue(forKey: k)
                    } else {
                        providers[k] = ps
                    }
                }

                if providers.count >= maxKeys {
                    return false
                }
            }

            // Add the provider
            let record = ProviderRecord(peerID: peerID, addresses: addresses)
            keyProviders[peerID] = StoredProvider(record: record, expiresAt: expiresAt)
            providers[key] = keyProviders
            return true
        }
    }

    /// Gets providers for a content key.
    ///
    /// - Parameter key: The content key.
    /// - Returns: Non-expired providers for this key.
    public func getProviders(for key: Data) -> [ProviderRecord] {
        let now = ContinuousClock.now

        return providers.withLock { providers in
            guard let keyProviders = providers[key] else { return [] }

            return keyProviders.values
                .filter { $0.expiresAt > now }
                .map { $0.record }
        }
    }

    /// Removes a provider for a content key.
    ///
    /// - Parameters:
    ///   - key: The content key.
    ///   - peerID: The provider to remove.
    /// - Returns: The removed provider record, if found.
    @discardableResult
    public func removeProvider(for key: Data, peerID: PeerID) -> ProviderRecord? {
        providers.withLock { providers in
            guard var keyProviders = providers[key] else { return nil }

            let removed = keyProviders.removeValue(forKey: peerID)?.record

            if keyProviders.isEmpty {
                providers.removeValue(forKey: key)
            } else {
                providers[key] = keyProviders
            }

            return removed
        }
    }

    /// Removes all providers for a content key.
    ///
    /// - Parameter key: The content key.
    /// - Returns: Number of providers removed.
    @discardableResult
    public func removeAllProviders(for key: Data) -> Int {
        providers.withLock { providers in
            let count = providers[key]?.count ?? 0
            providers.removeValue(forKey: key)
            return count
        }
    }

    /// Checks if there are any providers for a content key.
    ///
    /// - Parameter key: The content key.
    /// - Returns: True if there are non-expired providers.
    public func hasProviders(for key: Data) -> Bool {
        !getProviders(for: key).isEmpty
    }

    /// Returns all content keys that have providers.
    public var allKeys: [Data] {
        let now = ContinuousClock.now

        return providers.withLock { providers in
            providers.compactMap { key, keyProviders in
                let hasValid = keyProviders.values.contains { $0.expiresAt > now }
                return hasValid ? key : nil
            }
        }
    }

    /// Returns the total number of provider records.
    public var totalProviderCount: Int {
        let now = ContinuousClock.now

        return providers.withLock { providers in
            providers.values.reduce(0) { total, keyProviders in
                total + keyProviders.values.filter { $0.expiresAt > now }.count
            }
        }
    }

    /// Returns the number of content keys with providers.
    public var keyCount: Int {
        allKeys.count
    }

    /// Removes all expired provider records.
    ///
    /// - Returns: Number of provider records removed.
    @discardableResult
    public func cleanup() -> Int {
        let now = ContinuousClock.now

        return providers.withLock { providers in
            var removed = 0

            for (key, var keyProviders) in providers {
                let before = keyProviders.count
                keyProviders = keyProviders.filter { $0.value.expiresAt > now }
                removed += before - keyProviders.count

                if keyProviders.isEmpty {
                    providers.removeValue(forKey: key)
                } else {
                    providers[key] = keyProviders
                }
            }

            return removed
        }
    }

    /// Removes all provider records.
    public func clear() {
        providers.withLock { providers in
            providers.removeAll()
        }
    }

    /// Returns keys where local node is a provider that need republishing.
    ///
    /// - Parameters:
    ///   - localPeerID: The local peer ID.
    ///   - threshold: Republish interval (default: 12 hours).
    /// - Returns: Content keys needing republish.
    public func keysNeedingRepublish(
        localPeerID: PeerID,
        threshold: Duration = KademliaProtocol.providerRepublishInterval
    ) -> [Data] {
        let cutoff = ContinuousClock.now - threshold
        let now = ContinuousClock.now

        return providers.withLock { providers in
            providers.compactMap { key, keyProviders in
                guard let stored = keyProviders[localPeerID],
                      stored.expiresAt > now,
                      stored.record.addedAt < cutoff else {
                    return nil
                }
                return key
            }
        }
    }
}
