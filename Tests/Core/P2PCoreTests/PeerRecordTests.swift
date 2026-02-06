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
