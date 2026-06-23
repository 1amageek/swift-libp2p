/// Key-agreement primitives for the `NoiseFoundationProvider` seam.
///
/// swift-crypto / CryptoKit backend. Noise XX uses only ``NoiseFoundationX25519``
/// (32-byte raw private + public encodings, 32-byte shared secret); the P-256 /
/// P-384 conformances are provided so the aggregate `CryptoProvider` is complete.
///
/// Key-agreement failure throws ``P2PCoreCrypto/CryptoError/keyAgreementFailure``
/// (no silent fallback).

import Crypto
import P2PCoreBytes
import P2PCoreCrypto

/// X25519 key agreement over swift-crypto.
public enum NoiseFoundationX25519: P2PCoreCrypto.KeyAgreement {
    public struct PrivateKey: Sendable {
        let key: Curve25519.KeyAgreement.PrivateKey
    }
    public struct PublicKey: Sendable {
        let key: Curve25519.KeyAgreement.PublicKey
    }

    public static func generatePrivateKey() throws(P2PCoreCrypto.CryptoError) -> PrivateKey {
        PrivateKey(key: Curve25519.KeyAgreement.PrivateKey())
    }
    public static func privateKey(rawRepresentation: Span<UInt8>) throws(P2PCoreCrypto.CryptoError) -> PrivateKey {
        do {
            return PrivateKey(key: try Curve25519.KeyAgreement.PrivateKey(
                rawRepresentation: rawRepresentation.providerData()))
        } catch {
            throw .invalidLength(expected: 32, actual: rawRepresentation.count)
        }
    }
    public static func publicKey(rawRepresentation: Span<UInt8>) throws(P2PCoreCrypto.CryptoError) -> PublicKey {
        do {
            return PublicKey(key: try Curve25519.KeyAgreement.PublicKey(
                rawRepresentation: rawRepresentation.providerData()))
        } catch {
            throw .invalidLength(expected: 32, actual: rawRepresentation.count)
        }
    }
    public static func publicKey(for privateKey: PrivateKey) -> PublicKey {
        PublicKey(key: privateKey.key.publicKey)
    }
    public static func rawRepresentation(of privateKey: PrivateKey) -> [UInt8] {
        [UInt8](privateKey.key.rawRepresentation)
    }
    public static func rawRepresentation(of publicKey: PublicKey) -> [UInt8] {
        [UInt8](publicKey.key.rawRepresentation)
    }
    public static func sharedSecret(
        privateKey: PrivateKey, peerPublicKey: PublicKey
    ) throws(P2PCoreCrypto.CryptoError) -> [UInt8] {
        do {
            let secret = try privateKey.key.sharedSecretFromKeyAgreement(with: peerPublicKey.key)
            return secret.withUnsafeBytes { [UInt8]($0) }
        } catch {
            throw .keyAgreementFailure
        }
    }
}

/// P-256 ECDH over swift-crypto (not used by Noise; provider completeness).
public enum NoiseFoundationP256Agreement: P2PCoreCrypto.KeyAgreement {
    public struct PrivateKey: Sendable {
        let key: P256.KeyAgreement.PrivateKey
    }
    public struct PublicKey: Sendable {
        let key: P256.KeyAgreement.PublicKey
    }

    public static func generatePrivateKey() throws(P2PCoreCrypto.CryptoError) -> PrivateKey {
        PrivateKey(key: P256.KeyAgreement.PrivateKey())
    }
    public static func privateKey(rawRepresentation: Span<UInt8>) throws(P2PCoreCrypto.CryptoError) -> PrivateKey {
        do {
            return PrivateKey(key: try P256.KeyAgreement.PrivateKey(
                rawRepresentation: rawRepresentation.providerData()))
        } catch {
            throw .invalidLength(expected: 32, actual: rawRepresentation.count)
        }
    }
    public static func publicKey(rawRepresentation: Span<UInt8>) throws(P2PCoreCrypto.CryptoError) -> PublicKey {
        do {
            return PublicKey(key: try P256.KeyAgreement.PublicKey(
                x963Representation: rawRepresentation.providerData()))
        } catch {
            throw .invalidLength(expected: 65, actual: rawRepresentation.count)
        }
    }
    public static func publicKey(for privateKey: PrivateKey) -> PublicKey {
        PublicKey(key: privateKey.key.publicKey)
    }
    public static func rawRepresentation(of privateKey: PrivateKey) -> [UInt8] {
        [UInt8](privateKey.key.rawRepresentation)
    }
    public static func rawRepresentation(of publicKey: PublicKey) -> [UInt8] {
        [UInt8](publicKey.key.x963Representation)
    }
    public static func sharedSecret(
        privateKey: PrivateKey, peerPublicKey: PublicKey
    ) throws(P2PCoreCrypto.CryptoError) -> [UInt8] {
        do {
            let secret = try privateKey.key.sharedSecretFromKeyAgreement(with: peerPublicKey.key)
            return secret.withUnsafeBytes { [UInt8]($0) }
        } catch {
            throw .keyAgreementFailure
        }
    }
}

/// P-384 ECDH over swift-crypto (not used by Noise; provider completeness).
public enum NoiseFoundationP384Agreement: P2PCoreCrypto.KeyAgreement {
    public struct PrivateKey: Sendable {
        let key: P384.KeyAgreement.PrivateKey
    }
    public struct PublicKey: Sendable {
        let key: P384.KeyAgreement.PublicKey
    }

    public static func generatePrivateKey() throws(P2PCoreCrypto.CryptoError) -> PrivateKey {
        PrivateKey(key: P384.KeyAgreement.PrivateKey())
    }
    public static func privateKey(rawRepresentation: Span<UInt8>) throws(P2PCoreCrypto.CryptoError) -> PrivateKey {
        do {
            return PrivateKey(key: try P384.KeyAgreement.PrivateKey(
                rawRepresentation: rawRepresentation.providerData()))
        } catch {
            throw .invalidLength(expected: 48, actual: rawRepresentation.count)
        }
    }
    public static func publicKey(rawRepresentation: Span<UInt8>) throws(P2PCoreCrypto.CryptoError) -> PublicKey {
        do {
            return PublicKey(key: try P384.KeyAgreement.PublicKey(
                x963Representation: rawRepresentation.providerData()))
        } catch {
            throw .invalidLength(expected: 97, actual: rawRepresentation.count)
        }
    }
    public static func publicKey(for privateKey: PrivateKey) -> PublicKey {
        PublicKey(key: privateKey.key.publicKey)
    }
    public static func rawRepresentation(of privateKey: PrivateKey) -> [UInt8] {
        [UInt8](privateKey.key.rawRepresentation)
    }
    public static func rawRepresentation(of publicKey: PublicKey) -> [UInt8] {
        [UInt8](publicKey.key.x963Representation)
    }
    public static func sharedSecret(
        privateKey: PrivateKey, peerPublicKey: PublicKey
    ) throws(P2PCoreCrypto.CryptoError) -> [UInt8] {
        do {
            let secret = try privateKey.key.sharedSecretFromKeyAgreement(with: peerPublicKey.key)
            return secret.withUnsafeBytes { [UInt8]($0) }
        } catch {
            throw .keyAgreementFailure
        }
    }
}
