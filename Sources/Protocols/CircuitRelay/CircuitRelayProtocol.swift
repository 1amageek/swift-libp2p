/// Protocol constants for Circuit Relay v2.
///
/// Circuit Relay v2 enables peers behind NATs to communicate through
/// public relay nodes. This file defines the protocol IDs and default
/// configuration values.
///
/// See: https://github.com/libp2p/specs/blob/master/relay/circuit-v2.md

import Foundation

/// Protocol constants for Circuit Relay v2.
public enum CircuitRelayProtocol {
    /// Hop protocol ID for client-to-relay communication.
    public static let hopProtocolID = "/libp2p/circuit/relay/0.2.0/hop"

    /// Stop protocol ID for relay-to-target communication.
    public static let stopProtocolID = "/libp2p/circuit/relay/0.2.0/stop"

    /// Default reservation duration (1 hour).
    public static let defaultReservationDuration: Duration = .seconds(3600)

    /// Default circuit data limit (128 KB).
    public static let defaultDataLimit: UInt64 = 128 * 1024

    /// Default circuit duration limit (2 minutes).
    public static let defaultDurationLimit: Duration = .seconds(120)

    /// Maximum message size.
    public static let maxMessageSize: Int = 4096
}
