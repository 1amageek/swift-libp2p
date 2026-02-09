import Foundation
import Testing
@testable import P2PDiscoveryBeacon

@Suite("TrustCalculator")
struct TrustCalculatorTests {

    @Test("NFC always one")
    func nfcAlwaysOne() {
        #expect(TrustCalculator.directObservationTrust(rssi: -70, medium: "nfc") == 1.0)
        #expect(TrustCalculator.directObservationTrust(rssi: nil, medium: "nfc") == 1.0)
    }

    @Test("BLE with RSSI")
    func bleWithRSSI() {
        let trust = TrustCalculator.directObservationTrust(rssi: -70, medium: "ble")
        // ((-70) + 90) / 60 = 20/60 = 0.333...
        #expect(abs(trust - (20.0 / 60.0)) < 0.001)
    }

    @Test("BLE without RSSI")
    func bleWithoutRSSI() {
        let trust = TrustCalculator.directObservationTrust(rssi: nil, medium: "ble")
        #expect(trust == 0.5)
    }

    @Test("WiFi Direct with RSSI")
    func wifiDirectWithRSSI() {
        let trust = TrustCalculator.directObservationTrust(rssi: -50, medium: "wifi-direct")
        // ((-50) + 80) / 60 = 30/60 = 0.5, clipped to [0.2, 0.8]
        #expect(trust >= 0.2)
        #expect(trust <= 0.8)
    }

    @Test("LoRa with RSSI")
    func loraWithRSSI() {
        let trust = TrustCalculator.directObservationTrust(rssi: -100, medium: "lora")
        // ((-100) + 120) / 80 = 20/80 = 0.25, clipped to [0.1, 0.5]
        #expect(trust >= 0.1)
        #expect(trust <= 0.5)
    }

    @Test("unknown medium default")
    func unknownMediumDefault() {
        let trust = TrustCalculator.directObservationTrust(rssi: -50, medium: "zigbee")
        #expect(trust == 0.5)
    }

    @Test("clipping bounds")
    func clippingBounds() {
        // Very strong BLE signal
        let bleStrong = TrustCalculator.directObservationTrust(rssi: -10, medium: "ble")
        #expect(bleStrong == 1.0)

        // Very weak BLE signal
        let bleWeak = TrustCalculator.directObservationTrust(rssi: -120, medium: "ble")
        #expect(bleWeak == 0.3)

        // Very strong WiFi
        let wifiStrong = TrustCalculator.directObservationTrust(rssi: -10, medium: "wifi-direct")
        #expect(wifiStrong == 0.8)

        // Very weak LoRa
        let loraWeak = TrustCalculator.directObservationTrust(rssi: -200, medium: "lora")
        #expect(loraWeak == 0.1)
    }
}
