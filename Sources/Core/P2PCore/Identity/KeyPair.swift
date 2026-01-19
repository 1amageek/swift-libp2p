/// Key pair combining a private and public key.

import Foundation
import Crypto

/// A cryptographic key pair for signing and verification.
public struct KeyPair: Sendable {

    /// The private key.
    public let privateKey: PrivateKey

    /// The public key.
    public var publicKey: PublicKey {
        privateKey.publicKey
    }

    /// The key type.
    public var keyType: KeyType {
        privateKey.keyType
    }

    // MARK: - Key Generation

    /// Creates a new random Ed25519 key pair.
    public static func generateEd25519() -> KeyPair {
        let privateKey = PrivateKey.generateEd25519()
        return KeyPair(privateKey: privateKey)
    }

    /// Creates a new random ECDSA P-256 key pair.
    public static func generateECDSA() -> KeyPair {
        let privateKey = PrivateKey.generateECDSA()
        return KeyPair(privateKey: privateKey)
    }

    /// Creates a key pair from a private key.
    ///
    /// - Parameter privateKey: The private key
    public init(privateKey: PrivateKey) {
        self.privateKey = privateKey
    }

    /// Creates a key pair from raw private key bytes.
    ///
    /// - Parameters:
    ///   - keyType: The type of the key
    ///   - rawBytes: The raw private key bytes
    /// - Throws: `PrivateKeyError` if the bytes are invalid
    public init(keyType: KeyType, rawBytes: Data) throws {
        self.privateKey = try PrivateKey(keyType: keyType, rawBytes: rawBytes)
    }

    /// Signs data with this key pair.
    ///
    /// - Parameter data: The data to sign
    /// - Returns: The signature
    /// - Throws: `PrivateKeyError` if signing fails
    public func sign(_ data: Data) throws -> Data {
        try privateKey.sign(data)
    }

    /// Verifies a signature with this key pair's public key.
    ///
    /// - Parameters:
    ///   - signature: The signature to verify
    ///   - data: The data that was signed
    /// - Returns: `true` if the signature is valid
    /// - Throws: `PublicKeyError` if verification cannot be performed
    public func verify(signature: Data, for data: Data) throws -> Bool {
        try publicKey.verify(signature: signature, for: data)
    }

    /// The PeerID derived from this key pair's public key.
    public var peerID: PeerID {
        PeerID(publicKey: publicKey)
    }
}
