/// Base58 encoding/decoding (Bitcoin alphabet).
/// Used for PeerID string representation.

import Foundation

public enum Base58 {

    private static let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")
    private static let base = UInt(alphabet.count)

    private static let decodeTable: [Character: UInt8] = {
        var table: [Character: UInt8] = [:]
        for (index, char) in alphabet.enumerated() {
            table[char] = UInt8(index)
        }
        return table
    }()

    /// Encodes data as a Base58 string.
    ///
    /// - Parameter data: The data to encode
    /// - Returns: Base58-encoded string
    public static func encode(_ data: Data) -> String {
        guard !data.isEmpty else { return "" }

        // Count leading zeros
        var leadingZeros = 0
        for byte in data {
            if byte == 0 {
                leadingZeros += 1
            } else {
                break
            }
        }

        // Convert to base58 using the standard in-place digit expansion.
        // This avoids rebuilding quotient arrays on every division pass.
        let payload = data.dropFirst(leadingZeros)
        let capacity = max(1, (payload.count * 138 / 100) + 1)
        var digits = [UInt8](repeating: 0, count: capacity)
        var digitCount = 0

        for byte in payload {
            var carry = Int(byte)
            var index = 0

            while index < digitCount {
                let value = Int(digits[index]) * 256 + carry
                digits[index] = UInt8(value % Int(base))
                carry = value / Int(base)
                index += 1
            }

            while carry > 0 {
                digits[digitCount] = UInt8(carry % Int(base))
                digitCount += 1
                carry /= Int(base)
            }
        }

        var result = String()
        result.reserveCapacity(leadingZeros + digitCount)

        if leadingZeros > 0 {
            result.append(String(repeating: "1", count: leadingZeros))
        }

        if digitCount > 0 {
            for index in stride(from: digitCount - 1, through: 0, by: -1) {
                result.append(alphabet[Int(digits[index])])
            }
        }

        return result
    }

    /// Decodes a Base58 string to data.
    ///
    /// - Parameter string: The Base58-encoded string
    /// - Returns: Decoded data
    /// - Throws: `Base58Error.invalidCharacter` if the string contains invalid characters
    public static func decode(_ string: String) throws -> Data {
        guard !string.isEmpty else { return Data() }

        // Count leading '1's
        var leadingOnes = 0
        for char in string {
            if char == "1" {
                leadingOnes += 1
            } else {
                break
            }
        }

        // Convert from base58 — O(n*m) where n=string length, m=byte length
        // Uses in-place mutation to avoid O(n²) from repeated array copies
        var bytes: [UInt8] = []
        bytes.reserveCapacity(string.utf8.count)

        for char in string.dropFirst(leadingOnes) {
            guard let value = decodeTable[char] else {
                throw Base58Error.invalidCharacter(char)
            }

            // Multiply existing bytes by 58 and add new value (big-endian)
            var carry = UInt(value)
            for i in stride(from: bytes.count - 1, through: 0, by: -1) {
                let product = UInt(bytes[i]) * base + carry
                bytes[i] = UInt8(product & 0xFF)
                carry = product >> 8
            }

            while carry > 0 {
                bytes.insert(UInt8(carry & 0xFF), at: 0)
                carry >>= 8
            }
        }

        // Add leading zeros
        let leadingZeros = Data(repeating: 0, count: leadingOnes)

        return leadingZeros + Data(bytes)
    }
}

public enum Base58Error: Error, Equatable {
    case invalidCharacter(Character)
}

// MARK: - Data Extension

extension Data {

    /// Returns a Base58-encoded string representation of this data.
    public var base58EncodedString: String {
        Base58.encode(self)
    }

    /// Creates data from a Base58-encoded string.
    ///
    /// - Parameter base58String: The Base58-encoded string
    /// - Throws: `Base58Error` if the string is invalid
    public init(base58Encoded base58String: String) throws {
        self = try Base58.decode(base58String)
    }
}
