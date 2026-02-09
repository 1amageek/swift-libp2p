import Foundation
import Testing
@testable import P2PCore
@testable import P2PDiscoveryBeacon

@Suite("Tier3Beacon")
struct Tier3BeaconTests {

    @Test("encode/decode roundtrip")
    func encodeDecodeRoundtrip() throws {
        let kp = makeKeyPair()
        let envelope = try makeEnvelope(keyPair: kp)
        let beacon = Tier3Beacon(peerID: kp.peerID, nonce: 0xDEADBEEF, envelope: envelope)
        let encoded = try beacon.encode()
        let decoded = Tier3Beacon.decode(from: encoded)
        #expect(decoded != nil)
        #expect(decoded?.peerIDBytes == kp.peerID.bytes)
        #expect(decoded?.nonce == 0xDEADBEEF)
    }

    @Test("variable length PeerID")
    func variableLengthPeerID() throws {
        let kp1 = makeKeyPair()
        let kp2 = makeKeyPair()
        let env1 = try makeEnvelope(keyPair: kp1)
        let env2 = try makeEnvelope(keyPair: kp2)
        let b1 = Tier3Beacon(peerID: kp1.peerID, nonce: 1, envelope: env1)
        let b2 = Tier3Beacon(peerID: kp2.peerID, nonce: 2, envelope: env2)
        let d1 = Tier3Beacon.decode(from: try b1.encode())
        let d2 = Tier3Beacon.decode(from: try b2.encode())
        #expect(d1?.peerIDBytes == kp1.peerID.bytes)
        #expect(d2?.peerIDBytes == kp2.peerID.bytes)
    }

    @Test("envelope preserved")
    func envelopePreserved() throws {
        let kp = makeKeyPair()
        let envelope = try makeEnvelope(keyPair: kp, seq: 42)
        let beacon = Tier3Beacon(peerID: kp.peerID, nonce: 1, envelope: envelope)
        let decoded = Tier3Beacon.decode(from: try beacon.encode())
        let record = try decoded?.envelope.record(as: BeaconPeerRecord.self)
        #expect(record?.seq == 42)
    }

    @Test("minHeaderSize")
    func minHeaderSize() {
        #expect(Tier3Beacon.minHeaderSize == 9)
    }

    @Test("init from PeerID convenience")
    func initFromPeerIDConvenience() throws {
        let kp = makeKeyPair()
        let envelope = try makeEnvelope(keyPair: kp)
        let b1 = Tier3Beacon(peerID: kp.peerID, nonce: 1, envelope: envelope)
        let b2 = Tier3Beacon(peerIDBytes: kp.peerID.bytes, nonce: 1, envelope: envelope)
        #expect(b1.peerIDBytes == b2.peerIDBytes)
        #expect(b1.nonce == b2.nonce)
    }

    @Test("decode invalid tag")
    func decodeInvalidTag() {
        var data = Data(repeating: 0, count: 20)
        data[0] = 0xD0 // Tier1 tag
        #expect(Tier3Beacon.decode(from: data) == nil)
    }

    @Test("decode truncated data")
    func decodeTruncatedData() {
        var data = Data(count: 8)
        data[0] = 0xD2
        #expect(Tier3Beacon.decode(from: data) == nil)
    }

    @Test("decode invalid envelope")
    func decodeInvalidEnvelope() {
        // Build minimal valid header but garbage envelope
        var data = Data()
        data.append(0xD2) // tag
        let peerIDBytes = Data(repeating: 0x01, count: 4)
        withUnsafeBytes(of: UInt16(peerIDBytes.count).bigEndian) { data.append(contentsOf: $0) }
        data.append(peerIDBytes)
        withUnsafeBytes(of: UInt32(1).bigEndian) { data.append(contentsOf: $0) } // nonce
        let garbage = Data(repeating: 0xFF, count: 10)
        withUnsafeBytes(of: UInt16(garbage.count).bigEndian) { data.append(contentsOf: $0) }
        data.append(garbage)
        #expect(Tier3Beacon.decode(from: data) == nil)
    }
}
