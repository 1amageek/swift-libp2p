import Foundation
import Testing
@testable import P2PCore
@testable import P2PDiscoveryBeacon

@Suite("BeaconDiscoveryConfiguration")
struct BeaconDiscoveryConfigurationTests {

    @Test("default values")
    func defaultValues() {
        let kp = makeKeyPair()
        let config = BeaconDiscoveryConfiguration(keyPair: kp)
        #expect(config.powDifficulty == 16)
        #expect(config.sybilThreshold == 5)
        #expect(config.sybilWindow == .seconds(1800))
        #expect(config.beaconRateLimit == .seconds(5))
        #expect(config.ephIDRotationInterval == .seconds(600))
        #expect(config.capabilityBloom == Data(repeating: 0, count: 10))
    }

    @Test("custom values")
    func customValues() {
        let kp = makeKeyPair()
        let bloom = Data(repeating: 0xFF, count: 10)
        let config = BeaconDiscoveryConfiguration(
            keyPair: kp,
            powDifficulty: 8,
            sybilThreshold: 10,
            sybilWindow: .seconds(3600),
            beaconRateLimit: .seconds(1),
            ephIDRotationInterval: .seconds(300),
            capabilityBloom: bloom
        )
        #expect(config.powDifficulty == 8)
        #expect(config.sybilThreshold == 10)
        #expect(config.sybilWindow == .seconds(3600))
        #expect(config.beaconRateLimit == .seconds(1))
        #expect(config.ephIDRotationInterval == .seconds(300))
        #expect(config.capabilityBloom == bloom)
    }

    @Test("default store is InMemory")
    func defaultStoreIsInMemory() {
        let kp = makeKeyPair()
        let config = BeaconDiscoveryConfiguration(keyPair: kp)
        #expect(config.store is InMemoryBeaconPeerStore)
    }

    @Test("custom store injection")
    func customStoreInjection() {
        let kp = makeKeyPair()
        let customStore = InMemoryBeaconPeerStore()
        let config = BeaconDiscoveryConfiguration(keyPair: kp, store: customStore)
        #expect(config.store is InMemoryBeaconPeerStore)
    }
}
