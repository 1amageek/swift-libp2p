/// MessageIDTests - Tests for GossipSub MessageID functionality
import Testing
import Foundation
import Crypto
@testable import P2PGossipSub
@testable import P2PCore

@Suite("MessageID Tests")
struct MessageIDTests {

    // MARK: - Basic Creation Tests

    @Test("Create MessageID from raw bytes")
    func createFromBytes() {
        let bytes = Data([0x01, 0x02, 0x03, 0x04, 0x05])
        let messageID = MessageID(bytes: bytes)

        #expect(messageID.bytes == bytes)
    }

    @Test("Create MessageID from hex string")
    func createFromHex() {
        let hex = "0102030405"
        let messageID = MessageID(hex: hex)

        #expect(messageID != nil)
        #expect(messageID?.bytes == Data([0x01, 0x02, 0x03, 0x04, 0x05]))
    }

    @Test("Invalid hex string returns nil")
    func invalidHexReturnsNil() {
        let messageID = MessageID(hex: "not-valid-hex")

        #expect(messageID == nil)
    }

    // MARK: - Compute from Source and Sequence Number

    @Test("Compute MessageID from source and sequence number")
    func computeFromSourceAndSeqNo() {
        let keyPair = KeyPair.generateEd25519()
        let peerID = keyPair.peerID
        let seqNo = Data([0x00, 0x00, 0x00, 0x01])

        let messageID = MessageID.compute(source: peerID, sequenceNumber: seqNo)

        // Should contain peer ID bytes + sequence number
        #expect(messageID.bytes.count == peerID.bytes.count + seqNo.count)
        #expect(messageID.bytes.prefix(peerID.bytes.count) == peerID.bytes)
        #expect(messageID.bytes.suffix(seqNo.count) == seqNo)
    }

    @Test("Compute MessageID without source")
    func computeWithoutSource() {
        let seqNo = Data([0x00, 0x00, 0x00, 0x01])

        let messageID = MessageID.compute(source: nil, sequenceNumber: seqNo)

        #expect(messageID.bytes == seqNo)
    }

    // MARK: - SHA-256 Hash Tests

    @Test("ComputeFromHash uses SHA-256")
    func computeFromHashUsesSHA256() {
        let data = Data("test message content".utf8)
        let messageID = MessageID.computeFromHash(data)

        // Manually compute SHA-256 and take first 20 bytes
        let expectedHash = SHA256.hash(data: data)
        let expectedBytes = Data(expectedHash.prefix(20))

        #expect(messageID.bytes == expectedBytes)
        #expect(messageID.bytes.count == 20)
    }

    @Test("ComputeFromHash is deterministic")
    func computeFromHashDeterministic() {
        let data = Data("same content".utf8)

        let messageID1 = MessageID.computeFromHash(data)
        let messageID2 = MessageID.computeFromHash(data)

        #expect(messageID1 == messageID2)
    }

    @Test("ComputeFromHash produces different IDs for different content")
    func computeFromHashDifferentContent() {
        let data1 = Data("message 1".utf8)
        let data2 = Data("message 2".utf8)

        let messageID1 = MessageID.computeFromHash(data1)
        let messageID2 = MessageID.computeFromHash(data2)

        #expect(messageID1 != messageID2)
    }

    @Test("ComputeFromHash produces consistent IDs across computations")
    func computeFromHashConsistentAcrossNodes() {
        // This test verifies that SHA-256 produces consistent IDs
        // that would be the same across different nodes/processes
        let data = Data("shared message".utf8)

        // Compute multiple times
        var ids: Set<MessageID> = []
        for _ in 0..<100 {
            ids.insert(MessageID.computeFromHash(data))
        }

        // All should be identical
        #expect(ids.count == 1)
    }

    // MARK: - Hashable and Equatable

    @Test("MessageID is hashable")
    func messageIDHashable() {
        let id1 = MessageID(bytes: Data([0x01, 0x02, 0x03]))
        let id2 = MessageID(bytes: Data([0x01, 0x02, 0x03]))
        let id3 = MessageID(bytes: Data([0x04, 0x05, 0x06]))

        var set: Set<MessageID> = []
        set.insert(id1)
        set.insert(id2)
        set.insert(id3)

        #expect(set.count == 2)  // id1 and id2 are equal
    }

    @Test("MessageID equality")
    func messageIDEquality() {
        let id1 = MessageID(bytes: Data([0x01, 0x02, 0x03]))
        let id2 = MessageID(bytes: Data([0x01, 0x02, 0x03]))
        let id3 = MessageID(bytes: Data([0x04, 0x05, 0x06]))

        #expect(id1 == id2)
        #expect(id1 != id3)
    }

    // MARK: - Description

    @Test("MessageID description is hex encoded")
    func messageIDDescription() {
        let bytes = Data([0x01, 0x02, 0x03, 0xAB, 0xCD])
        let messageID = MessageID(bytes: bytes)

        #expect(messageID.description == "010203abcd")
    }

    // MARK: - Codable

    @Test("MessageID encodes and decodes")
    func messageIDCodable() throws {
        let original = MessageID(bytes: Data([0x01, 0x02, 0x03, 0x04, 0x05]))

        let encoder = JSONEncoder()
        let encoded = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(MessageID.self, from: encoded)

        #expect(decoded == original)
    }
}
