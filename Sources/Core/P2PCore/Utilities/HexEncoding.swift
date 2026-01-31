/// Hex string encoding/decoding utilities for Data.
import Foundation

extension Data {
    /// Creates Data from a hex string.
    ///
    /// - Parameter hexString: A hex-encoded string (e.g., "deadbeef").
    ///   Must have even length. Case-insensitive.
    /// - Returns: The decoded data, or nil if the string is invalid hex.
    public init?(hexString: String) {
        let utf8 = Array(hexString.utf8)
        guard utf8.count % 2 == 0 else { return nil }
        var data = Data(capacity: utf8.count / 2)
        var i = 0
        while i < utf8.count {
            guard let high = Self.hexValue(utf8[i]),
                  let low = Self.hexValue(utf8[i + 1]) else { return nil }
            data.append((high << 4) | low)
            i += 2
        }
        self = data
    }

    /// Converts a single hex ASCII byte to its numeric value (0-15).
    @inline(__always)
    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            return byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"):
            return byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"):
            return byte - UInt8(ascii: "A") + 10
        default:
            return nil
        }
    }
}
