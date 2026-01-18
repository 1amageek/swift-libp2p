/// Protocol constants for DCUtR (Direct Connection Upgrade through Relay).
///
/// DCUtR enables peers to upgrade relayed connections to direct connections
/// via hole punching.
///
/// See: https://github.com/libp2p/specs/blob/master/relay/DCUtR.md

import Foundation

/// Protocol constants for DCUtR.
public enum DCUtRProtocol {
    /// Protocol ID for DCUtR.
    public static let protocolID = "/libp2p/dcutr"

    /// Maximum message size.
    public static let maxMessageSize: Int = 4096

    /// Default timeout for hole punch attempts.
    public static let defaultTimeout: Duration = .seconds(30)

    /// Maximum number of hole punch attempts.
    public static let maxAttempts: Int = 3
}
