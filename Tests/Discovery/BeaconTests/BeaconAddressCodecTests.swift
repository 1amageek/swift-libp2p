import Foundation
import Testing
@testable import P2PCore
@testable import P2PDiscoveryBeacon

@Suite("BeaconAddressCodec")
struct BeaconAddressCodecTests {

    let codec = BeaconAddressCodec()

    @Test("BLE to Multiaddr")
    func bleToMultiaddr() throws {
        let addr = OpaqueAddress(mediumID: "ble", raw: Data([0x01]))
        let multiaddr = try codec.toMultiaddr(addr)
        #expect(multiaddr.protocols.count == 1)
    }

    @Test("WiFi Direct to Multiaddr")
    func wifiDirectToMultiaddr() throws {
        let addr = OpaqueAddress(mediumID: "wifi-direct", raw: Data([0x02]))
        let multiaddr = try codec.toMultiaddr(addr)
        #expect(multiaddr.protocols.count == 1)
    }

    @Test("LoRa to Multiaddr")
    func loraToMultiaddr() throws {
        let addr = OpaqueAddress(mediumID: "lora", raw: Data([0x03]))
        let multiaddr = try codec.toMultiaddr(addr)
        #expect(multiaddr.protocols.count == 1)
    }

    @Test("NFC to Multiaddr")
    func nfcToMultiaddr() throws {
        let addr = OpaqueAddress(mediumID: "nfc", raw: Data([0x04]))
        let multiaddr = try codec.toMultiaddr(addr)
        #expect(multiaddr.protocols.count == 1)
    }

    @Test("unknown medium throws")
    func unknownMediumThrows() {
        let addr = OpaqueAddress(mediumID: "zigbee", raw: Data([0x05]))
        #expect(throws: BeaconAddressCodecError.self) {
            try codec.toMultiaddr(addr)
        }
    }

    @Test("batch convert skips failures")
    func batchConvertSkipsFailures() {
        let valid = OpaqueAddress(mediumID: "ble", raw: Data([0x01]))
        let invalid = OpaqueAddress(mediumID: "zigbee", raw: Data([0x02]))
        let results = codec.toMultiaddrs([valid, invalid, valid])
        #expect(results.count == 2)
    }

    @Test("Multiaddr to OpaqueAddress")
    func multiaddrToOpaqueAddress() throws {
        let original = OpaqueAddress(mediumID: "ble", raw: Data([0xAB, 0xCD]))
        let multiaddr = try codec.toMultiaddr(original)
        let converted = codec.toOpaqueAddress(multiaddr)
        #expect(converted != nil)
        #expect(converted?.mediumID == "ble")
        #expect(converted?.raw == original.raw)
    }

    @Test("roundtrip conversion")
    func roundtripConversion() throws {
        let original = OpaqueAddress(mediumID: "lora", raw: Data([0x01, 0x02, 0x03]))
        let multiaddr = try codec.toMultiaddr(original)
        let back = codec.toOpaqueAddress(multiaddr)
        #expect(back == original)
    }
}
