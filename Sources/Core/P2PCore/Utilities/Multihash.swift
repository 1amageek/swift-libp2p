/// Multihash implementation for self-describing hashes.
/// https://github.com/multiformats/multihash

import Foundation
import Crypto

/// A self-describing hash digest.
public struct Multihash: Sendable, Hashable {

    /// The hash function code.
    public let code: HashCode

    /// The raw digest bytes.
    public let digest: Data

    /// The full multihash bytes (code + length + digest).
    public var bytes: Data {
        var result = Varint.encode(code.rawValue)
        result.append(contentsOf: Varint.encode(UInt64(digest.count)))
        result.append(digest)
        return result
    }

    /// Creates a multihash with the specified code and digest.
    ///
    /// - Parameters:
    ///   - code: The hash function code
    ///   - digest: The raw digest bytes
    public init(code: HashCode, digest: Data) {
        self.code = code
        self.digest = digest
    }

    /// Maximum allowed digest length to prevent DoS attacks.
    /// 64KB should be more than enough for any reasonable hash digest.
    public static let maxDigestLength: Int = 64 * 1024

    /// Decodes a multihash from its binary representation.
    ///
    /// - Parameter data: The multihash bytes
    /// - Throws: `MultihashError` if the data is malformed
    public init(bytes data: Data) throws {
        let (codeValue, codeBytes) = try Varint.decode(data)
        guard let code = HashCode(rawValue: codeValue) else {
            throw MultihashError.unknownCode(codeValue)
        }

        let remaining = data.dropFirst(codeBytes)
        let (length, lengthBytes) = try Varint.decode(Data(remaining))

        // Bounds check: prevent DoS from huge length values
        guard length <= Self.maxDigestLength else {
            throw MultihashError.digestTooLarge(length)
        }

        let digestLength = Int(length)
        let digestStart = remaining.dropFirst(lengthBytes)
        guard digestStart.count >= digestLength else {
            throw MultihashError.insufficientData
        }

        self.code = code
        self.digest = Data(digestStart.prefix(digestLength))
    }

    /// Creates a SHA-256 multihash of the given data.
    ///
    /// - Parameter data: The data to hash
    /// - Returns: A SHA-256 multihash
    public static func sha256(_ data: Data) -> Multihash {
        let digest = Data(SHA256.hash(data: data))
        return Multihash(code: .sha2_256, digest: digest)
    }

    /// Creates an identity multihash (no hashing, just wraps the data).
    ///
    /// - Parameter data: The data to wrap
    /// - Returns: An identity multihash
    public static func identity(_ data: Data) -> Multihash {
        Multihash(code: .identity, digest: data)
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

public enum MultihashError: Error, Equatable {
    case unknownCode(UInt64)
    case insufficientData
    case digestTooLarge(UInt64)
}
