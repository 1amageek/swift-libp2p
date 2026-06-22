/// Multihash framing for self-describing hashes.
/// https://github.com/multiformats/multihash
///
/// Embedded-clean: no Foundation, no Crypto. This is the multihash *framing*
/// (code + length + digest) over `[UInt8]`. The SHA-256 digest factory
/// (`Multihash.sha256`) is a crypto call and lives in the `P2PCore` adapter via
/// the Crypto seam; the identity factory and binary encode/decode are pure and
/// live here.

/// A self-describing hash digest.
public struct Multihash: Sendable, Hashable {

    /// The hash function code.
    public let code: HashCode

    /// The raw digest bytes.
    public let digest: [UInt8]

    @usableFromInline
    let _bytes: [UInt8]

    /// The full multihash bytes (code + length + digest).
    @inlinable
    public var bytes: [UInt8] {
        _bytes
    }

    /// Creates a multihash with the specified code and digest.
    ///
    /// - Parameters:
    ///   - code: The hash function code.
    ///   - digest: The raw digest bytes.
    public init(code: HashCode, digest: [UInt8]) {
        self.code = code
        self.digest = digest
        self._bytes = Self.encodeBytes(code: code, digest: digest)
    }

    /// Maximum allowed digest length to prevent DoS attacks.
    /// 64KB should be more than enough for any reasonable hash digest.
    public static let maxDigestLength: Int = 64 * 1024

    /// Decodes a multihash from its binary representation.
    ///
    /// - Parameter bytes: The multihash bytes.
    /// - Throws: `MultihashError` if the bytes are malformed.
    public init(bytes: [UInt8]) throws(MultihashError) {
        let codeValue: UInt64
        let codeBytes: Int
        do {
            (codeValue, codeBytes) = try Varint.decode(from: bytes, at: 0)
        } catch {
            throw .insufficientData
        }
        guard let code = HashCode(rawValue: codeValue) else {
            throw MultihashError.unknownCode(codeValue)
        }

        let length: UInt64
        let lengthBytes: Int
        do {
            (length, lengthBytes) = try Varint.decode(from: bytes, at: codeBytes)
        } catch {
            throw .insufficientData
        }

        // Bounds check: prevent DoS from huge length values.
        guard length <= UInt64(Self.maxDigestLength) else {
            throw MultihashError.digestTooLarge(length)
        }

        let digestLength = Int(length)
        let digestStart = codeBytes + lengthBytes
        let digestEnd = digestStart + digestLength
        guard digestEnd <= bytes.count else {
            throw MultihashError.insufficientData
        }

        self.code = code
        self.digest = Array(bytes[digestStart..<digestEnd])
        self._bytes = Array(bytes[0..<digestEnd])
    }

    /// Creates an identity multihash (no hashing, just wraps the bytes).
    ///
    /// - Parameter bytes: The bytes to wrap.
    /// - Returns: An identity multihash.
    public static func identity(_ bytes: [UInt8]) -> Multihash {
        Multihash(code: .identity, digest: bytes)
    }

    @usableFromInline
    static func encodeBytes(code: HashCode, digest: [UInt8]) -> [UInt8] {
        var result = Varint.encodeBytes(code.rawValue)
        result.append(contentsOf: Varint.encodeBytes(UInt64(digest.count)))
        result.append(contentsOf: digest)
        return result
    }
}

/// Hash function codes as defined in the multicodec table.
/// https://github.com/multiformats/multicodec/blob/master/table.csv
public enum HashCode: UInt64, Sendable {
    case identity = 0x00
    case sha2_256 = 0x12
    case sha2_512 = 0x13
    case sha3_256 = 0x16
    case sha3_512 = 0x14
    case blake2b_256 = 0xb220
    case blake2s_256 = 0xb260
}

public enum MultihashError: Error, Equatable, Sendable {
    case unknownCode(UInt64)
    case insufficientData
    case digestTooLarge(UInt64)
}
