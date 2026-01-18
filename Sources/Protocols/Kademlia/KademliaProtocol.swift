/// KademliaProtocol - Protocol constants and defaults for Kademlia DHT.

import Foundation

/// Constants and defaults for Kademlia DHT protocol.
public enum KademliaProtocol {
    /// Protocol ID for Kademlia DHT.
    public static let protocolID = "/ipfs/kad/1.0.0"

    /// Maximum message size (1MB).
    public static let maxMessageSize: Int = 1024 * 1024

    /// Replication factor (k) - bucket size and number of closest peers to return.
    public static let kValue: Int = 20

    /// Parallelism factor (alpha) - concurrent queries.
    public static let alphaValue: Int = 3

    /// Number of bits in the key space (SHA-256).
    public static let keyBits: Int = 256

    /// Default record TTL.
    public static let defaultRecordTTL: Duration = .seconds(36 * 3600)  // 36 hours

    /// Record TTL (alias for defaultRecordTTL).
    public static let recordTTL: Duration = defaultRecordTTL

    /// Record republish interval.
    public static let recordRepublishInterval: Duration = .seconds(3600)  // 1 hour

    /// Provider record TTL.
    public static let providerTTL: Duration = .seconds(24 * 3600)  // 24 hours

    /// Provider record republish interval.
    public static let providerRepublishInterval: Duration = .seconds(22 * 3600)  // 22 hours

    /// Provider record expiration.
    public static let providerExpiration: Duration = .seconds(48 * 3600)  // 48 hours

    /// Routing table refresh interval.
    public static let refreshInterval: Duration = .seconds(3600)  // 1 hour

    /// Query timeout.
    public static let queryTimeout: Duration = .seconds(60)

    /// Single request timeout.
    public static let requestTimeout: Duration = .seconds(10)
}

/// Operating mode for Kademlia service.
public enum KademliaMode: Sendable {
    /// Server mode - responds to queries and stores records.
    case server

    /// Client mode - only issues queries, doesn't respond.
    case client

    /// Automatic mode - starts as client, switches to server when publicly reachable.
    case automatic
}
