import Foundation

/// Beacon tier levels corresponding to different payload sizes.
public enum BeaconTier: UInt8, Sendable, Codable {
    /// 10 bytes: Tag + TruncID + PoW + Nonce
    case tier1 = 0x00

    /// 32 bytes: + MAC_t + Key_p + CapBloom
    case tier2 = 0x01

    /// Variable length: + FullID + SignedPeerRecord
    case tier3 = 0x02
}

extension BeaconTier {
    /// The Tag byte for this tier: magic prefix 0xD0 | tier raw value.
    public var tagByte: UInt8 {
        0xD0 | rawValue
    }

    /// Creates a BeaconTier from a tag byte.
    public init?(tagByte: UInt8) {
        guard tagByte & 0xFC == 0xD0 else { return nil }
        self.init(rawValue: tagByte & 0x03)
    }

    /// Minimum payload size for this tier.
    ///
    /// Tier 3 minimum = header (1 tag + 2 peerIDLen + variable peerID + 4 nonce + 2 envelopeLen)
    /// + envelope minimum. Conservative estimate for typical Ed25519 PeerIDs.
    public var minimumSize: Int {
        switch self {
        case .tier1: 10
        case .tier2: 32
        case .tier3: 145
        }
    }
}
