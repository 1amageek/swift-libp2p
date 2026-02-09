import Foundation

/// A raw discovery event received from a transport medium.
/// Represents unprocessed beacon data before any decoding or aggregation.
public struct RawDiscovery: Sendable {
    /// The raw beacon payload bytes.
    public let payload: Data

    /// The transport-specific source address.
    public let sourceAddress: OpaqueAddress

    /// When this discovery was received.
    public let timestamp: ContinuousClock.Instant

    /// Received Signal Strength Indicator (dBm), if available.
    public let rssi: Double?

    /// The medium that produced this discovery (e.g., "ble", "wifi-direct").
    public let mediumID: String

    /// Physical-layer fingerprint for Sybil detection, if available.
    public let physicalFingerprint: PhysicalFingerprint?

    public init(
        payload: Data,
        sourceAddress: OpaqueAddress,
        timestamp: ContinuousClock.Instant,
        rssi: Double?,
        mediumID: String,
        physicalFingerprint: PhysicalFingerprint?
    ) {
        self.payload = payload
        self.sourceAddress = sourceAddress
        self.timestamp = timestamp
        self.rssi = rssi
        self.mediumID = mediumID
        self.physicalFingerprint = physicalFingerprint
    }
}
