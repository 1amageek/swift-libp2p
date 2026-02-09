import Foundation
import Testing
@testable import P2PDiscoveryWiFiBeacon
@testable import P2PDiscoveryBeacon

@Suite("WiFiBeaconAdapter")
struct WiFiBeaconAdapterTests {

    @Test("mediumID is wifi-direct")
    func mediumIDIsWifiDirect() {
        let adapter = WiFiBeaconAdapter()
        #expect(adapter.mediumID == "wifi-direct")
    }

    @Test("characteristics match wifiDirect preset")
    func characteristicsMatchPreset() {
        let adapter = WiFiBeaconAdapter()
        #expect(adapter.characteristics.maxBeaconSize == 512)
        #expect(adapter.characteristics.channelCount == 13)
        #expect(adapter.characteristics.directionality == .bidirectional)
        #expect(adapter.characteristics.supportsMultiPacketReception == true)
    }

    @Test("startBeacon too large throws", .timeLimit(.minutes(1)))
    func startBeaconTooLargeThrows() async {
        let adapter = WiFiBeaconAdapter()
        let oversized = Data(repeating: 0xAA, count: 513)
        await #expect(throws: TransportAdapterError.self) {
            try await adapter.startBeacon(oversized)
        }
        await adapter.shutdown()
    }

    @Test("startBeacon after shutdown throws", .timeLimit(.minutes(1)))
    func startBeaconAfterShutdownThrows() async {
        let adapter = WiFiBeaconAdapter()
        await adapter.shutdown()
        let payload = Data([0xD0, 0x12, 0x34, 0xAA, 0xBB, 0xCC, 0x00, 0x00, 0x01, 0x02])
        await #expect(throws: TransportAdapterError.self) {
            try await adapter.startBeacon(payload)
        }
    }

    @Test("shutdown is idempotent", .timeLimit(.minutes(1)))
    func shutdownIsIdempotent() async {
        let adapter = WiFiBeaconAdapter()
        await adapter.shutdown()
        await adapter.shutdown()  // second call should not crash
    }

    @Test("shutdown finishes discovery stream", .timeLimit(.minutes(1)))
    func shutdownFinishesDiscoveryStream() async {
        let adapter = WiFiBeaconAdapter()
        let stream = adapter.discoveries
        await adapter.shutdown()

        var count = 0
        for await _ in stream {
            count += 1
        }
        #expect(count == 0)
    }

    @Test("discoveries after shutdown returns finished stream", .timeLimit(.minutes(1)))
    func discoveriesAfterShutdownReturnsFinishedStream() async {
        let adapter = WiFiBeaconAdapter()
        await adapter.shutdown()

        // This should return an immediately-finished stream, not hang
        var count = 0
        for await _ in adapter.discoveries {
            count += 1
        }
        #expect(count == 0)
    }

    @Test("loopback receives own beacon", .timeLimit(.minutes(1)))
    func loopbackReceivesOwnBeacon() async throws {
        let config = WiFiBeaconConfiguration(
            port: 0,
            transmitInterval: .milliseconds(100),
            loopback: true
        )
        let adapter = WiFiBeaconAdapter(configuration: config)

        // Tier 1 beacon payload (10 bytes)
        let payload = Data([0xD0, 0x12, 0x34, 0xAA, 0xBB, 0xCC, 0x00, 0x00, 0x01, 0x02])
        try await adapter.startBeacon(payload)

        // Wait for first discovery
        var received: RawDiscovery?
        for await discovery in adapter.discoveries {
            received = discovery
            break
        }

        #expect(received != nil)
        #expect(received?.payload == payload)
        #expect(received?.mediumID == "wifi-direct")
        #expect(received?.rssi == nil)
        #expect(received?.physicalFingerprint == nil)
        #expect(received?.sourceAddress.mediumID == "wifi-direct")
        #expect((received?.sourceAddress.raw.count ?? 0) > 0)

        await adapter.shutdown()
    }

    @Test("stopBeacon clears payload", .timeLimit(.minutes(1)))
    func stopBeaconClearsPayload() async throws {
        let config = WiFiBeaconConfiguration(
            port: 0,
            transmitInterval: .milliseconds(100),
            loopback: true
        )
        let adapter = WiFiBeaconAdapter(configuration: config)

        let payload = Data([0xD0, 0x12, 0x34, 0xAA, 0xBB, 0xCC, 0x00, 0x00, 0x01, 0x02])
        try await adapter.startBeacon(payload)
        await adapter.stopBeacon()

        // After stopping, transmit loop should exit.
        try await Task.sleep(for: .milliseconds(300))

        await adapter.shutdown()
    }
}
