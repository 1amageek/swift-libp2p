import Foundation

/// Physical-layer fingerprint for Sybil detection.
/// Collected by the receiver only -- no additional beacon bytes needed.
/// See: Newsome et al. (IPSN 2004), Radio Resource Testing.
///
/// All fields use integer types for stable Hashable conformance.
public struct PhysicalFingerprint: Sendable, Hashable {
    /// Transmit power (dBm).
    public let txPower: Int8?

    /// Receive channel index.
    public let channelIndex: UInt8?

    /// Packet arrival timing jitter (microseconds, quantized).
    public let timingOffsetMicros: Int64?

    /// Angle of Arrival (integer degrees, BLE 5.1+ Direction Finding).
    public let angleOfArrivalDegrees: Int16?

    public init(
        txPower: Int8? = nil,
        channelIndex: UInt8? = nil,
        timingOffsetMicros: Int64? = nil,
        angleOfArrivalDegrees: Int16? = nil
    ) {
        self.txPower = txPower
        self.channelIndex = channelIndex
        self.timingOffsetMicros = timingOffsetMicros
        self.angleOfArrivalDegrees = angleOfArrivalDegrees
    }
}
