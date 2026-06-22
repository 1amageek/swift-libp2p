/// Base58 encoding/decoding (Bitcoin alphabet).
/// Used for PeerID string representation.
///
/// Embedded-clean: no Foundation. The byte container is `[UInt8]`; the
/// `Data`/`String`-extension surface lives in the `P2PCore` adapter.

public enum Base58 {

    @usableFromInline
    static let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")

    @usableFromInline
    static let base = UInt(58)

    @usableFromInline
    static let decodeTable: [Character: UInt8] = {
        var table: [Character: UInt8] = [:]
        for (index, char) in alphabet.enumerated() {
            table[char] = UInt8(index)
        }
        return table
    }()

    /// Encodes bytes as a Base58 string.
    ///
    /// - Parameter bytes: The bytes to encode.
    /// - Returns: Base58-encoded string.
    public static func encode(_ bytes: [UInt8]) -> String {
        guard !bytes.isEmpty else { return "" }

        // Count leading zeros.
        var leadingZeros = 0
        for byte in bytes {
            if byte == 0 {
                leadingZeros += 1
            } else {
                break
            }
        }

        // Convert to base58 using the standard in-place digit expansion.
        // This avoids rebuilding quotient arrays on every division pass.
        let payload = bytes.dropFirst(leadingZeros)
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

    /// Decodes a Base58 string to bytes.
    ///
    /// - Parameter string: The Base58-encoded string.
    /// - Returns: Decoded bytes.
    /// - Throws: `Base58Error.invalidCharacter` if the string contains invalid characters.
    public static func decode(_ string: String) throws(Base58Error) -> [UInt8] {
        guard !string.isEmpty else { return [] }

        // Count leading '1's.
        var leadingOnes = 0
        for char in string {
            if char == "1" {
                leadingOnes += 1
            } else {
                break
            }
        }

        // Convert from base58 — O(n*m) where n=string length, m=byte length.
        // Uses in-place mutation to avoid O(n²) from repeated array copies.
        var bytes: [UInt8] = []
        bytes.reserveCapacity(string.utf8.count)

        for char in string.dropFirst(leadingOnes) {
            guard let value = decodeTable[char] else {
                throw Base58Error.invalidCharacter(char)
            }

            // Multiply existing bytes by 58 and add new value (big-endian).
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

        // Add leading zeros.
        var result = [UInt8](repeating: 0, count: leadingOnes)
        result.append(contentsOf: bytes)
        return result
    }
}

public enum Base58Error: Error, Equatable, Sendable {
    case invalidCharacter(Character)
}
