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

        // Convert to base58
        var bytes = [UInt8](data)
        var result: [Character] = []

        while !bytes.allSatisfy({ $0 == 0 }) {
            var remainder: UInt = 0
            var newBytes: [UInt8] = []

            for byte in bytes {
                let value = remainder * 256 + UInt(byte)
                let quotient = value / base
                remainder = value % base

                if !newBytes.isEmpty || quotient > 0 {
                    newBytes.append(UInt8(quotient))
                }
            }

            result.append(alphabet[Int(remainder)])
            bytes = newBytes
        }

        // Add leading '1's for each leading zero byte
        let leadingOnes = String(repeating: "1", count: leadingZeros)

        return leadingOnes + String(result.reversed())
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

        // Convert from base58
        var bytes: [UInt8] = []

        for char in string.dropFirst(leadingOnes) {
            guard let value = decodeTable[char] else {
                throw Base58Error.invalidCharacter(char)
            }

            var carry = UInt(value)
            var newBytes: [UInt8] = []

            for byte in bytes.reversed() {
                let product = UInt(byte) * base + carry
                newBytes.append(UInt8(product & 0xFF))
                carry = product >> 8
            }

            while carry > 0 {
                newBytes.append(UInt8(carry & 0xFF))
                carry >>= 8
            }

            newBytes.reverse()
            bytes = newBytes
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
