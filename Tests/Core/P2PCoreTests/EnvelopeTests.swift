import Testing
import Foundation
@testable import P2PCore

@Suite("Envelope Tests")
struct EnvelopeTests {

    @Test("Seal and verify PeerRecord roundtrip")
    func sealAndVerify() throws {
        let keyPair = KeyPair.generateEd25519()
        let addr = try Multiaddr("/ip4/127.0.0.1/tcp/4001")
        let record = PeerRecord.make(keyPair: keyPair, seq: 1, addresses: [addr])

        let envelope = try Envelope.seal(record: record, with: keyPair)

        #expect(try envelope.verify(domain: PeerRecord.domain))
        #expect(envelope.peerID == keyPair.peerID)
        #expect(envelope.payloadType == PeerRecord.codec)
    }

    @Test("Seal and open")
    func sealAndOpen() throws {
        let keyPair = KeyPair.generateEd25519()
        let record = PeerRecord.make(keyPair: keyPair, seq: 42, addresses: [])

        let envelope = try Envelope.seal(record: record, with: keyPair)
        let (publicKey, payload) = try envelope.open(domain: PeerRecord.domain)

        #expect(publicKey.peerID == keyPair.peerID)
        #expect(!payload.isEmpty)
    }

    @Test("Extract record from envelope")
    func extractRecord() throws {
        let keyPair = KeyPair.generateEd25519()
        let addr = try Multiaddr("/ip4/10.0.0.1/tcp/8080")
        let original = PeerRecord.make(keyPair: keyPair, seq: 99, addresses: [addr])

        let envelope = try Envelope.seal(record: original, with: keyPair)
        let extracted = try envelope.record(as: PeerRecord.self)

        #expect(extracted.peerID == original.peerID)
        #expect(extracted.seq == 99)
        #expect(extracted.addresses.count == 1)
        #expect(extracted.addresses[0].multiaddr == addr)
    }

    @Test("Verify with wrong domain fails")
    func verifyWrongDomain() throws {
        let keyPair = KeyPair.generateEd25519()
        let record = PeerRecord.make(keyPair: keyPair, seq: 1, addresses: [])

        let envelope = try Envelope.seal(record: record, with: keyPair)

        // Wrong domain should produce invalid signature
        let isValid = try envelope.verify(domain: "wrong-domain")
        #expect(!isValid)
    }

    @Test("Open with wrong domain throws invalidSignature")
    func openWrongDomain() throws {
        let keyPair = KeyPair.generateEd25519()
        let record = PeerRecord.make(keyPair: keyPair, seq: 1, addresses: [])

        let envelope = try Envelope.seal(record: record, with: keyPair)

        #expect(throws: EnvelopeError.self) {
            _ = try envelope.open(domain: "wrong-domain")
        }
    }

    @Test("Verify as wrong record type throws payloadTypeMismatch")
    func verifyWrongRecordType() throws {
        // Create a custom record type with different codec
        struct OtherRecord: SignedRecord {
            static let domain = "other-record"
            static let codec = Data([0xFF, 0xFF])
            func marshal() throws -> Data { Data() }
            static func unmarshal(_ data: Data) throws -> OtherRecord { OtherRecord() }
        }

        let keyPair = KeyPair.generateEd25519()
        let record = PeerRecord.make(keyPair: keyPair, seq: 1, addresses: [])
        let envelope = try Envelope.seal(record: record, with: keyPair)

        #expect(throws: EnvelopeError.self) {
            _ = try envelope.verify(as: OtherRecord.self)
        }
    }

    @Test("Marshal and unmarshal roundtrip")
    func marshalRoundtrip() throws {
        let keyPair = KeyPair.generateEd25519()
        let addr = try Multiaddr("/ip4/192.168.1.1/tcp/9000")
        let record = PeerRecord.make(keyPair: keyPair, seq: 7, addresses: [addr])

        let original = try Envelope.seal(record: record, with: keyPair)
        let data = try original.marshal()
        let restored = try Envelope.unmarshal(data)

        #expect(restored.publicKey == original.publicKey)
        #expect(restored.payloadType == original.payloadType)
        #expect(restored.payload == original.payload)
        #expect(restored.signature == original.signature)
        #expect(restored == original)
    }

    @Test("Unmarshal truncated data throws invalidFormat")
    func unmarshalTruncated() throws {
        let keyPair = KeyPair.generateEd25519()
        let record = PeerRecord.make(keyPair: keyPair, seq: 1, addresses: [])
        let envelope = try Envelope.seal(record: record, with: keyPair)
        let data = try envelope.marshal()

        // Truncate data at various points
        for truncateAt in [1, 5, data.count / 2] {
            let truncated = data.prefix(truncateAt)
            #expect(throws: (any Error).self) {
                _ = try Envelope.unmarshal(Data(truncated))
            }
        }
    }

    @Test("Unmarshal rejects oversized public key field")
    func unmarshalOversizedPublicKey() throws {
        // Construct data with an absurdly large public key length
        var data = Data()
        data.append(contentsOf: Varint.encode(UInt64(5000))) // > 4096
        data.append(Data(repeating: 0, count: 5000))

        #expect(throws: EnvelopeError.self) {
            _ = try Envelope.unmarshal(data)
        }
    }

    @Test("ECDSA key pair seal and verify")
    func ecdsaSealAndVerify() throws {
        let keyPair = KeyPair.generateECDSA()
        let record = PeerRecord.make(keyPair: keyPair, seq: 5, addresses: [])

        let envelope = try Envelope.seal(record: record, with: keyPair)
        #expect(try envelope.verify(domain: PeerRecord.domain))
        #expect(envelope.peerID == keyPair.peerID)
    }

    @Test("Envelope peerID matches signer")
    func peerIDMatchesSigner() throws {
        let keyPair1 = KeyPair.generateEd25519()
        let keyPair2 = KeyPair.generateEd25519()

        let record = PeerRecord.make(keyPair: keyPair1, seq: 1, addresses: [])
        let envelope = try Envelope.seal(record: record, with: keyPair1)

        #expect(envelope.peerID == keyPair1.peerID)
        #expect(envelope.peerID != keyPair2.peerID)
    }
}
