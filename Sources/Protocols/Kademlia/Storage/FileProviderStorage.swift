/// FileProviderStorage - File-based persistent implementation of ProviderStorage.

import Foundation
import Synchronization
import Crypto
import P2PCore

/// File-based persistent storage backend for content provider records.
///
/// Provider records are stored as JSON files in a directory structure:
/// ```
/// <baseDirectory>/providers/<first2hex>/<sha256hex>.json
/// ```
///
/// Each file stores an array of provider records for a single content key.
/// Uses a write-through cache: all records are kept in memory and
/// written to disk on every mutation.
public final class FileProviderStorage: ProviderStorage, Sendable {

    /// Codable representation of a persisted provider entry.
    ///
    /// Timestamps are stored as wall-clock `Date` values (seconds since reference date)
    /// so that they survive process restarts.
    struct PersistedProvider: Codable, Sendable {
        let peerID: String
        let addresses: [String]
        /// Wall-clock timestamp when provider was added (Date.timeIntervalSinceReferenceDate).
        let addedAtWallclock: TimeInterval
        /// Wall-clock timestamp when provider expires (Date.timeIntervalSinceReferenceDate).
        let expiresAtWallclock: TimeInterval
    }

    /// Codable representation of all providers for a single key.
    struct PersistedProviderSet: Codable, Sendable {
        let key: Data
        var providers: [PersistedProvider]
    }

    /// In-memory cached provider with metadata.
    private struct CachedProvider: Sendable {
        var record: ProviderRecord
        var expiresAt: ContinuousClock.Instant
    }

    private struct State: Sendable {
        var providers: [Data: [PeerID: CachedProvider]] = [:]
    }

    private let state: Mutex<State>

    /// Base directory for provider storage.
    public let baseDirectory: URL

    /// Maximum providers per content key.
    public let maxProvidersPerKey: Int

    /// Maximum total content keys.
    public let maxKeys: Int

    private let providersDirectory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// Errors specific to file-based provider storage.
    public enum FileProviderStorageError: Error, Sendable {
        case directoryCreationFailed(String)
        case writeFailed(String)
        case readFailed(String)
    }

    /// Creates a new file-based provider storage.
    ///
    /// Loads existing provider records from the directory on initialization.
    ///
    /// - Parameters:
    ///   - directory: The base directory for storing providers.
    ///   - maxProvidersPerKey: Maximum providers per content key (default: 20).
    ///   - maxKeys: Maximum content keys to track (default: 1024).
    /// - Throws: If the directory cannot be created or existing records cannot be loaded.
    public init(
        directory: URL,
        maxProvidersPerKey: Int = KademliaProtocol.kValue,
        maxKeys: Int = 1024
    ) throws {
        self.baseDirectory = directory
        self.maxProvidersPerKey = maxProvidersPerKey
        self.maxKeys = maxKeys
        self.providersDirectory = directory.appendingPathComponent("providers")
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.state = Mutex(State())

        // Create directory structure
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: providersDirectory.path) {
            do {
                try fileManager.createDirectory(at: providersDirectory, withIntermediateDirectories: true)
            } catch {
                throw FileProviderStorageError.directoryCreationFailed(error.localizedDescription)
            }
        }

        // Load existing providers from disk
        let loaded = try loadFromDisk()
        state.withLock { s in
            s.providers = loaded
        }
    }

    // MARK: - ProviderStorage

    @discardableResult
    public func addProvider(for key: Data, record: ProviderRecord, ttl: Duration) throws -> Bool {
        let expiresAt = ContinuousClock.now.advanced(by: ttl)

        let result = state.withLock { s -> Bool in
            var keyProviders = s.providers[key] ?? [:]

            // If provider already exists, update it
            if var existing = keyProviders[record.peerID] {
                existing.record.addresses = record.addresses
                existing.expiresAt = expiresAt
                keyProviders[record.peerID] = existing
                s.providers[key] = keyProviders
                return true
            }

            // Check per-key capacity
            if keyProviders.count >= maxProvidersPerKey {
                let now = ContinuousClock.now
                keyProviders = keyProviders.filter { $0.value.expiresAt > now }

                if keyProviders.count >= maxProvidersPerKey {
                    return false
                }
            }

            // Check key capacity
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

            keyProviders[record.peerID] = CachedProvider(record: record, expiresAt: expiresAt)
            s.providers[key] = keyProviders
            return true
        }

        if result {
            try syncKeyToDisk(key)
        }

        return result
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

        try syncKeyToDisk(key)
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
        var keysToSync: [Data] = []

        let removed = state.withLock { s -> Int in
            var totalRemoved = 0
            for (key, var keyProviders) in s.providers {
                let before = keyProviders.count
                keyProviders = keyProviders.filter { $0.value.expiresAt > now }
                let diff = before - keyProviders.count
                totalRemoved += diff

                if keyProviders.isEmpty {
                    s.providers.removeValue(forKey: key)
                    keysToSync.append(key)
                } else if diff > 0 {
                    s.providers[key] = keyProviders
                    keysToSync.append(key)
                }
            }
            return totalRemoved
        }

        // Sync changed keys to disk outside of lock
        for key in keysToSync {
            try syncKeyToDisk(key)
        }

        return removed
    }

    public func removeAll() throws {
        let keys = state.withLock { s -> [Data] in
            let keys = Array(s.providers.keys)
            s.providers.removeAll()
            return keys
        }

        // Remove all files outside of lock
        let fileManager = FileManager.default
        for key in keys {
            let path = filePath(for: key)
            if fileManager.fileExists(atPath: path.path) {
                do {
                    try fileManager.removeItem(at: path)
                } catch {
                    throw FileProviderStorageError.writeFailed(error.localizedDescription)
                }
            }
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

    // MARK: - File Operations

    /// Computes the file path for a given content key.
    private func filePath(for key: Data) -> URL {
        let hash = SHA256.hash(data: key)
        let hex = hash.map { String(format: "%02x", $0) }.joined()
        let prefix = String(hex.prefix(2))
        let dir = providersDirectory.appendingPathComponent(prefix)
        return dir.appendingPathComponent("\(hex).json")
    }

    /// Syncs the in-memory state for a key to disk.
    ///
    /// If the key has no providers, the file is removed.
    /// Otherwise, the file is written with the current providers.
    private func syncKeyToDisk(_ key: Data) throws {
        let path = filePath(for: key)
        let fileManager = FileManager.default

        let providers: [PeerID: CachedProvider]? = state.withLock { s in
            s.providers[key]
        }

        guard let providers, !providers.isEmpty else {
            // Remove file if no providers
            if fileManager.fileExists(atPath: path.path) {
                try? fileManager.removeItem(at: path)
            }
            return
        }

        // Build persisted representation using wall-clock dates
        let now = ContinuousClock.now
        let dateNow = Date()
        let persistedProviders: [PersistedProvider] = providers.values
            .filter { $0.expiresAt > now }
            .map { cached in
                PersistedProvider(
                    peerID: cached.record.peerID.description,
                    addresses: cached.record.addresses.map { $0.description },
                    addedAtWallclock: dateNow.addingTimeInterval(
                        durationToSeconds(cached.record.addedAt - now)
                    ).timeIntervalSinceReferenceDate,
                    expiresAtWallclock: dateNow.addingTimeInterval(
                        durationToSeconds(cached.expiresAt - now)
                    ).timeIntervalSinceReferenceDate
                )
            }

        guard !persistedProviders.isEmpty else {
            if fileManager.fileExists(atPath: path.path) {
                try? fileManager.removeItem(at: path)
            }
            return
        }

        let persistedSet = PersistedProviderSet(key: key, providers: persistedProviders)

        // Ensure directory exists
        let dir = path.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: dir.path) {
            do {
                try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                throw FileProviderStorageError.directoryCreationFailed(error.localizedDescription)
            }
        }

        do {
            let data = try encoder.encode(persistedSet)
            try data.write(to: path, options: .atomic)
        } catch {
            throw FileProviderStorageError.writeFailed(error.localizedDescription)
        }
    }

    /// Loads all provider records from disk.
    private func loadFromDisk() throws -> [Data: [PeerID: CachedProvider]] {
        let fileManager = FileManager.default
        var result: [Data: [PeerID: CachedProvider]] = [:]
        let now = ContinuousClock.now

        guard fileManager.fileExists(atPath: providersDirectory.path) else {
            return result
        }

        let prefixDirs: [URL]
        do {
            prefixDirs = try fileManager.contentsOfDirectory(
                at: providersDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw FileProviderStorageError.readFailed(error.localizedDescription)
        }

        for prefixDir in prefixDirs {
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: prefixDir.path, isDirectory: &isDir),
                  isDir.boolValue else {
                continue
            }

            let files: [URL]
            do {
                files = try fileManager.contentsOfDirectory(
                    at: prefixDir,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )
            } catch {
                continue
            }

            for file in files {
                guard file.pathExtension == "json" else { continue }

                do {
                    let data = try Data(contentsOf: file)
                    let persistedSet = try decoder.decode(PersistedProviderSet.self, from: data)

                    var keyProviders: [PeerID: CachedProvider] = [:]

                    for persisted in persistedSet.providers {
                        let peerID = try PeerID(string: persisted.peerID)
                        let addresses = persisted.addresses.compactMap { addrString -> Multiaddr? in
                            do {
                                return try Multiaddr(addrString)
                            } catch {
                                return nil
                            }
                        }

                        // Convert wall-clock dates back to monotonic instants
                        let expiresAt = wallclockToInstant(
                            Date(timeIntervalSinceReferenceDate: persisted.expiresAtWallclock)
                        )
                        guard expiresAt > now else { continue }

                        // Reconstruct ProviderRecord.
                        // ProviderRecord.addedAt is a `let` set to `.now` at init,
                        // so loaded records get a fresh addedAt. For republish checks
                        // this means records loaded from disk will not immediately
                        // need republishing, which is acceptable behavior.
                        let record = ProviderRecord(peerID: peerID, addresses: addresses)

                        keyProviders[peerID] = CachedProvider(
                            record: record,
                            expiresAt: expiresAt
                        )
                    }

                    if !keyProviders.isEmpty {
                        result[persistedSet.key] = keyProviders
                    } else {
                        // Remove file with no valid providers
                        try? fileManager.removeItem(at: file)
                    }
                } catch {
                    // Skip corrupt files
                    continue
                }
            }
        }

        return result
    }

}

// MARK: - Wall-Clock / Monotonic Conversion Helpers

/// Converts a Duration to seconds as a Double.
private func durationToSeconds(_ duration: Duration) -> Double {
    let (seconds, attoseconds) = duration.components
    return Double(seconds) + Double(attoseconds) / 1e18
}

/// Converts a wall-clock Date to a ContinuousClock.Instant.
///
/// Computes the time difference between the date and now (wall-clock),
/// then applies that offset to the current monotonic time.
private func wallclockToInstant(_ date: Date) -> ContinuousClock.Instant {
    let secondsFromNow = date.timeIntervalSinceNow
    let wholeSeconds = Int64(secondsFromNow)
    let fractionalAttoseconds = Int64((secondsFromNow - Double(wholeSeconds)) * 1e18)
    let duration = Duration(secondsComponent: wholeSeconds, attosecondsComponent: fractionalAttoseconds)
    return ContinuousClock.now.advanced(by: duration)
}
