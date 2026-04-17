import Testing
import Foundation
@testable import P2PCore

@Suite("PeerRecord Tests")
struct PeerRecordTests {

    @Test("Domain and codec constants")
    func domainAndCodec() {
        #expect(PeerRecord.domain == "libp2p-peer-record")
        #expect(PeerRecord.codec == Data([0x03, 0x01]))
    }

    @Test("Make with key pair")
    func makeWithKeyPair() throws {
        let keyPair = KeyPair.generateEd25519()
        let addr = try Multiaddr("/ip4/127.0.0.1/tcp/4001")
        let record = PeerRecord.make(keyPair: keyPair, seq: 42, addresses: [addr])

        #expect(record.peerID == keyPair.peerID)
        #expect(record.seq == 42)
        #expect(record.addresses.count == 1)
        #expect(record.addresses[0].multiaddr == addr)
    }

    @Test("Marshal and unmarshal roundtrip with no addresses")
    func marshalRoundtripEmpty() throws {
        let keyPair = KeyPair.generateEd25519()
        let original = PeerRecord.make(keyPair: keyPair, seq: 0, addresses: [])

        let data = try original.marshal()
        let restored = try PeerRecord.unmarshal(data)

        #expect(restored.peerID == original.peerID)
        #expect(restored.seq == 0)
        #expect(restored.addresses.isEmpty)
    }

    @Test("Marshal and unmarshal roundtrip with addresses")
    func marshalRoundtripWithAddresses() throws {
        let keyPair = KeyPair.generateEd25519()
        let addrs = [
            try Multiaddr("/ip4/127.0.0.1/tcp/4001"),
            try Multiaddr("/ip4/10.0.0.1/tcp/8080"),
            try Multiaddr("/ip6/::1/tcp/9000"),
        ]
        let original = PeerRecord.make(keyPair: keyPair, seq: 100, addresses: addrs)

        let data = try original.marshal()
        let restored = try PeerRecord.unmarshal(data)

        #expect(restored.peerID == original.peerID)
        #expect(restored.seq == 100)
        #expect(restored.addresses.count == 3)
        for (i, addr) in addrs.enumerated() {
            #expect(restored.addresses[i].multiaddr == addr)
        }
    }

    @Test("Marshal uses libp2p protobuf wire format")
    func marshalUsesProtobufWireFormat() throws {
        let keyPair = KeyPair.generateEd25519()
        let addr = try Multiaddr("/ip4/127.0.0.1/tcp/4001")
        let record = PeerRecord.make(keyPair: keyPair, seq: 42, addresses: [addr])

        let encoded = try record.marshal()

        var expected = Data()
        let peerIDBytes = keyPair.peerID.bytes
        expected.append(0x0A)
        expected.append(Varint.encode(UInt64(peerIDBytes.count)))
        expected.append(peerIDBytes)
        expected.append(0x10)
        expected.append(Varint.encode(42))

        let addrBytes = addr.bytes
        var nested = Data()
        nested.append(0x0A)
        nested.append(Varint.encode(UInt64(addrBytes.count)))
        nested.append(addrBytes)

        expected.append(0x1A)
        expected.append(Varint.encode(UInt64(nested.count)))
        expected.append(nested)

        #expect(encoded == expected)
    }

    @Test("Sequence number preserved")
    func sequenceNumber() throws {
        let keyPair = KeyPair.generateEd25519()
        let record = PeerRecord.make(keyPair: keyPair, seq: UInt64.max, addresses: [])

        let data = try record.marshal()
        let restored = try PeerRecord.unmarshal(data)

        #expect(restored.seq == UInt64.max)
    }

    @Test("Unmarshal truncated data throws")
    func unmarshalTruncated() throws {
        let keyPair = KeyPair.generateEd25519()
        let record = PeerRecord.make(
            keyPair: keyPair,
            seq: 1,
            addresses: [try Multiaddr("/ip4/127.0.0.1/tcp/4001")]
        )
        let data = try record.marshal()

        #expect(throws: (any Error).self) {
            _ = try PeerRecord.unmarshal(Data(data.prefix(3)))
        }
    }

    @Test("Unmarshal ignores unknown protobuf fields")
    func unmarshalIgnoresUnknownFields() throws {
        let keyPair = KeyPair.generateEd25519()
        let addr = try Multiaddr("/ip4/127.0.0.1/tcp/4001")
        let record = PeerRecord.make(keyPair: keyPair, seq: 7, addresses: [addr])

        var data = try record.marshal()
        data.append(0x22) // field 4, wire type 2
        data.append(0x03)
        data.append(Data([0x01, 0x02, 0x03]))
        data.append(0x28) // field 5, wire type 0
        data.append(0x01)

        let restored = try PeerRecord.unmarshal(data)
        #expect(restored == record)
    }

    @Test("Equatable conformance")
    func equatable() throws {
        let keyPair = KeyPair.generateEd25519()
        let addr = try Multiaddr("/ip4/127.0.0.1/tcp/4001")
        let record1 = PeerRecord.make(keyPair: keyPair, seq: 1, addresses: [addr])
        let record2 = PeerRecord.make(keyPair: keyPair, seq: 1, addresses: [addr])

        #expect(record1 == record2)
    }

    @Test("AddressInfo marshal and unmarshal roundtrip")
    func addressInfoRoundtrip() throws {
        let addr = try Multiaddr("/ip4/192.168.1.1/tcp/9000")
        let info = AddressInfo(multiaddr: addr)

        let data = try info.marshal()
        let restored = try AddressInfo.unmarshal(data)

        #expect(restored.multiaddr == addr)
    }

    @Test("Integration with Envelope seal and extract")
    func envelopeIntegration() throws {
        let keyPair = KeyPair.generateEd25519()
        let addr = try Multiaddr("/ip4/10.0.0.1/tcp/8080")
        let original = PeerRecord.make(keyPair: keyPair, seq: 55, addresses: [addr])

        let envelope = try Envelope.seal(record: original, with: keyPair)
        let extracted = try envelope.record(as: PeerRecord.self)

        #expect(extracted.peerID == original.peerID)
        #expect(extracted.seq == 55)
        #expect(extracted.addresses.count == 1)
    }
}
