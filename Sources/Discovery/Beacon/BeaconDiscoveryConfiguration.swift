import Foundation
import P2PCore

/// Configuration for the BeaconDiscovery service.
public struct BeaconDiscoveryConfiguration: Sendable {

    /// The local key pair for signing beacons and deriving EphIDs.
    public let keyPair: KeyPair

    /// PoW difficulty for beacon generation (number of leading zero bits).
    /// Default is 16.
    public var powDifficulty: Int

    /// Sybil detection threshold: maximum distinct truncIDs per physical fingerprint.
    /// Default is 5.
    public var sybilThreshold: Int

    /// Sybil detection sliding window duration.
    /// Default is 30 minutes.
    public var sybilWindow: Duration

    /// Minimum interval between accepted beacons from the same (truncID, mediumID) pair.
    /// Default is 5 seconds.
    public var beaconRateLimit: Duration

    /// EphID rotation interval.
    /// Default is 10 minutes.
    public var ephIDRotationInterval: Duration

    /// Capability bloom filter (10 bytes) to advertise in Tier 2 beacons.
    /// Default is all zeros (no capabilities).
    public var capabilityBloom: Data

    /// The peer record store to use for persistence.
    /// Default is `InMemoryBeaconPeerStore`.
    public var store: any BeaconPeerStore

    public init(
        keyPair: KeyPair,
        powDifficulty: Int = MicroPoW.defaultDifficulty,
        sybilThreshold: Int = 5,
        sybilWindow: Duration = .seconds(1800),
        beaconRateLimit: Duration = .seconds(5),
        ephIDRotationInterval: Duration = .seconds(600),
        capabilityBloom: Data = Data(repeating: 0, count: 10),
        store: (any BeaconPeerStore)? = nil
    ) {
        self.keyPair = keyPair
        self.powDifficulty = powDifficulty
        self.sybilThreshold = sybilThreshold
        self.sybilWindow = sybilWindow
        self.beaconRateLimit = beaconRateLimit
        self.ephIDRotationInterval = ephIDRotationInterval
        self.capabilityBloom = capabilityBloom
        self.store = store ?? InMemoryBeaconPeerStore()
    }
}
