/// FileRecordStorage - File-based persistent implementation of RecordStorage.

import Foundation
import Synchronization
import Crypto

/// File-based persistent storage backend for Kademlia DHT records.
///
/// Records are stored as JSON files in a directory structure:
/// ```
/// <baseDirectory>/records/<first2hex>/<sha256hex>.json
/// ```
///
/// Uses a write-through cache: all records are kept in memory and
/// written to disk on every mutation. On initialization, records are
/// loaded from the directory.
public final class FileRecordStorage: RecordStorage, Sendable {

    /// Codable representation of a persisted record.
    ///
    /// Timestamps are stored as wall-clock `Date` values (seconds since reference date)
    /// so that they survive process restarts. `ContinuousClock.Instant` is monotonic and
    /// process-relative, making it unsuitable for persistent storage.
    struct PersistedRecord: Codable, Sendable {
        let key: Data
        let value: Data
        let timeReceived: String?
        /// Wall-clock timestamp when record was stored (Date.timeIntervalSinceReferenceDate).
        let storedAtWallclock: TimeInterval
        /// Wall-clock timestamp when record expires (Date.timeIntervalSinceReferenceDate).
        let expiresAtWallclock: TimeInterval

        init(record: KademliaRecord, storedAt: ContinuousClock.Instant, expiresAt: ContinuousClock.Instant) {
            self.key = record.key
            self.value = record.value
            self.timeReceived = record.timeReceived
            // Convert monotonic ContinuousClock instants to wall-clock Date values.
            // Compute relative offsets from current monotonic time,
            // then apply to current wall-clock time.
            let now = ContinuousClock.now
            let dateNow = Date()
            self.storedAtWallclock = dateNow.addingTimeInterval(
                durationToSeconds(storedAt - now)
            ).timeIntervalSinceReferenceDate
            self.expiresAtWallclock = dateNow.addingTimeInterval(
                durationToSeconds(expiresAt - now)
            ).timeIntervalSinceReferenceDate
        }

        var kademliaRecord: KademliaRecord {
            KademliaRecord(key: key, value: value, timeReceived: timeReceived)
        }

        var storedAtInstant: ContinuousClock.Instant {
            wallclockToInstant(Date(timeIntervalSinceReferenceDate: storedAtWallclock))
        }

        var expiresAtInstant: ContinuousClock.Instant {
            wallclockToInstant(Date(timeIntervalSinceReferenceDate: expiresAtWallclock))
        }
    }

    /// In-memory cached record with metadata.
    private struct CachedRecord: Sendable {
        let record: KademliaRecord
        let storedAt: ContinuousClock.Instant
        let expiresAt: ContinuousClock.Instant
        let filePath: URL
    }

    private struct State: Sendable {
        var records: [Data: CachedRecord] = [:]
    }

    private let state: Mutex<State>

    /// Base directory for record storage.
    public let baseDirectory: URL

    /// Maximum number of records to store.
    public let maxRecords: Int

    private let recordsDirectory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// Errors specific to file-based record storage.
    public enum FileRecordStorageError: Error, Sendable {
        case directoryCreationFailed(String)
        case writeFailed(String)
        case readFailed(String)
    }

    /// Creates a new file-based record storage.
    ///
    /// Loads existing records from the directory on initialization.
    ///
    /// - Parameters:
    ///   - directory: The base directory for storing records.
    ///   - maxRecords: Maximum number of records (default: 1024).
    /// - Throws: If the directory cannot be created or existing records cannot be loaded.
    public init(directory: URL, maxRecords: Int = 1024) throws {
        self.baseDirectory = directory
        self.maxRecords = maxRecords
        self.recordsDirectory = directory.appendingPathComponent("records")
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.state = Mutex(State())

        // Create directory structure
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: recordsDirectory.path) {
            do {
                try fileManager.createDirectory(at: recordsDirectory, withIntermediateDirectories: true)
            } catch {
                throw FileRecordStorageError.directoryCreationFailed(error.localizedDescription)
            }
        }

        // Load existing records from disk
        let loaded = try loadFromDisk()
        state.withLock { s in
            s.records = loaded
        }
    }

    // MARK: - RecordStorage

    public func put(_ record: KademliaRecord, ttl: Duration) throws {
        let now = ContinuousClock.now
        let expiresAt = now.advanced(by: ttl)
        let filePath = self.filePath(for: record.key)

        // Write to disk first
        let persisted = PersistedRecord(record: record, storedAt: now, expiresAt: expiresAt)
        try writeToDisk(persisted, at: filePath)

        // Then update cache
        let cached = CachedRecord(record: record, storedAt: now, expiresAt: expiresAt, filePath: filePath)
        state.withLock { s in
            // If already exists, update
            if s.records[record.key] != nil {
                s.records[record.key] = cached
                return
            }

            // Check capacity
            if s.records.count >= maxRecords {
                s.records = s.records.filter { $0.value.expiresAt > now }

                if s.records.count >= maxRecords {
                    // Remove the file we just wrote since we cannot cache it
                    try? FileManager.default.removeItem(at: filePath)
                    return
                }
            }

            s.records[record.key] = cached
        }
    }

    public func get(_ key: Data) throws -> KademliaRecord? {
        state.withLock { s in
            guard let cached = s.records[key] else { return nil }

            if cached.expiresAt <= ContinuousClock.now {
                s.records.removeValue(forKey: key)
                try? FileManager.default.removeItem(at: cached.filePath)
                return nil
            }

            return cached.record
        }
    }

    public func remove(_ key: Data) throws {
        state.withLock { s in
            if let cached = s.records.removeValue(forKey: key) {
                try? FileManager.default.removeItem(at: cached.filePath)
            }
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
                .filter { cached in
                    cached.expiresAt > now && cached.storedAt < cutoff
                }
                .map { $0.record }
        }
    }

    @discardableResult
    public func cleanup() throws -> Int {
        let now = ContinuousClock.now
        var filesToRemove: [URL] = []

        let removed = state.withLock { s -> Int in
            let before = s.records.count
            var toRemove: [Data] = []
            for (key, cached) in s.records {
                if cached.expiresAt <= now {
                    toRemove.append(key)
                    filesToRemove.append(cached.filePath)
                }
            }
            for key in toRemove {
                s.records.removeValue(forKey: key)
            }
            return before - s.records.count
        }

        // Remove files outside of lock
        for fileURL in filesToRemove {
            try? FileManager.default.removeItem(at: fileURL)
        }

        return removed
    }

    public var count: Int {
        let now = ContinuousClock.now
        return state.withLock { s in
            s.records.values.filter { $0.expiresAt > now }.count
        }
    }

    // MARK: - File Operations

    /// Computes the file path for a given record key.
    private func filePath(for key: Data) -> URL {
        let hash = SHA256.hash(data: key)
        let hex = hash.map { String(format: "%02x", $0) }.joined()
        let prefix = String(hex.prefix(2))
        let dir = recordsDirectory.appendingPathComponent(prefix)
        return dir.appendingPathComponent("\(hex).json")
    }

    /// Writes a persisted record to disk.
    private func writeToDisk(_ persisted: PersistedRecord, at path: URL) throws {
        let fileManager = FileManager.default
        let dir = path.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: dir.path) {
            do {
                try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                throw FileRecordStorageError.directoryCreationFailed(error.localizedDescription)
            }
        }

        do {
            let data = try encoder.encode(persisted)
            try data.write(to: path, options: .atomic)
        } catch {
            throw FileRecordStorageError.writeFailed(error.localizedDescription)
        }
    }

    /// Loads all records from disk.
    private func loadFromDisk() throws -> [Data: CachedRecord] {
        let fileManager = FileManager.default
        var records: [Data: CachedRecord] = [:]
        let now = ContinuousClock.now

        guard fileManager.fileExists(atPath: recordsDirectory.path) else {
            return records
        }

        let prefixDirs: [URL]
        do {
            prefixDirs = try fileManager.contentsOfDirectory(
                at: recordsDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw FileRecordStorageError.readFailed(error.localizedDescription)
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
                    let persisted = try decoder.decode(PersistedRecord.self, from: data)

                    let expiresAt = persisted.expiresAtInstant
                    // Skip expired records, remove their files
                    guard expiresAt > now else {
                        try? fileManager.removeItem(at: file)
                        continue
                    }

                    let cached = CachedRecord(
                        record: persisted.kademliaRecord,
                        storedAt: persisted.storedAtInstant,
                        expiresAt: expiresAt,
                        filePath: file
                    )
                    records[persisted.key] = cached
                } catch {
                    // Skip corrupt files but do not crash
                    continue
                }
            }
        }

        return records
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
