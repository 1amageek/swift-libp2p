import Foundation

/// RSSI-based trust calculation per medium type.
///
/// Converts smoothed RSSI values to trust scores based on the physical
/// characteristics of each communication medium.
public struct TrustCalculator: Sendable {

    /// Converts a smoothed RSSI value to a trust score (0.0-1.0) based on the medium type.
    ///
    /// Trust ranges are calibrated per medium:
    /// - NFC: Always 1.0 (physical contact required).
    /// - BLE: 0.3-1.0 based on signal strength.
    /// - WiFi Direct: 0.2-0.8 based on signal strength.
    /// - LoRa: 0.1-0.5 based on signal strength.
    /// - Unknown: 0.5 as a neutral default.
    ///
    /// - Parameters:
    ///   - rssi: The smoothed RSSI value in dBm, or nil if unavailable.
    ///   - medium: The medium identifier (e.g., "ble", "wifi-direct", "lora", "nfc").
    /// - Returns: A trust value in [0.0, 1.0].
    public static func directObservationTrust(rssi: Double?, medium: String) -> Double {
        switch medium {
        case "nfc":
            return 1.0
        case "ble":
            guard let rssi else { return 0.5 }
            return max(0.3, min(1.0, (rssi + 90) / 60))
        case "wifi-direct":
            guard let rssi else { return 0.4 }
            return max(0.2, min(0.8, (rssi + 80) / 60))
        case "lora":
            guard let rssi else { return 0.2 }
            return max(0.1, min(0.5, (rssi + 120) / 80))
        default:
            return 0.5
        }
    }
}
