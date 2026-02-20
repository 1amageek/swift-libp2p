/// PersistentStorageTests - Tests for Kademlia persistent storage backends.

import Testing
import Foundation
@testable import P2PKademlia
@testable import P2PCore

// MARK: - InMemory Record Storage Tests

@Suite("InMemory Record Storage Tests")
struct InMemoryRecordStorageTests {

    @Test("Put and get record")
    func putAndGet() throws {
        let storage = InMemoryRecordStorage()
        let key = Data("test-key".utf8)
        let value = Data("test-value".utf8)
        let record = KademliaRecord(key: key, value: value)

        try storage.put(record, ttl: .seconds(3600))

        let retrieved = try storage.get(key)
        #expect(retrieved != nil)
        #expect(retrieved?.key == key)
        #expect(retrieved?.value == value)
    }

    @Test("Get nonexistent record returns nil")
    func getNonexistent() throws {
        let storage = InMemoryRecordStorage()
        let result = try storage.get(Data("nonexistent".utf8))
        #expect(result == nil)
    }

    @Test("Remove record")
    func removeRecord() throws {
        let storage = InMemoryRecordStorage()
        let key = Data("test-key".utf8)
        let record = KademliaRecord(key: key, value: Data("value".utf8))

        try storage.put(record, ttl: .seconds(3600))
        try storage.remove(key)

        let retrieved = try storage.get(key)
        #expect(retrieved == nil)
        #expect(storage.count == 0)
    }

    @Test("AllRecords returns all non-expired records")
    func allRecords() throws {
        let storage = InMemoryRecordStorage()

        for i in 0..<3 {
            let record = KademliaRecord(
                key: Data("key-\(i)".utf8),
                value: Data("value-\(i)".utf8)
            )
            try storage.put(record, ttl: .seconds(3600))
        }

        let all = try storage.allRecords()
        #expect(all.count == 3)
    }

    @Test("Cleanup removes expired records")
    func cleanup() async throws {
        let storage = InMemoryRecordStorage()

        for i in 0..<5 {
            let record = KademliaRecord(
                key: Data("key-\(i)".utf8),
                value: Data("value".utf8)
            )
            try storage.put(record, ttl: .milliseconds(50))
        }

        #expect(storage.count == 5)

        try await Task.sleep(for: .milliseconds(100))

        let removed = try storage.cleanup()
        #expect(removed == 5)
        #expect(storage.count == 0)
    }

    @Test("Count reflects non-expired records")
    func countReflectsNonExpired() throws {
        let storage = InMemoryRecordStorage()
        let record = KademliaRecord(key: Data("key".utf8), value: Data("value".utf8))

        try storage.put(record, ttl: .seconds(3600))
        #expect(storage.count == 1)

        try storage.remove(Data("key".utf8))
        #expect(storage.count == 0)
    }
}

// MARK: - InMemory Provider Storage Tests

@Suite("InMemory Provider Storage Tests")
struct InMemoryProviderStorageTests {

    @Test("Add and get provider")
    func addAndGet() throws {
        let storage = InMemoryProviderStorage()
        let contentKey = Data("content-cid".utf8)
        let peerID = KeyPair.generateEd25519().peerID
        let record = ProviderRecord(peerID: peerID)

        let added = try storage.addProvider(for: contentKey, record: record, ttl: .seconds(3600))
        #expect(added == true)

        let providers = try storage.getProviders(for: contentKey)
        #expect(providers.count == 1)
        #expect(providers[0].peerID == peerID)
    }

    @Test("Remove provider")
    func removeProvider() throws {
        let storage = InMemoryProviderStorage()
        let contentKey = Data("content-cid".utf8)
        let peerID = KeyPair.generateEd25519().peerID
        let record = ProviderRecord(peerID: peerID)

        _ = try storage.addProvider(for: contentKey, record: record, ttl: .seconds(3600))
        try storage.removeProvider(for: contentKey, peerID: peerID)

        let providers = try storage.getProviders(for: contentKey)
        #expect(providers.isEmpty)
    }

    @Test("Multiple providers for same key")
    func multipleProviders() throws {
        let storage = InMemoryProviderStorage()
        let contentKey = Data("content-cid".utf8)

        for _ in 0..<3 {
            let peerID = KeyPair.generateEd25519().peerID
            let record = ProviderRecord(peerID: peerID)
            _ = try storage.addProvider(for: contentKey, record: record, ttl: .seconds(3600))
        }

        let providers = try storage.getProviders(for: contentKey)
        #expect(providers.count == 3)
    }

    @Test("Cleanup removes expired providers")
    func cleanup() async throws {
        let storage = InMemoryProviderStorage()
        let contentKey = Data("content-cid".utf8)

        for _ in 0..<3 {
            let peerID = KeyPair.generateEd25519().peerID
            let record = ProviderRecord(peerID: peerID)
            _ = try storage.addProvider(for: contentKey, record: record, ttl: .milliseconds(50))
        }

        #expect(storage.totalProviderCount == 3)

        try await Task.sleep(for: .milliseconds(100))

        let removed = try storage.cleanup()
        #expect(removed == 3)
        #expect(storage.totalProviderCount == 0)
    }

    @Test("TotalProviderCount across multiple keys")
    func totalProviderCount() throws {
        let storage = InMemoryProviderStorage()

        for i in 0..<3 {
            let contentKey = Data("cid-\(i)".utf8)
            let peerID = KeyPair.generateEd25519().peerID
            let record = ProviderRecord(peerID: peerID)
            _ = try storage.addProvider(for: contentKey, record: record, ttl: .seconds(3600))
        }

        #expect(storage.totalProviderCount == 3)
    }
}

// MARK: - File Record Storage Tests

@Suite("File Record Storage Tests")
struct FileRecordStorageTests {

    /// Creates a unique temporary directory for each test.
    private func makeTempDir() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kademlia-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    /// Removes the temporary directory.
    private func cleanupDir(_ dir: URL) {
        do { try FileManager.default.removeItem(at: dir) } catch { }
    }

    @Test("File record put and get")
    func putAndGet() throws {
        let dir = try makeTempDir()
        defer { cleanupDir(dir) }

        let storage = try FileRecordStorage(directory: dir)
        let key = Data("file-test-key".utf8)
        let value = Data("file-test-value".utf8)
        let record = KademliaRecord(key: key, value: value)

        try storage.put(record, ttl: .seconds(3600))

        let retrieved = try storage.get(key)
        #expect(retrieved != nil)
        #expect(retrieved?.key == key)
        #expect(retrieved?.value == value)
    }

    @Test("File record persists after reopen")
    func persistsAfterReopen() throws {
        let dir = try makeTempDir()
        defer { cleanupDir(dir) }

        let key = Data("persist-key".utf8)
        let value = Data("persist-value".utf8)

        // First instance: write a record
        do {
            let storage = try FileRecordStorage(directory: dir)
            let record = KademliaRecord(key: key, value: value)
            try storage.put(record, ttl: .seconds(3600))
        }

        // Second instance: read the record back
        do {
            let storage = try FileRecordStorage(directory: dir)
            let retrieved = try storage.get(key)
            #expect(retrieved != nil)
            #expect(retrieved?.key == key)
            #expect(retrieved?.value == value)
            #expect(storage.count == 1)
        }
    }

    @Test("File record cleanup removes expired")
    func cleanupExpired() async throws {
        let dir = try makeTempDir()
        defer { cleanupDir(dir) }

        let storage = try FileRecordStorage(directory: dir)

        for i in 0..<3 {
            let record = KademliaRecord(
                key: Data("exp-key-\(i)".utf8),
                value: Data("value".utf8)
            )
            try storage.put(record, ttl: .milliseconds(50))
        }

        #expect(storage.count == 3)

        try await Task.sleep(for: .milliseconds(100))

        let removed = try storage.cleanup()
        #expect(removed == 3)
        #expect(storage.count == 0)
    }

    @Test("File record remove deletes from disk")
    func removeDeletesFromDisk() throws {
        let dir = try makeTempDir()
        defer { cleanupDir(dir) }

        let key = Data("remove-key".utf8)
        let record = KademliaRecord(key: key, value: Data("value".utf8))

        let storage = try FileRecordStorage(directory: dir)
        try storage.put(record, ttl: .seconds(3600))
        #expect(storage.count == 1)

        try storage.remove(key)
        #expect(storage.count == 0)

        // Reopen to verify file is gone
        let storage2 = try FileRecordStorage(directory: dir)
        #expect(storage2.count == 0)
    }

    @Test("File record allRecords returns all non-expired")
    func allRecordsNonExpired() throws {
        let dir = try makeTempDir()
        defer { cleanupDir(dir) }

        let storage = try FileRecordStorage(directory: dir)

        for i in 0..<5 {
            let record = KademliaRecord(
                key: Data("all-key-\(i)".utf8),
                value: Data("value-\(i)".utf8)
            )
            try storage.put(record, ttl: .seconds(3600))
        }

        let all = try storage.allRecords()
        #expect(all.count == 5)
    }

    @Test("File record update replaces existing")
    func updateReplacesExisting() throws {
        let dir = try makeTempDir()
        defer { cleanupDir(dir) }

        let storage = try FileRecordStorage(directory: dir)
        let key = Data("update-key".utf8)

        let record1 = KademliaRecord(key: key, value: Data("value-1".utf8))
        try storage.put(record1, ttl: .seconds(3600))

        let record2 = KademliaRecord(key: key, value: Data("value-2".utf8))
        try storage.put(record2, ttl: .seconds(3600))

        let retrieved = try storage.get(key)
        #expect(retrieved?.value == Data("value-2".utf8))
        #expect(storage.count == 1)
    }
}

// MARK: - File Provider Storage Tests

@Suite("File Provider Storage Tests")
struct FileProviderStorageTests {

    private func makeTempDir() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kademlia-prov-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    private func cleanupDir(_ dir: URL) {
        do { try FileManager.default.removeItem(at: dir) } catch { }
    }

    @Test("File provider put and get")
    func putAndGet() throws {
        let dir = try makeTempDir()
        defer { cleanupDir(dir) }

        let storage = try FileProviderStorage(directory: dir)
        let contentKey = Data("file-content-cid".utf8)
        let peerID = KeyPair.generateEd25519().peerID
        let record = ProviderRecord(peerID: peerID)

        let added = try storage.addProvider(for: contentKey, record: record, ttl: .seconds(3600))
        #expect(added == true)

        let providers = try storage.getProviders(for: contentKey)
        #expect(providers.count == 1)
        #expect(providers[0].peerID == peerID)
    }

    @Test("File provider persists after reopen")
    func persistsAfterReopen() throws {
        let dir = try makeTempDir()
        defer { cleanupDir(dir) }

        let contentKey = Data("persist-cid".utf8)
        let peerID = KeyPair.generateEd25519().peerID

        // First instance: add provider
        do {
            let storage = try FileProviderStorage(directory: dir)
            let record = ProviderRecord(peerID: peerID)
            _ = try storage.addProvider(for: contentKey, record: record, ttl: .seconds(3600))
        }

        // Second instance: read back
        do {
            let storage = try FileProviderStorage(directory: dir)
            let providers = try storage.getProviders(for: contentKey)
            #expect(providers.count == 1)
            #expect(providers[0].peerID == peerID)
            #expect(storage.totalProviderCount == 1)
        }
    }

    @Test("File provider cleanup removes expired")
    func cleanupExpired() async throws {
        let dir = try makeTempDir()
        defer { cleanupDir(dir) }

        let storage = try FileProviderStorage(directory: dir)
        let contentKey = Data("exp-cid".utf8)

        for _ in 0..<3 {
            let peerID = KeyPair.generateEd25519().peerID
            let record = ProviderRecord(peerID: peerID)
            _ = try storage.addProvider(for: contentKey, record: record, ttl: .milliseconds(50))
        }

        #expect(storage.totalProviderCount == 3)

        try await Task.sleep(for: .milliseconds(100))

        let removed = try storage.cleanup()
        #expect(removed == 3)
        #expect(storage.totalProviderCount == 0)
    }

    @Test("File provider remove")
    func removeProvider() throws {
        let dir = try makeTempDir()
        defer { cleanupDir(dir) }

        let storage = try FileProviderStorage(directory: dir)
        let contentKey = Data("remove-cid".utf8)
        let peerID = KeyPair.generateEd25519().peerID
        let record = ProviderRecord(peerID: peerID)

        _ = try storage.addProvider(for: contentKey, record: record, ttl: .seconds(3600))
        try storage.removeProvider(for: contentKey, peerID: peerID)

        let providers = try storage.getProviders(for: contentKey)
        #expect(providers.isEmpty)
    }
}

// MARK: - RecordStore with Custom Backend Tests

@Suite("RecordStore with Custom Backend Tests")
struct RecordStoreCustomBackendTests {

    private func makeTempDir() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kademlia-store-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    private func cleanupDir(_ dir: URL) {
        do { try FileManager.default.removeItem(at: dir) } catch { }
    }

    @Test("RecordStore using InMemory backend")
    func recordStoreInMemory() {
        let store = RecordStore()  // Default in-memory backend
        let key = Data("inmem-key".utf8)
        let record = KademliaRecord(key: key, value: Data("value".utf8))

        let stored = store.put(record)
        #expect(stored == true)

        let retrieved = store.get(key)
        #expect(retrieved != nil)
        #expect(retrieved?.value == Data("value".utf8))
    }

    @Test("RecordStore using file backend")
    func recordStoreFileBackend() throws {
        let dir = try makeTempDir()
        defer { cleanupDir(dir) }

        let fileBackend = try FileRecordStorage(directory: dir)
        let store = RecordStore(backend: fileBackend, defaultTTL: .seconds(3600))

        let key = Data("file-backend-key".utf8)
        let record = KademliaRecord(key: key, value: Data("file-backend-value".utf8))

        let stored = store.put(record)
        #expect(stored == true)

        let retrieved = store.get(key)
        #expect(retrieved != nil)
        #expect(retrieved?.value == Data("file-backend-value".utf8))
    }

    @Test("RecordStore with file backend persists across instances")
    func recordStoreFileBackendPersistence() throws {
        let dir = try makeTempDir()
        defer { cleanupDir(dir) }

        let key = Data("persist-store-key".utf8)
        let value = Data("persist-store-value".utf8)

        // Write via RecordStore
        do {
            let fileBackend = try FileRecordStorage(directory: dir)
            let store = RecordStore(backend: fileBackend, defaultTTL: .seconds(3600))
            let record = KademliaRecord(key: key, value: value)
            _ = store.put(record)
        }

        // Read via a new RecordStore instance
        do {
            let fileBackend = try FileRecordStorage(directory: dir)
            let store = RecordStore(backend: fileBackend, defaultTTL: .seconds(3600))
            let retrieved = store.get(key)
            #expect(retrieved != nil)
            #expect(retrieved?.value == value)
        }
    }

    @Test("ProviderStore using InMemory backend")
    func providerStoreInMemory() {
        let store = ProviderStore()
        let contentKey = Data("inmem-cid".utf8)
        let peerID = KeyPair.generateEd25519().peerID

        let added = store.addProvider(for: contentKey, peerID: peerID)
        #expect(added == true)

        let providers = store.getProviders(for: contentKey)
        #expect(providers.count == 1)
        #expect(providers[0].peerID == peerID)
    }

    @Test("ProviderStore using file backend")
    func providerStoreFileBackend() throws {
        let dir = try makeTempDir()
        defer { cleanupDir(dir) }

        let fileBackend = try FileProviderStorage(directory: dir)
        let store = ProviderStore(backend: fileBackend, defaultTTL: .seconds(3600))

        let contentKey = Data("file-backend-cid".utf8)
        let peerID = KeyPair.generateEd25519().peerID

        let added = store.addProvider(for: contentKey, peerID: peerID)
        #expect(added == true)

        let providers = store.getProviders(for: contentKey)
        #expect(providers.count == 1)
        #expect(providers[0].peerID == peerID)
    }

    @Test("RecordStore cleanup works with file backend")
    func recordStoreCleanupFileBackend() async throws {
        let dir = try makeTempDir()
        defer { cleanupDir(dir) }

        let fileBackend = try FileRecordStorage(directory: dir)
        let store = RecordStore(backend: fileBackend, defaultTTL: .milliseconds(50))

        for i in 0..<3 {
            let record = KademliaRecord(
                key: Data("cleanup-key-\(i)".utf8),
                value: Data("value".utf8)
            )
            _ = store.put(record)
        }

        #expect(store.count == 3)

        try await Task.sleep(for: .milliseconds(100))

        let removed = store.cleanup()
        #expect(removed == 3)
        #expect(store.count == 0)
    }

    @Test("RecordStore contains works with backend")
    func recordStoreContains() throws {
        let dir = try makeTempDir()
        defer { cleanupDir(dir) }

        let fileBackend = try FileRecordStorage(directory: dir)
        let store = RecordStore(backend: fileBackend, defaultTTL: .seconds(3600))

        let key = Data("contains-key".utf8)
        let record = KademliaRecord(key: key, value: Data("value".utf8))

        #expect(store.contains(key) == false)

        _ = store.put(record)
        #expect(store.contains(key) == true)

        _ = store.remove(key)
        #expect(store.contains(key) == false)
    }
}
