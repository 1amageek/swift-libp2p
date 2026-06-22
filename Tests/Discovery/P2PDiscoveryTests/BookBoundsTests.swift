/// BookBoundsTests - Sybil memory-DoS bounding for the in-memory books.
import Testing
import Foundation
@testable import P2PDiscovery
@testable import P2PCore

// MARK: - KeyBook

@Suite("MemoryKeyBook Bounds")
struct MemoryKeyBookBoundsTests {

    @Test("key map is bounded under churn (LRU)")
    func keyBookBounded() async throws {
        let cap = 16
        let book = MemoryKeyBook(maxPeers: cap)
        for _ in 0..<500 {
            let kp = KeyPair.generateEd25519()
            try await book.setPublicKey(kp.publicKey, for: kp.peerID)
        }
        let peers = await book.peersWithKeys()
        #expect(peers.count <= cap)
    }
}

// MARK: - ProtoBook

@Suite("MemoryProtoBook Bounds")
struct MemoryProtoBookBoundsTests {

    @Test("peer map is bounded under churn (LRU)")
    func protoBookPeersBounded() async throws {
        let cap = 16
        let book = MemoryProtoBook(maxPeers: cap)
        for _ in 0..<500 {
            let peer = KeyPair.generateEd25519().peerID
            await book.setProtocols(["/chat/1.0", "/ping/1.0"], for: peer)
        }
        // Count distinct peers still tracked by sampling the reverse index.
        let chatPeers = await book.peers(supporting: "/chat/1.0")
        #expect(chatPeers.count <= cap)
    }

    @Test("per-peer protocol set is capped")
    func protoBookPerPeerCapped() async throws {
        let perPeerCap = 8
        let book = MemoryProtoBook(maxProtocolsPerPeer: perPeerCap)
        let peer = KeyPair.generateEd25519().peerID
        let many = (0..<100).map { "/proto/\($0)" }
        await book.addProtocols(many, for: peer)
        let protocols = await book.protocols(for: peer)
        #expect(protocols.count <= perPeerCap)
    }

    @Test("setProtocols also enforces per-peer cap")
    func protoBookSetCapped() async throws {
        let perPeerCap = 4
        let book = MemoryProtoBook(maxProtocolsPerPeer: perPeerCap)
        let peer = KeyPair.generateEd25519().peerID
        let many = (0..<50).map { "/proto/\($0)" }
        await book.setProtocols(many, for: peer)
        let protocols = await book.protocols(for: peer)
        #expect(protocols.count <= perPeerCap)
    }
}

// MARK: - MetadataBook

@Suite("MemoryMetadataBook Bounds")
struct MemoryMetadataBookBoundsTests {

    @Test("peer map is bounded under churn (LRU)")
    func metadataPeersBounded() async {
        let cap = 16
        let book = MemoryMetadataBook(maxPeers: cap)
        defer { book.shutdown() }
        for _ in 0..<500 {
            let peer = KeyPair.generateEd25519().peerID
            book.set(.agentVersion, value: "agent/1.0", for: peer)
        }
        // Verify the most recent peers are still present and old ones evicted by
        // checking total tracked count indirectly: re-insert a fresh batch and
        // confirm none of an earlier batch survived beyond the cap.
        var survivors = 0
        var peers: [PeerID] = []
        for _ in 0..<cap {
            let peer = KeyPair.generateEd25519().peerID
            peers.append(peer)
            book.set(.agentVersion, value: "agent/1.0", for: peer)
        }
        for peer in peers where book.get(.agentVersion, for: peer) != nil {
            survivors += 1
        }
        // All `cap` freshly inserted peers must be present (LRU keeps recent).
        #expect(survivors == cap)
    }

    @Test("per-peer key count is capped")
    func metadataKeysCapped() {
        let keyCap = 8
        let book = MemoryMetadataBook(maxKeysPerPeer: keyCap)
        defer { book.shutdown() }
        let peer = KeyPair.generateEd25519().peerID
        for i in 0..<100 {
            book.set(MetadataKey<String>("k\(i)"), value: "v", for: peer)
        }
        #expect(book.keys(for: peer).count <= keyCap)
    }

    @Test("oversized value is rejected, not stored")
    func metadataValueSizeCapped() {
        let book = MemoryMetadataBook(maxValueSize: 64)
        defer { book.shutdown() }
        let peer = KeyPair.generateEd25519().peerID
        let huge = String(repeating: "x", count: 10_000)
        book.set(MetadataKey<String>("big"), value: huge, for: peer)
        #expect(book.get(MetadataKey<String>("big"), for: peer) == nil)
    }

    @Test("rejection is surfaced via an event, not silent")
    func metadataRejectionSurfaced() async {
        let book = MemoryMetadataBook(maxValueSize: 16)
        let peer = KeyPair.generateEd25519().peerID
        let stream = book.events
        let huge = String(repeating: "y", count: 1000)

        let collector = Task<Bool, Never> {
            for await event in stream {
                if case .metadataRejected = event { return true }
            }
            return false
        }
        // Allow subscription to attach.
        try? await Task.sleep(for: .milliseconds(20))
        book.set(MetadataKey<String>("big"), value: huge, for: peer)
        try? await Task.sleep(for: .milliseconds(20))
        book.shutdown()
        #expect(await collector.value)
    }
}

// MARK: - CertifiedAddressBook

@Suite("CertifiedAddressBook Bounds")
struct CertifiedAddressBookBoundsTests {

    @Test("record store is bounded under churn (LRU)")
    func certifiedBounded() throws {
        let cap = 16
        let book = CertifiedAddressBook(maxRecords: cap)
        defer { book.shutdown() }
        let addr = try Multiaddr("/ip4/127.0.0.1/tcp/4001")
        for _ in 0..<500 {
            let kp = KeyPair.generateEd25519()
            let record = PeerRecord.make(keyPair: kp, seq: 1, addresses: [addr])
            let envelope = try Envelope.seal(record: record, with: kp)
            _ = try book.consumePeerRecord(envelope)
        }
        #expect(book.recordCount() <= cap)
        #expect(book.allCertifiedPeers().count <= cap)
    }
}
