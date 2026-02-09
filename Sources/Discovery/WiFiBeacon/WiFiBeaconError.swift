import Foundation

/// Errors specific to the WiFi beacon transport adapter.
public enum WiFiBeaconError: Error, Sendable {
    /// Failed to bind the UDP socket.
    case bindFailed(underlying: Error)
}
