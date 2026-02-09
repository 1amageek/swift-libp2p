import Foundation
import Testing
@testable import P2PDiscoveryWiFiBeacon

@Suite("WiFiBeaconFrame")
struct WiFiBeaconFrameTests {

    @Test("encode/decode roundtrip")
    func encodeDecodeRoundtrip() {
        let payload = Data([0xD0, 0x12, 0x34, 0xAA, 0xBB, 0xCC, 0xDD, 0x00, 0x01, 0x02])
        let frame = WiFiBeaconFrame(payload: payload)
        let encoded = frame.encode()
        let decoded = WiFiBeaconFrame.decode(from: encoded)
        #expect(decoded != nil)
        #expect(decoded?.payload == payload)
    }

    @Test("empty payload roundtrip")
    func emptyPayload() {
        let frame = WiFiBeaconFrame(payload: Data())
        let encoded = frame.encode()
        #expect(encoded.count == WiFiBeaconFrame.headerSize)
        let decoded = WiFiBeaconFrame.decode(from: encoded)
        #expect(decoded != nil)
        #expect(decoded?.payload == Data())
    }

    @Test("magic bytes are correct")
    func magicBytesCorrect() {
        let frame = WiFiBeaconFrame(payload: Data([0x01]))
        let encoded = frame.encode()
        #expect(encoded[0] == 0x50)  // 'P'
        #expect(encoded[1] == 0x32)  // '2'
    }

    @Test("version byte")
    func versionByte() {
        let frame = WiFiBeaconFrame(payload: Data([0x01]))
        let encoded = frame.encode()
        #expect(encoded[2] == 0x01)
    }

    @Test("reject wrong magic")
    func rejectWrongMagic() {
        var data = WiFiBeaconFrame(payload: Data([0x01])).encode()
        data[0] = 0xFF  // corrupt magic
        let decoded = WiFiBeaconFrame.decode(from: data)
        #expect(decoded == nil)
    }

    @Test("reject truncated header")
    func rejectTruncatedHeader() {
        let data = Data([0x50, 0x32, 0x01, 0x00, 0x00, 0x01, 0x00])  // 7 bytes < headerSize
        let decoded = WiFiBeaconFrame.decode(from: data)
        #expect(decoded == nil)
    }

    @Test("reject payload length mismatch")
    func rejectPayloadLengthMismatch() {
        // Header claims 10 bytes payload but only 2 bytes present
        var data = Data([0x50, 0x32, 0x01, 0x00, 0x00, 0x0A, 0x00, 0x00])
        data.append(Data([0x01, 0x02]))  // only 2 bytes, header says 10
        let decoded = WiFiBeaconFrame.decode(from: data)
        #expect(decoded == nil)
    }
}
