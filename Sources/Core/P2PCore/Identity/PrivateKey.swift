/// Private key representation for libp2p.

import Foundation
import Crypto

/// A private key used for signing and key derivation.
public struct PrivateKey: Sendable {

    /// The type of this key.
    public let keyType: KeyType

    /// The raw private key bytes.
    public let rawBytes: Data

    /// The corresponding public key.
    public let publicKey: PublicKey

    /// Pre-constructed CryptoKit key, populated at init.
    /// Avoids reconstructing the key on every sign() call (hot path).
    private let _cryptoKey: CryptoSigningKey

    // MARK: - Ed25519

    /// Creates a new random Ed25519 private key.
    public static func generateEd25519() -> PrivateKey {
        let key = Curve25519.Signing.PrivateKey()
        return PrivateKey(ed25519: key)
    }

    /// Creates a private key from a Curve25519 signing key.
    ///
    /// - Parameter key: The Ed25519 private key
    public init(ed25519 key: Curve25519.Signing.PrivateKey) {
        self.keyType = .ed25519
        self.rawBytes = Data(key.rawRepresentation)
        self.publicKey = PublicKey(ed25519: key.publicKey)
        self._cryptoKey = .ed25519(key)
    }

    // MARK: - ECDSA P-256

    /// Creates a new random ECDSA P-256 private key.
    public static func generateECDSA() -> PrivateKey {
        let key = P256.Signing.PrivateKey()
        return PrivateKey(ecdsa: key)
    }

    /// Creates a private key from a P256 signing key.
    ///
    /// - Parameter key: The ECDSA P-256 private key
    public init(ecdsa key: P256.Signing.PrivateKey) {
        self.keyType = .ecdsa
        self.rawBytes = Data(key.rawRepresentation)
        self.publicKey = PublicKey(ecdsa: key.publicKey)
        self._cryptoKey = .ecdsa(key)
    }

    // MARK: - Raw Bytes Initialization

    /// Creates a private key from raw bytes.
    ///
    /// - Parameters:
    ///   - keyType: The type of the key
    ///   - rawBytes: The raw private key bytes
    /// - Throws: `PrivateKeyError` if the bytes are invalid
    public init(keyType: KeyType, rawBytes: Data) throws {
        self.keyType = keyType
        self.rawBytes = rawBytes

        switch keyType {
        case .ed25519:
            guard rawBytes.count == 32 else {
                throw PrivateKeyError.invalidKeySize(expected: 32, actual: rawBytes.count)
            }
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: rawBytes)
            self.publicKey = PublicKey(ed25519: key.publicKey)
            self._cryptoKey = .ed25519(key)

        case .ecdsa:
            // P-256 private key is 32 bytes
            guard rawBytes.count == 32 else {
                throw PrivateKeyError.invalidKeySize(expected: 32, actual: rawBytes.count)
            }
            let key = try P256.Signing.PrivateKey(rawRepresentation: rawBytes)
            self.publicKey = PublicKey(ecdsa: key.publicKey)
            self._cryptoKey = .ecdsa(key)

        case .secp256k1, .rsa:
            throw PrivateKeyError.unsupportedKeyType(keyType)
        }
    }

    // MARK: - Key Accessors

    /// Returns this key as a Curve25519 signing private key, if applicable.
    ///
    /// - Throws: `PrivateKeyError.keyTypeMismatch` if this is not an Ed25519 key
    public func ed25519Key() throws -> Curve25519.Signing.PrivateKey {
        guard case let .ed25519(key) = _cryptoKey else {
            throw PrivateKeyError.keyTypeMismatch(expected: .ed25519, actual: keyType)
        }
        return key
    }

    /// Returns this key as a P256 signing private key, if applicable.
    ///
    /// - Throws: `PrivateKeyError.keyTypeMismatch` if this is not an ECDSA key
    public func ecdsaKey() throws -> P256.Signing.PrivateKey {
        guard case let .ecdsa(key) = _cryptoKey else {
            throw PrivateKeyError.keyTypeMismatch(expected: .ecdsa, actual: keyType)
        }
        return key
    }

    // MARK: - Signing

    /// Signs data with this private key.
    ///
    /// - Parameter data: The data to sign
    /// - Returns: The signature
    /// - Throws: `PrivateKeyError` if signing fails
    public func sign(_ data: Data) throws -> Data {
        switch _cryptoKey {
        case .ed25519(let key):
            let signature = try key.signature(for: data)
            return Data(signature)

        case .ecdsa(let key):
            let signature = try key.signature(for: data)
            // Use DER representation for libp2p compatibility
            return Data(signature.derRepresentation)
        }
    }

    /// The protobuf-encoded representation of this private key.
    public var protobufEncoded: Data {
        var result = Data()

        // Field 1: KeyType
        result.append(0x08)
        result.append(contentsOf: Varint.encode(keyType.rawValue))

        // Field 2: Data
        result.append(0x12)
        result.append(contentsOf: Varint.encode(UInt64(rawBytes.count)))
        result.append(rawBytes)

        return result
    }
}

// MARK: - Cached CryptoKit key wrapper

/// Internal enum holding the constructed CryptoKit private key.
/// Constructed once at PrivateKey init to avoid rebuilding on every sign().
private enum CryptoSigningKey: Sendable {
    case ed25519(Curve25519.Signing.PrivateKey)
    case ecdsa(P256.Signing.PrivateKey)
}

public enum PrivateKeyError: Error, Equatable {
    case invalidKeySize(expected: Int, actual: Int)
    case keyTypeMismatch(expected: KeyType, actual: KeyType)
    case unsupportedKeyType(KeyType)
    case unsupportedOperation
    case signingFailed
}
