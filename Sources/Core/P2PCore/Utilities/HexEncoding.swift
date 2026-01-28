/// Hex string encoding/decoding utilities for Data.
import Foundation

extension Data {
    /// Creates Data from a hex string.
    ///
    /// - Parameter hexString: A hex-encoded string (e.g., "deadbeef").
    ///   Must have even length. Case-insensitive.
    /// - Returns: The decoded data, or nil if the string is invalid hex.
    public init?(hexString: String) {
        let hex = hexString.lowercased()
        var data = Data()
        var index = hex.startIndex

        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard nextIndex <= hex.endIndex else { return nil }
            let byteString = hex[index..<nextIndex]
            guard let byte = UInt8(byteString, radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }

        self = data
    }
}
