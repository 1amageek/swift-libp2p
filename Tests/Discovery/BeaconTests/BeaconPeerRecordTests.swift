import Foundation
import Testing
@testable import P2PCore
@testable import P2PDiscoveryBeacon

@Suite("BeaconPeerRecord")
struct BeaconPeerRecordTests {

    @Test("domain constant")
    func domainConstant() {
        #expect(BeaconPeerRecord.domain == "p2p-beacon-peer-record")
    }

    @Test("codec constant")
    func codecConstant() {
        #expect(BeaconPeerRecord.codec == Data([0x03, 0xB0]))
    }

    @Test("marshal/unmarshal roundtrip with empty addresses")
    func marshalUnmarshalRoundtrip() throws {
        let kp = makeKeyPair()
        let record = BeaconPeerRecord(peerID: kp.peerID, seq: 1, opaqueAddresses: [])
        let data = try record.marshal()
        let decoded = try BeaconPeerRecord.unmarshal(data)
        #expect(decoded == record)
    }

    @Test("marshal with multiple addresses")
    func marshalWithMultipleAddresses() throws {
        let kp = makeKeyPair()
        let addrs = [
            OpaqueAddress(mediumID: "ble", raw: Data([0x01, 0x02])),
            OpaqueAddress(mediumID: "lora", raw: Data([0x03, 0x04, 0x05]))
        ]
        let record = BeaconPeerRecord(peerID: kp.peerID, seq: 5, opaqueAddresses: addrs)
        let data = try record.marshal()
        let decoded = try BeaconPeerRecord.unmarshal(data)
        #expect(decoded.peerID == kp.peerID)
        #expect(decoded.seq == 5)
        #expect(decoded.opaqueAddresses.count == 2)
        #expect(decoded.opaqueAddresses[0].mediumID == "ble")
        #expect(decoded.opaqueAddresses[1].mediumID == "lora")
    }

    @Test("marshal with large seq")
    func marshalWithLargeSeq() throws {
        let kp = makeKeyPair()
        let record = BeaconPeerRecord(peerID: kp.peerID, seq: UInt64.max, opaqueAddresses: [])
        let data = try record.marshal()
        let decoded = try BeaconPeerRecord.unmarshal(data)
        #expect(decoded.seq == UInt64.max)
    }

    @Test("unmarshal truncated data throws")
    func unmarshalTruncatedDataThrows() {
        let data = Data([0x00, 0x01])
        #expect(throws: BeaconPeerRecordError.self) {
            try BeaconPeerRecord.unmarshal(data)
        }
    }

    @Test("unmarshal empty data throws")
    func unmarshalEmptyDataThrows() {
        #expect(throws: BeaconPeerRecordError.self) {
            try BeaconPeerRecord.unmarshal(Data())
        }
    }

    @Test("Equatable conformance")
    func equatableConformance() throws {
        let kp = makeKeyPair()
        let a = BeaconPeerRecord(peerID: kp.peerID, seq: 1, opaqueAddresses: [])
        let b = BeaconPeerRecord(peerID: kp.peerID, seq: 1, opaqueAddresses: [])
        let c = BeaconPeerRecord(peerID: kp.peerID, seq: 2, opaqueAddresses: [])
        #expect(a == b)
        #expect(a != c)
    }

    @Test("envelope seal and extract")
    func envelopeSealAndExtract() throws {
        let kp = makeKeyPair()
        let record = BeaconPeerRecord(peerID: kp.peerID, seq: 10, opaqueAddresses: [])
        let envelope = try Envelope.seal(record: record, with: kp)
        let extracted = try envelope.record(as: BeaconPeerRecord.self)
        #expect(extracted == record)
    }

    @Test("envelope verify with correct domain")
    func envelopeVerifyWithCorrectDomain() throws {
        let kp = makeKeyPair()
        let record = BeaconPeerRecord(peerID: kp.peerID, seq: 1, opaqueAddresses: [])
        let envelope = try Envelope.seal(record: record, with: kp)
        let result = try envelope.open(domain: BeaconPeerRecord.domain)
        #expect(result.publicKey.rawBytes == kp.publicKey.rawBytes)
    }
}
