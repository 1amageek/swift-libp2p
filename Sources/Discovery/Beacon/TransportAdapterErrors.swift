/// Errors that can occur when interacting with a transport adapter.
public enum TransportAdapterError: Error, Sendable {
    /// The beacon payload exceeds the medium's maximum size.
    case beaconTooLarge(size: Int, max: Int)

    /// Failed to establish a connection to the remote peer.
    case connectionFailed(String)

    /// The transport medium is not currently available (e.g., BLE disabled).
    case mediumNotAvailable

    /// The provided address does not match the expected medium type.
    case addressTypeMismatch(expected: String, got: String)
}
