import Foundation

/// Describes the physical capabilities and constraints of a transport medium.
public struct MediumCharacteristics: Sendable {
    /// Whether the medium supports sending, receiving, or both.
    public let directionality: Directionality

    /// Maximum beacon payload size in bytes.
    public let maxBeaconSize: Int

    /// Approximate effective range in meters.
    public let approximateRange: ClosedRange<Double>

    /// Minimum interval between beacon transmissions.
    public let minTransmitInterval: Duration

    /// Minimum listen window duration.
    public let minListenWindow: Duration

    /// Number of available channels.
    public let channelCount: Int

    /// Relative energy cost of using this medium (0.0 = low, 1.0 = high).
    public let energyCost: Double

    /// Whether the medium can receive from multiple sources simultaneously.
    public let supportsMultiPacketReception: Bool

    public enum Directionality: Sendable {
        case bidirectional
        case transmitOnly
        case receiveOnly
        case halfDuplex
        case asymmetric
    }

    public init(
        directionality: Directionality,
        maxBeaconSize: Int,
        approximateRange: ClosedRange<Double>,
        minTransmitInterval: Duration,
        minListenWindow: Duration,
        channelCount: Int,
        energyCost: Double,
        supportsMultiPacketReception: Bool
    ) {
        self.directionality = directionality
        self.maxBeaconSize = maxBeaconSize
        self.approximateRange = approximateRange
        self.minTransmitInterval = minTransmitInterval
        self.minListenWindow = minListenWindow
        self.channelCount = channelCount
        self.energyCost = energyCost
        self.supportsMultiPacketReception = supportsMultiPacketReception
    }
}

// MARK: - Static Presets

extension MediumCharacteristics {
    /// BLE legacy advertising: 31-byte payload, 3 channels, half-duplex.
    public static let ble = MediumCharacteristics(
        directionality: .halfDuplex,
        maxBeaconSize: 31,
        approximateRange: 1.0...30.0,
        minTransmitInterval: .milliseconds(20),
        minListenWindow: .milliseconds(10),
        channelCount: 3,
        energyCost: 0.1,
        supportsMultiPacketReception: false
    )

    /// BLE extended advertising: 255-byte payload, 37 channels, half-duplex.
    public static let bleExtended = MediumCharacteristics(
        directionality: .halfDuplex,
        maxBeaconSize: 255,
        approximateRange: 1.0...50.0,
        minTransmitInterval: .milliseconds(20),
        minListenWindow: .milliseconds(10),
        channelCount: 37,
        energyCost: 0.2,
        supportsMultiPacketReception: true
    )

    /// WiFi Direct / peer-to-peer WiFi: 512-byte payload, 13 channels, bidirectional.
    public static let wifiDirect = MediumCharacteristics(
        directionality: .bidirectional,
        maxBeaconSize: 512,
        approximateRange: 5.0...100.0,
        minTransmitInterval: .milliseconds(10),
        minListenWindow: .milliseconds(20),
        channelCount: 13,
        energyCost: 0.5,
        supportsMultiPacketReception: true
    )

    /// LoRa / long-range radio: 51-byte payload, 8 channels, asymmetric.
    public static let lora = MediumCharacteristics(
        directionality: .asymmetric,
        maxBeaconSize: 51,
        approximateRange: 100.0...15000.0,
        minTransmitInterval: .seconds(1),
        minListenWindow: .milliseconds(500),
        channelCount: 8,
        energyCost: 0.3,
        supportsMultiPacketReception: false
    )

    /// NFC: 4096-byte payload, 1 channel, bidirectional, event-driven (no polling).
    public static let nfc = MediumCharacteristics(
        directionality: .bidirectional,
        maxBeaconSize: 4096,
        approximateRange: 0.0...0.04,
        minTransmitInterval: .zero,
        minListenWindow: .zero,
        channelCount: 1,
        energyCost: 0.05,
        supportsMultiPacketReception: false
    )

    /// libp2p / network transport: unlimited payload, unlimited channels, bidirectional.
    public static let libp2p = MediumCharacteristics(
        directionality: .bidirectional,
        maxBeaconSize: Int.max,
        approximateRange: 0.0...Double.infinity,
        minTransmitInterval: .milliseconds(1),
        minListenWindow: .milliseconds(1),
        channelCount: Int.max,
        energyCost: 0.4,
        supportsMultiPacketReception: true
    )
}
