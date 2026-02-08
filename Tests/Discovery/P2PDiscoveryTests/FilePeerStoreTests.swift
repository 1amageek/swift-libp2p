import Testing
import Foundation
@testable import P2PDiscovery
@testable import P2PCore

@Suite("FilePeerStore")
struct FilePeerStoreTests {

    private func makePeerID() -> PeerID {
        KeyPair.generateEd25519().peerID
    }

    private func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("FilePeerStoreTests-\(UUID().uuidString)")
    }

    @Test("add and retrieve addresses", .timeLimit(.minutes(1)))
    func addAndRetrieve() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = FilePeerStore(configuration: .init(directory: dir))
        try await store.start()

        let peer = makePeerID()
        let addr = try Multiaddr("/ip4/127.0.0.1/tcp/4001")

        await store.addAddresses([addr], for: peer, ttl: nil)
        let addresses = await store.addresses(for: peer)

        #expect(addresses.count == 1)
        #expect(addresses.first == addr)

        await store.stop()
    }

    @Test("flush persists to disk", .timeLimit(.minutes(1)))
    func flushPersists() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let peer = makePeerID()
        let addr = try Multiaddr("/ip4/10.0.0.1/tcp/8080")

        // Write data
        let store1 = FilePeerStore(configuration: .init(directory: dir))
        try await store1.start()
        await store1.addAddresses([addr], for: peer, ttl: nil)
        try await store1.flush()
        await store1.stop()

        // Read back in new store
        let store2 = FilePeerStore(configuration: .init(directory: dir))
        try await store2.start()
        let addresses = await store2.addresses(for: peer)
        await store2.stop()

        #expect(addresses.count == 1)
        #expect(addresses.first == addr)
    }

    @Test("remove peer persists", .timeLimit(.minutes(1)))
    func removePeerPersists() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let peer = makePeerID()
        let addr = try Multiaddr("/ip4/10.0.0.1/tcp/8080")

        let store = FilePeerStore(configuration: .init(directory: dir))
        try await store.start()

        await store.addAddresses([addr], for: peer, ttl: nil)
        await store.removePeer(peer)
        try await store.flush()

        let peers = await store.allPeers()
        #expect(peers.isEmpty)

        await store.stop()
    }

    @Test("events pass through from memory store", .timeLimit(.minutes(1)))
    func eventsPassThrough() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = FilePeerStore(configuration: .init(directory: dir))
        try await store.start()

        let peer = makePeerID()
        let addr = try Multiaddr("/ip4/127.0.0.1/tcp/4001")

        let stream = store.events
        await store.addAddresses([addr], for: peer, ttl: nil)

        for await event in stream {
            if case .addressAdded = event {
                break
            }
        }

        await store.stop()
    }

    @Test("start creates directory if missing", .timeLimit(.minutes(1)))
    func createsDirectory() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(!FileManager.default.fileExists(atPath: dir.path))

        let store = FilePeerStore(configuration: .init(directory: dir))
        try await store.start()

        #expect(FileManager.default.fileExists(atPath: dir.path))
        await store.stop()
    }

    @Test("multiple peers persist correctly", .timeLimit(.minutes(1)))
    func multiplePeers() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let peer1 = makePeerID()
        let peer2 = makePeerID()
        let addr1 = try Multiaddr("/ip4/10.0.0.1/tcp/1000")
        let addr2 = try Multiaddr("/ip4/10.0.0.2/tcp/2000")

        let store1 = FilePeerStore(configuration: .init(directory: dir))
        try await store1.start()
        await store1.addAddresses([addr1], for: peer1, ttl: nil)
        await store1.addAddresses([addr2], for: peer2, ttl: nil)
        try await store1.flush()
        await store1.stop()

        let store2 = FilePeerStore(configuration: .init(directory: dir))
        try await store2.start()
        let count = await store2.peerCount()
        #expect(count == 2)
        await store2.stop()
    }

    @Test("remove address persists", .timeLimit(.minutes(1)))
    func removeAddressPersists() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let peer = makePeerID()
        let addr1 = try Multiaddr("/ip4/10.0.0.1/tcp/1000")
        let addr2 = try Multiaddr("/ip4/10.0.0.2/tcp/2000")

        let store1 = FilePeerStore(configuration: .init(directory: dir))
        try await store1.start()
        await store1.addAddresses([addr1, addr2], for: peer, ttl: nil)
        await store1.removeAddress(addr1, for: peer)
        try await store1.flush()
        await store1.stop()

        let store2 = FilePeerStore(configuration: .init(directory: dir))
        try await store2.start()
        let addresses = await store2.addresses(for: peer)
        #expect(addresses.count == 1)
        #expect(addresses.first == addr2)
        await store2.stop()
    }

    @Test("record success and failure persist", .timeLimit(.minutes(1)))
    func recordSuccessFailurePersist() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let peer = makePeerID()
        let addr = try Multiaddr("/ip4/10.0.0.1/tcp/1000")

        let store = FilePeerStore(configuration: .init(directory: dir))
        try await store.start()
        await store.addAddresses([addr], for: peer, ttl: nil)
        await store.recordSuccess(address: addr, for: peer)
        await store.recordFailure(address: addr, for: peer)

        let record = await store.addressRecord(addr, for: peer)
        #expect(record != nil)
        #expect(record?.failureCount == 1)
        #expect(record?.lastSuccess != nil)

        await store.stop()
    }

    @Test("peer count matches stored peers", .timeLimit(.minutes(1)))
    func peerCountMatches() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = FilePeerStore(configuration: .init(directory: dir))
        try await store.start()

        let count0 = await store.peerCount()
        #expect(count0 == 0)

        let peer1 = makePeerID()
        let peer2 = makePeerID()
        let peer3 = makePeerID()
        let addr = try Multiaddr("/ip4/127.0.0.1/tcp/4001")

        await store.addAddresses([addr], for: peer1, ttl: nil)
        await store.addAddresses([addr], for: peer2, ttl: nil)
        await store.addAddresses([addr], for: peer3, ttl: nil)

        let count3 = await store.peerCount()
        #expect(count3 == 3)

        let allPeers = await store.allPeers()
        #expect(allPeers.count == 3)

        await store.stop()
    }

    @Test("failureCount persists across store restarts", .timeLimit(.minutes(1)))
    func failureCountPersistsAcrossRestarts() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let peer = makePeerID()
        let addr = try Multiaddr("/ip4/10.0.0.1/tcp/7000")

        // Write data with failures
        let store1 = FilePeerStore(configuration: .init(directory: dir))
        try await store1.start()
        await store1.addAddresses([addr], for: peer, ttl: nil)
        // Record 3 failures
        await store1.recordFailure(address: addr, for: peer)
        await store1.recordFailure(address: addr, for: peer)
        await store1.recordFailure(address: addr, for: peer)

        // Verify in-memory state
        let record1 = await store1.addressRecord(addr, for: peer)
        #expect(record1?.failureCount == 3)

        try await store1.flush()
        await store1.stop()

        // Load in a new store and verify failureCount is preserved
        let store2 = FilePeerStore(configuration: .init(directory: dir))
        try await store2.start()
        let record2 = await store2.addressRecord(addr, for: peer)
        #expect(record2 != nil)
        #expect(record2?.failureCount == 3)
        await store2.stop()
    }

    @Test("empty store produces no file before flush", .timeLimit(.minutes(1)))
    func emptyStoreNoFile() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = FilePeerStore(configuration: .init(directory: dir))
        try await store.start()

        let filePath = dir.appendingPathComponent("peerstore.json").path
        #expect(!FileManager.default.fileExists(atPath: filePath))

        await store.stop()
    }

    @Test("stop performs final flush", .timeLimit(.minutes(1)))
    func stopPerformsFinalFlush() async throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let peer = makePeerID()
        let addr = try Multiaddr("/ip4/10.0.0.1/tcp/5000")

        let store1 = FilePeerStore(configuration: .init(directory: dir))
        try await store1.start()
        await store1.addAddresses([addr], for: peer, ttl: nil)
        // stop() should flush without explicit flush()
        await store1.stop()

        let store2 = FilePeerStore(configuration: .init(directory: dir))
        try await store2.start()
        let addresses = await store2.addresses(for: peer)
        #expect(addresses.count == 1)
        #expect(addresses.first == addr)
        await store2.stop()
    }
}
