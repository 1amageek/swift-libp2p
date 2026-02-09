import Foundation
import P2PCore

/// Result of decoding a raw beacon payload.
/// Contains tier-specific fields populated based on the beacon type.
public struct DecodedBeacon: Sendable {
    /// The beacon tier that was decoded.
    public let tier: BeaconTier

    /// Truncated peer identifier (Tier 1-2). First 2 bytes of EphID.
    public let truncID: UInt16?

    /// Full peer identity (Tier 3 only).
    public let fullID: PeerID?

    /// 4-byte nonce used for PoW and freshness.
    public let nonce: Data

    /// Whether the proof-of-work passed verification.
    public let powValid: Bool

    /// HMAC-SHA256 truncated to 4 bytes (Tier 2 only).
    public let teslaMAC: Data?

    /// Previous TESLA key truncated to 8 bytes (Tier 2 only).
    public let teslaPrevKey: Data?

    /// Capability bloom filter, 10 bytes (Tier 2 only).
    public let capabilityBloom: Data?

    /// Signed envelope containing a BeaconPeerRecord (Tier 3 only).
    public let envelope: Envelope?

    public init(
        tier: BeaconTier,
        truncID: UInt16? = nil,
        fullID: PeerID? = nil,
        nonce: Data,
        powValid: Bool,
        teslaMAC: Data? = nil,
        teslaPrevKey: Data? = nil,
        capabilityBloom: Data? = nil,
        envelope: Envelope? = nil
    ) {
        self.tier = tier
        self.truncID = truncID
        self.fullID = fullID
        self.nonce = nonce
        self.powValid = powValid
        self.teslaMAC = teslaMAC
        self.teslaPrevKey = teslaPrevKey
        self.capabilityBloom = capabilityBloom
        self.envelope = envelope
    }
}
