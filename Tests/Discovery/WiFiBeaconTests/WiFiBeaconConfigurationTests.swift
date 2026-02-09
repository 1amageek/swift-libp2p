import Foundation
import Testing
@testable import P2PDiscoveryWiFiBeacon

@Suite("WiFiBeaconConfiguration")
struct WiFiBeaconConfigurationTests {

    @Test("default values")
    func defaultValues() {
        let config = WiFiBeaconConfiguration()
        #expect(config.multicastGroup == "239.2.0.1")
        #expect(config.port == 9876)
        #expect(config.networkInterface == nil)
        #expect(config.transmitInterval == .seconds(5))
        #expect(config.loopback == false)
    }

    @Test("custom values")
    func customValues() {
        let config = WiFiBeaconConfiguration(
            multicastGroup: "239.1.2.3",
            port: 12345,
            networkInterface: "en0",
            transmitInterval: .seconds(10),
            loopback: true
        )
        #expect(config.multicastGroup == "239.1.2.3")
        #expect(config.port == 12345)
        #expect(config.networkInterface == "en0")
        #expect(config.transmitInterval == .seconds(10))
        #expect(config.loopback == true)
    }

    @Test("default transmit interval is 5 seconds")
    func defaultTransmitInterval() {
        let config = WiFiBeaconConfiguration()
        #expect(config.transmitInterval == .seconds(5))
    }

    @Test("default loopback is false")
    func defaultLoopbackIsFalse() {
        let config = WiFiBeaconConfiguration()
        #expect(config.loopback == false)
    }
}
