/// Hex string encoding/decoding utilities.
///
/// Embedded-clean: no Foundation. Returns `[UInt8]`; the `Data(hexString:)`
/// surface lives in the `P2PCore` adapter.

public enum Hex {

    /// Decodes a hex string to bytes.
    ///
    /// - Parameter hexString: A hex-encoded string (e.g., "deadbeef").
    ///   Must have even length. Case-insensitive.
    /// - Returns: The decoded bytes, or `nil` if the string is invalid hex.
    public static func decode(_ hexString: String) -> [UInt8]? {
        let utf8 = Array(hexString.utf8)
        guard utf8.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(utf8.count / 2)
        var i = 0
        while i < utf8.count {
            guard let high = hexValue(utf8[i]),
                  let low = hexValue(utf8[i + 1]) else { return nil }
            bytes.append((high << 4) | low)
            i += 2
        }
        return bytes
    }

    /// Converts a single hex ASCII byte to its numeric value (0-15).
    @inline(__always)
    static func hexValue(_ byte: UInt8) -> UInt8? {
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
