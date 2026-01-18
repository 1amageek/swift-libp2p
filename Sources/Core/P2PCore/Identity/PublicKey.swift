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
            guard rawBytes.count == 33 || rawBytes.count == 65 else {
                throw PublicKeyError.invalidKeySize(expected: 33, actual: rawBytes.count)
            }
        case .rsa:
            // RSA keys are variable length
            guard !rawBytes.isEmpty else {
                throw PublicKeyError.invalidKeySize(expected: 1, actual: 0)
            }
        }
    }

    /// Creates an Ed25519 public key from a Curve25519 signing key.
    ///
    /// - Parameter key: The Ed25519 public key
    public init(ed25519 key: Curve25519.Signing.PublicKey) {
        self.keyType = .ed25519
        self.rawBytes = Data(key.rawRepresentation)
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
        case .secp256k1, .ecdsa, .rsa:
            throw PublicKeyError.unsupportedOperation
        }
    }

    /// The PeerID derived from this public key.
    public var peerID: PeerID {
        PeerID(publicKey: self)
    }

    /// The protobuf-encoded representation of this public key.
    ///
    /// Format: KeyType (varint) + key data
    public var protobufEncoded: Data {
        // Simple protobuf encoding:
        // Field 1 (KeyType): varint
        // Field 2 (Data): length-delimited bytes
        var result = Data()

        // Field 1: KeyType (field number 1, wire type 0 = varint)
        result.append(0x08) // (1 << 3) | 0
        result.append(contentsOf: Varint.encode(keyType.rawValue))

        // Field 2: Data (field number 2, wire type 2 = length-delimited)
        result.append(0x12) // (2 << 3) | 2
        result.append(contentsOf: Varint.encode(UInt64(rawBytes.count)))
        result.append(rawBytes)

        return result
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
