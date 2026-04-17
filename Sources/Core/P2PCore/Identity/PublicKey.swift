/// Public key representation for libp2p.
/// https://github.com/libp2p/specs/blob/master/peer-ids/peer-ids.md

import Foundation
import Crypto

/// A public key used for peer identification and verification.
public struct PublicKey: Sendable {

    /// The type of this key.
    public let keyType: KeyType

    /// The raw public key bytes.
    public let rawBytes: Data

    /// Pre-computed protobuf-encoded representation.
    private let _protobufEncoded: Data

    /// Pre-constructed CryptoKit key, populated at init.
    /// Avoids reconstructing the key on every verify() call (hot path).
    private let _cryptoKey: CryptoKey

    // MARK: - Raw Bytes Initialization

    /// Creates a public key from raw bytes.
    ///
    /// - Parameters:
    ///   - keyType: The type of the key
    ///   - rawBytes: The raw public key bytes
    /// - Throws: `PublicKeyError.invalidKeySize` if the bytes are invalid
    public init(keyType: KeyType, rawBytes: Data) throws {
        self.keyType = keyType
        self.rawBytes = rawBytes

        // Validate key size and pre-construct CryptoKit key for verify() hot path.
        switch keyType {
        case .ed25519:
            guard rawBytes.count == 32 else {
                throw PublicKeyError.invalidKeySize(expected: 32, actual: rawBytes.count)
            }
            let key = try Curve25519.Signing.PublicKey(rawRepresentation: rawBytes)
            self._cryptoKey = .ed25519(key)
        case .secp256k1:
            guard rawBytes.count == 33 || rawBytes.count == 65 else {
                throw PublicKeyError.invalidKeySize(expected: 33, actual: rawBytes.count)
            }
            self._cryptoKey = .unsupported
        case .ecdsa:
            // P-256 public key: 65 bytes uncompressed or 33 bytes compressed
            guard rawBytes.count == 33 || rawBytes.count == 65 else {
                throw PublicKeyError.invalidKeySize(expected: 65, actual: rawBytes.count)
            }
            let key: P256.Signing.PublicKey
            if rawBytes.count == 65 {
                key = try P256.Signing.PublicKey(x963Representation: rawBytes)
            } else {
                key = try P256.Signing.PublicKey(compressedRepresentation: rawBytes)
            }
            self._cryptoKey = .ecdsa(key)
        case .rsa:
            // RSA keys are variable length
            guard !rawBytes.isEmpty else {
                throw PublicKeyError.invalidKeySize(expected: 1, actual: 0)
            }
            self._cryptoKey = .unsupported
        }

        self._protobufEncoded = Self.buildProtobufEncoded(keyType: keyType, rawBytes: rawBytes)
    }

    // MARK: - Ed25519

    /// Creates an Ed25519 public key from a Curve25519 signing key.
    ///
    /// - Parameter key: The Ed25519 public key
    public init(ed25519 key: Curve25519.Signing.PublicKey) {
        let rawBytes = Data(key.rawRepresentation)
        self.keyType = .ed25519
        self.rawBytes = rawBytes
        self._cryptoKey = .ed25519(key)
        self._protobufEncoded = Self.buildProtobufEncoded(keyType: .ed25519, rawBytes: rawBytes)
    }

    /// Returns this key as a Curve25519 signing public key, if applicable.
    ///
    /// - Throws: `PublicKeyError.keyTypeMismatch` if this is not an Ed25519 key
    public func ed25519Key() throws -> Curve25519.Signing.PublicKey {
        guard case let .ed25519(key) = _cryptoKey else {
            throw PublicKeyError.keyTypeMismatch(expected: .ed25519, actual: keyType)
        }
        return key
    }

    // MARK: - ECDSA P-256

    /// Creates an ECDSA P-256 public key from a P256 signing key.
    ///
    /// - Parameter key: The ECDSA P-256 public key
    public init(ecdsa key: P256.Signing.PublicKey) {
        // Use uncompressed representation (65 bytes) for compatibility
        let rawBytes = Data(key.x963Representation)
        self.keyType = .ecdsa
        self.rawBytes = rawBytes
        self._cryptoKey = .ecdsa(key)
        self._protobufEncoded = Self.buildProtobufEncoded(keyType: .ecdsa, rawBytes: rawBytes)
    }

    /// Returns this key as a P256 signing public key, if applicable.
    ///
    /// - Throws: `PublicKeyError.keyTypeMismatch` if this is not an ECDSA key
    public func ecdsaKey() throws -> P256.Signing.PublicKey {
        guard case let .ecdsa(key) = _cryptoKey else {
            throw PublicKeyError.keyTypeMismatch(expected: .ecdsa, actual: keyType)
        }
        return key
    }

    // MARK: - Verification

    /// Verifies a signature against this public key.
    ///
    /// - Parameters:
    ///   - signature: The signature to verify
    ///   - data: The data that was signed
    /// - Returns: `true` if the signature is valid
    /// - Throws: `PublicKeyError` if verification cannot be performed
    public func verify(signature: Data, for data: Data) throws -> Bool {
        switch _cryptoKey {
        case .ed25519(let key):
            return key.isValidSignature(signature, for: data)

        case .ecdsa(let key):
            // Signature is DER encoded
            let ecdsaSignature = try P256.Signing.ECDSASignature(derRepresentation: signature)
            return key.isValidSignature(ecdsaSignature, for: data)

        case .unsupported:
            throw PublicKeyError.unsupportedOperation
        }
    }

    /// The PeerID derived from this public key.
    public var peerID: PeerID {
        PeerID(publicKey: self)
    }

    /// The protobuf-encoded representation of this public key (pre-computed).
    ///
    /// Format: KeyType (varint) + key data
    public var protobufEncoded: Data {
        _protobufEncoded
    }

    /// Decodes a public key from its protobuf representation.
    ///
    /// - Parameter data: The protobuf-encoded public key
    /// - Throws: `PublicKeyError` if decoding fails
    public init(protobufEncoded data: Data) throws {
        var offset = 0
        var keyType: KeyType?
        var keyData: Data?

        while offset < data.count {
            let (fieldTag, fieldBytes) = try Varint.decode(from: data, at: offset)
            offset += fieldBytes

            let fieldNumber = fieldTag >> 3
            let wireType = fieldTag & 0x07

            switch (fieldNumber, wireType) {
            case (1, 0): // KeyType varint
                let (typeValue, typeBytes) = try Varint.decode(from: data, at: offset)
                offset += typeBytes
                guard let type = KeyType(rawValue: typeValue) else {
                    throw PublicKeyError.unknownKeyType(typeValue)
                }
                keyType = type

            case (2, 2): // Data length-delimited
                let (length, lengthBytes) = try Varint.decode(from: data, at: offset)
                offset += lengthBytes
                // Bounds check: prevent DoS from huge length values
                // Public keys are typically 32-256 bytes, 4KB is more than enough
                guard length <= 4096 else {
                    throw PublicKeyError.keyDataTooLarge(length)
                }
                let keyLength = Int(length)
                let keyDataEnd = offset + keyLength
                guard keyDataEnd <= data.count else {
                    throw PublicKeyError.invalidProtobuf
                }
                keyData = data[Self.fieldRange(in: data, offset: offset, end: keyDataEnd)]
                offset = keyDataEnd

            default:
                throw PublicKeyError.invalidProtobuf
            }
        }

        guard let type = keyType, let data = keyData else {
            throw PublicKeyError.invalidProtobuf
        }

        try self.init(keyType: type, rawBytes: data)
    }

    private static func fieldRange(in data: Data, offset: Int, end: Int) -> Range<Data.Index> {
        let startIndex = data.index(data.startIndex, offsetBy: offset)
        let endIndex = data.index(data.startIndex, offsetBy: end)
        return startIndex..<endIndex
    }

    private static func buildProtobufEncoded(keyType: KeyType, rawBytes: Data) -> Data {
        var encoded = Data()
        encoded.append(0x08) // Field 1: KeyType (field number 1, wire type 0)
        encoded.append(contentsOf: Varint.encode(keyType.rawValue))
        encoded.append(0x12) // Field 2: Data (field number 2, wire type 2)
        encoded.append(contentsOf: Varint.encode(UInt64(rawBytes.count)))
        encoded.append(rawBytes)
        return encoded
    }
}

// MARK: - Cached CryptoKit key wrapper

/// Internal enum holding the constructed CryptoKit key.
/// Constructed once at PublicKey init to avoid rebuilding on every verify().
private enum CryptoKey: Sendable {
    case ed25519(Curve25519.Signing.PublicKey)
    case ecdsa(P256.Signing.PublicKey)
    case unsupported
}

// MARK: - Equatable / Hashable

extension PublicKey: Hashable {
    /// Equality is derived from keyType + rawBytes only.
    /// The cached CryptoKit key is a derived value and must not participate.
    public static func == (lhs: PublicKey, rhs: PublicKey) -> Bool {
        lhs.keyType == rhs.keyType && lhs.rawBytes == rhs.rawBytes
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(keyType)
        hasher.combine(rawBytes)
    }
}

public enum PublicKeyError: Error, Equatable {
    case invalidKeySize(expected: Int, actual: Int)
    case keyTypeMismatch(expected: KeyType, actual: KeyType)
    case unknownKeyType(UInt64)
    case invalidProtobuf
    case unsupportedOperation
    case keyDataTooLarge(UInt64)
}
