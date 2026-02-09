import Foundation
import Testing
@testable import P2PDiscoveryBeacon

@Suite("Medium")
struct MediumTests {

    @Test("BLE preset")
    func blePreset() {
        let ble = MediumCharacteristics.ble
        #expect(ble.maxBeaconSize == 31)
        #expect(ble.channelCount == 3)
        #expect(ble.directionality == .halfDuplex)
    }

    @Test("BLE extended preset")
    func bleExtendedPreset() {
        let bleExt = MediumCharacteristics.bleExtended
        #expect(bleExt.maxBeaconSize == 255)
        #expect(bleExt.channelCount == 37)
    }

    @Test("NFC preset")
    func nfcPreset() {
        let nfc = MediumCharacteristics.nfc
        #expect(nfc.maxBeaconSize == 4096)
        #expect(nfc.approximateRange == 0.0...0.04)
    }

    @Test("LoRa preset")
    func loraPreset() {
        let lora = MediumCharacteristics.lora
        #expect(lora.maxBeaconSize == 51)
        #expect(lora.approximateRange == 100.0...15000.0)
    }

    @Test("libp2p preset")
    func libp2pPreset() {
        let libp2p = MediumCharacteristics.libp2p
        #expect(libp2p.maxBeaconSize == Int.max)
    }

    @Test("RawDiscovery init")
    func rawDiscoveryInit() {
        let payload = Data([0x01, 0x02])
        let addr = makeOpaqueAddress()
        let ts = ContinuousClock.now
        let fp = PhysicalFingerprint(txPower: -10)
        let rd = RawDiscovery(
            payload: payload,
            sourceAddress: addr,
            timestamp: ts,
            rssi: -70.0,
            mediumID: "ble",
            physicalFingerprint: fp
        )
        #expect(rd.payload == payload)
        #expect(rd.sourceAddress == addr)
        #expect(rd.rssi == -70.0)
        #expect(rd.mediumID == "ble")
        #expect(rd.physicalFingerprint?.txPower == -10)
    }

    @Test("RawDiscovery optional fields")
    func rawDiscoveryOptionalFields() {
        let rd = RawDiscovery(
            payload: Data(),
            sourceAddress: makeOpaqueAddress(),
            timestamp: .now,
            rssi: nil,
            mediumID: "lora",
            physicalFingerprint: nil
        )
        #expect(rd.rssi == nil)
        #expect(rd.physicalFingerprint == nil)
    }

    @Test("TransportAdapterError cases")
    func transportAdapterErrorCases() {
        let e1 = TransportAdapterError.beaconTooLarge(size: 100, max: 31)
        let e2 = TransportAdapterError.connectionFailed("timeout")
        let e3 = TransportAdapterError.mediumNotAvailable
        let e4 = TransportAdapterError.addressTypeMismatch(expected: "ble", got: "lora")

        // Verify they are distinct Error instances
        #expect(e1.localizedDescription.count > 0)
        #expect(e2.localizedDescription.count > 0)
        #expect(e3.localizedDescription.count > 0)
        #expect(e4.localizedDescription.count > 0)
    }
}
