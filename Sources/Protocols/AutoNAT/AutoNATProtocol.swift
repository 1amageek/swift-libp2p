/// AutoNATProtocol - Protocol constants and defaults for AutoNAT.

import Foundation

/// Constants and defaults for AutoNAT protocol.
public enum AutoNATProtocol {
    /// Protocol ID for AutoNAT v1.
    public static let protocolID = "/libp2p/autonat/1.0.0"

    /// Maximum message size (64KB).
    public static let maxMessageSize: Int = 64 * 1024

    /// Maximum addresses to include in a dial request.
    public static let maxAddresses: Int = 16

    /// Default dial-back timeout.
    public static let defaultDialTimeout: Duration = .seconds(30)

    /// Default retry interval (when status is unknown).
    public static let defaultRetryInterval: Duration = .seconds(60)

    /// Default refresh interval (when status is known).
    public static let defaultRefreshInterval: Duration = .seconds(3600)

    /// Minimum probes required to determine status.
    public static let minProbesRequired: Int = 3
}
