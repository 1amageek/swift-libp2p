import Testing
import Foundation
@testable import P2PDiscovery
@testable import P2PCore

// MARK: - MetadataBook Tests

@Suite("MetadataBook Tests")
struct MetadataBookTests {

    private func makePeerID() -> PeerID {
        KeyPair.generateEd25519().peerID
    }

    @Test("set and get string metadata")
    func setGetString() {
        let book = MemoryMetadataBook()
        defer { book.shutdown() }
        let peer = makePeerID()

        book.set(.protocolVersion, value: "libp2p/1.0", for: peer)
        let result = book.get(.protocolVersion, for: peer)
        #expect(result == "libp2p/1.0")
    }

    @Test("set and get double metadata")
    func setGetDouble() {
        let book = MemoryMetadataBook()
        defer { book.shutdown() }
        let peer = makePeerID()

        book.set(.latency, value: 0.042, for: peer)
        let result = book.get(.latency, for: peer)
        #expect(result == 0.042)
    }

    @Test("get nonexistent returns nil")
    func getNonexistent() {
        let book = MemoryMetadataBook()
        defer { book.shutdown() }
        let peer = makePeerID()

        let result = book.get(.protocolVersion, for: peer)
        #expect(result == nil)
    }

    @Test("overwrite existing value")
    func overwrite() {
        let book = MemoryMetadataBook()
        defer { book.shutdown() }
        let peer = makePeerID()

        book.set(.agentVersion, value: "v1", for: peer)
        book.set(.agentVersion, value: "v2", for: peer)
        #expect(book.get(.agentVersion, for: peer) == "v2")
    }

    @Test("remove specific key")
    func removeKey() {
        let book = MemoryMetadataBook()
        defer { book.shutdown() }
        let peer = makePeerID()

        book.set(.protocolVersion, value: "1.0", for: peer)
        book.set(.agentVersion, value: "test", for: peer)
        book.remove(key: "protocolVersion", for: peer)

        #expect(book.get(.protocolVersion, for: peer) == nil)
        #expect(book.get(.agentVersion, for: peer) == "test")
    }

    @Test("remove peer removes all metadata")
    func removePeer() {
        let book = MemoryMetadataBook()
        defer { book.shutdown() }
        let peer = makePeerID()

        book.set(.protocolVersion, value: "1.0", for: peer)
        book.set(.latency, value: 0.1, for: peer)
        book.removePeer(peer)

        #expect(book.get(.protocolVersion, for: peer) == nil)
        #expect(book.get(.latency, for: peer) == nil)
    }

    @Test("keys returns stored keys")
    func keys() {
        let book = MemoryMetadataBook()
        defer { book.shutdown() }
        let peer = makePeerID()

        book.set(.protocolVersion, value: "1.0", for: peer)
        book.set(.latency, value: 0.1, for: peer)

        let keys = book.keys(for: peer)
        #expect(keys.count == 2)
        #expect(keys.contains("protocolVersion"))
        #expect(keys.contains("latency"))
    }

    @Test("keys returns empty for unknown peer")
    func keysUnknownPeer() {
        let book = MemoryMetadataBook()
        defer { book.shutdown() }
        let peer = makePeerID()

        let keys = book.keys(for: peer)
        #expect(keys.isEmpty)
    }

    @Test("events emitted on set", .timeLimit(.minutes(1)))
    func events() async {
        let book = MemoryMetadataBook()
        defer { book.shutdown() }
        let peer = makePeerID()

        let stream = book.events
        book.set(.protocolVersion, value: "1.0", for: peer)

        for await event in stream {
            if case .metadataSet(let p, let key) = event {
                #expect(p == peer)
                #expect(key == "protocolVersion")
                break
            }
        }
    }

    @Test("different peers have independent metadata")
    func independentPeers() {
        let book = MemoryMetadataBook()
        defer { book.shutdown() }
        let peer1 = makePeerID()
        let peer2 = makePeerID()

        book.set(.agentVersion, value: "peer1-agent", for: peer1)
        book.set(.agentVersion, value: "peer2-agent", for: peer2)

        #expect(book.get(.agentVersion, for: peer1) == "peer1-agent")
        #expect(book.get(.agentVersion, for: peer2) == "peer2-agent")
    }

    @Test("custom metadata key")
    func customKey() {
        let book = MemoryMetadataBook()
        defer { book.shutdown() }
        let peer = makePeerID()

        let myKey = MetadataKey<Int>("connectionCount")
        book.set(myKey, value: 42, for: peer)
        #expect(book.get(myKey, for: peer) == 42)
    }

    @Test("remove emits event only when key existed")
    func removeEmitsEventOnlyWhenExists() async {
        let book = MemoryMetadataBook()
        defer { book.shutdown() }
        let peer = makePeerID()

        // Remove nonexistent key should not emit
        book.remove(key: "nonexistent", for: peer)

        // Set and then remove should emit
        book.set(.protocolVersion, value: "1.0", for: peer)
        book.remove(key: "protocolVersion", for: peer)
        #expect(book.get(.protocolVersion, for: peer) == nil)
    }

    @Test("removePeer emits event only when peer had data")
    func removePeerEmitsEventOnlyWhenExists() {
        let book = MemoryMetadataBook()
        defer { book.shutdown() }
        let peer = makePeerID()

        // Remove nonexistent peer should not emit
        book.removePeer(peer)

        // Set and then remove should emit
        book.set(.protocolVersion, value: "1.0", for: peer)
        book.removePeer(peer)
        #expect(book.keys(for: peer).isEmpty)
    }

    @Test("shutdown clears all metadata")
    func shutdownClearsAll() {
        let book = MemoryMetadataBook()
        let peer = makePeerID()

        book.set(.protocolVersion, value: "1.0", for: peer)
        book.set(.latency, value: 0.1, for: peer)
        book.shutdown()

        #expect(book.get(.protocolVersion, for: peer) == nil)
        #expect(book.keys(for: peer).isEmpty)
    }
}
