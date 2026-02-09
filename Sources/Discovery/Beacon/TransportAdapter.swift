import Foundation

/// Abstracts a physical transport medium for peer discovery.
/// Each concrete adapter (BLE, WiFi Direct, LoRa, etc.) conforms to this protocol.
///
/// Unlike the original swift-p2p-discovery version, this protocol does not include
/// `connect(to:)` for establishing bidirectional streams. Connection management
/// is handled by the P2PTransport layer in swift-libp2p.
public protocol TransportAdapter: Sendable {
    /// Unique identifier for this medium (e.g., "ble", "wifi-direct", "lora").
    var mediumID: String { get }

    /// The physical characteristics of this medium.
    var characteristics: MediumCharacteristics { get }

    /// Starts broadcasting the given beacon payload.
    /// - Parameter payload: The raw beacon bytes to transmit.
    /// - Throws: `TransportAdapterError.beaconTooLarge` if payload exceeds `characteristics.maxBeaconSize`.
    func startBeacon(_ payload: Data) async throws

    /// Stops the current beacon broadcast.
    func stopBeacon() async

    /// A stream of raw discoveries received from this medium.
    var discoveries: AsyncStream<RawDiscovery> { get }

    /// Shuts down the adapter and releases all resources.
    func shutdown() async
}
