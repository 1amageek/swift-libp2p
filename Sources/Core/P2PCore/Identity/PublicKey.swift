/// Public key representation for libp2p.
/// https://github.com/libp2p/specs/blob/master/peer-ids/peer-ids.md

import Foundation
import Crypto

/// A public key used for peer identification and verification.
public struct PublicKey: Sendable, Hashable {

    /// The type of this key.
    public let keyType: KeyType

    /// The raw public key bytes.
    public let rawBytes: Data

    /// Pre-computed protobuf-encoded representation.
    private let _protobufEncoded: Data

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

        // Validate key size for known types
        switch keyType {
        case .ed25519:
            guard rawBytes.count == 32 else {
                throw PublicKeyError.invalidKeySize(expected: 32, actual: rawBytes.count)
            }
        case .secp256k1:
            guard rawBytes.count == 33 || rawBytes.count == 65 else {
                throw PublicKeyError.invalidKeySize(expected: 33, actual: rawBytes.count)
            }
        case .ecdsa:
            // P-256 public key: 65 bytes uncompressed or 33 bytes compressed
            guard rawBytes.count == 33 || rawBytes.count == 65 else {
                throw PublicKeyError.invalidKeySize(expected: 65, actual: rawBytes.count)
            }
        case .rsa:
            // RSA keys are variable length
            guard !rawBytes.isEmpty else {
                throw PublicKeyError.invalidKeySize(expected: 1, actual: 0)
            }
        }

        // Pre-compute protobuf encoding
        var encoded = Data()
        encoded.append(0x08) // Field 1: KeyType (field number 1, wire type 0)
        encoded.append(contentsOf: Varint.encode(keyType.rawValue))
        encoded.append(0x12) // Field 2: Data (field number 2, wire type 2)
        encoded.append(contentsOf: Varint.encode(UInt64(rawBytes.count)))
        encoded.append(rawBytes)
        self._protobufEncoded = encoded
    }

    // MARK: - Ed25519

    /// Creates an Ed25519 public key from a Curve25519 signing key.
    ///
    /// - Parameter key: The Ed25519 public key
    public init(ed25519 key: Curve25519.Signing.PublicKey) {
        self.keyType = .ed25519
        self.rawBytes = Data(key.rawRepresentation)

        // Pre-compute protobuf encoding
        var encoded = Data()
        encoded.append(0x08)
        encoded.append(contentsOf: Varint.encode(KeyType.ed25519.rawValue))
        encoded.append(0x12)
        encoded.append(contentsOf: Varint.encode(UInt64(self.rawBytes.count)))
        encoded.append(self.rawBytes)
        self._protobufEncoded = encoded
    }

    /// Returns this key as a Curve25519 signing public key, if applicable.
    ///
    /// - Throws: `PublicKeyError.keyTypeMismatch` if this is not an Ed25519 key
    public func ed25519Key() throws -> Curve25519.Signing.PublicKey {
        guard keyType == .ed25519 else {
            throw PublicKeyError.keyTypeMismatch(expected: .ed25519, actual: keyType)
        }
        return try Curve25519.Signing.PublicKey(rawRepresentation: rawBytes)
    }

    // MARK: - ECDSA P-256

    /// Creates an ECDSA P-256 public key from a P256 signing key.
    ///
    /// - Parameter key: The ECDSA P-256 public key
    public init(ecdsa key: P256.Signing.PublicKey) {
        self.keyType = .ecdsa
        // Use uncompressed representation (65 bytes) for compatibility
        self.rawBytes = Data(key.x963Representation)

        // Pre-compute protobuf encoding
        var encoded = Data()
        encoded.append(0x08)
        encoded.append(contentsOf: Varint.encode(KeyType.ecdsa.rawValue))
        encoded.append(0x12)
        encoded.append(contentsOf: Varint.encode(UInt64(self.rawBytes.count)))
        encoded.append(self.rawBytes)
        self._protobufEncoded = encoded
    }

    /// Returns this key as a P256 signing public key, if applicable.
    ///
    /// - Throws: `PublicKeyError.keyTypeMismatch` if this is not an ECDSA key
    public func ecdsaKey() throws -> P256.Signing.PublicKey {
        guard keyType == .ecdsa else {
            throw PublicKeyError.keyTypeMismatch(expected: .ecdsa, actual: keyType)
        }
        // Handle both compressed (33 bytes) and uncompressed (65 bytes) formats
        if rawBytes.count == 65 {
            return try P256.Signing.PublicKey(x963Representation: rawBytes)
        } else {
            return try P256.Signing.PublicKey(compressedRepresentation: rawBytes)
        }
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
        switch keyType {
        case .ed25519:
            let key = try ed25519Key()
            return key.isValidSignature(signature, for: data)

        case .ecdsa:
            let key = try ecdsaKey()
            // Signature is DER encoded
            let ecdsaSignature = try P256.Signing.ECDSASignature(derRepresentation: signature)
            return key.isValidSignature(ecdsaSignature, for: data)

        case .secp256k1, .rsa:
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
        var remaining = data
        var keyType: KeyType?
        var keyData: Data?

        while !remaining.isEmpty {
            let (fieldTag, fieldBytes) = try Varint.decode(remaining)
            remaining = remaining.dropFirst(fieldBytes)

            let fieldNumber = fieldTag >> 3
            let wireType = fieldTag & 0x07

            switch (fieldNumber, wireType) {
            case (1, 0): // KeyType varint
                let (typeValue, typeBytes) = try Varint.decode(remaining)
                remaining = remaining.dropFirst(typeBytes)
                guard let type = KeyType(rawValue: typeValue) else {
                    throw PublicKeyError.unknownKeyType(typeValue)
                }
                keyType = type

            case (2, 2): // Data length-delimited
                let (length, lengthBytes) = try Varint.decode(remaining)
                remaining = remaining.dropFirst(lengthBytes)
                // Bounds check: prevent DoS from huge length values
                // Public keys are typically 32-256 bytes, 4KB is more than enough
                guard length <= 4096 else {
                    throw PublicKeyError.keyDataTooLarge(length)
                }
                let keyLength = Int(length)
                guard remaining.count >= keyLength else {
                    throw PublicKeyError.invalidProtobuf
                }
                keyData = Data(remaining.prefix(keyLength))
                remaining = remaining.dropFirst(keyLength)

            default:
                throw PublicKeyError.invalidProtobuf
            }
        }

        guard let type = keyType, let data = keyData else {
            throw PublicKeyError.invalidProtobuf
        }

        try self.init(keyType: type, rawBytes: data)
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
