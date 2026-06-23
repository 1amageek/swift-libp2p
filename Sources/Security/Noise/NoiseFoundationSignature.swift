/// Signature primitives for the `NoiseFoundationProvider` seam.
///
/// swift-crypto / CryptoKit backend. The Noise XX state machine does not use these
/// (the libp2p identity signature stays adapter-side via `P2PCore`'s multi-scheme
/// keys); they are provided so the aggregate `CryptoProvider` is complete.
///
/// A signing failure throws ``P2PCoreCrypto/CryptoError/providerFailure``; an
/// invalid signature is an explicit `false` from `isValid` (no silent fallback).

import Crypto
import P2PCoreBytes
import P2PCoreCrypto

/// Ed25519 (EdDSA) signatures over swift-crypto.
public enum NoiseFoundationEd25519: P2PCoreCrypto.SignatureScheme {
    public struct SigningKey: Sendable {
        let key: Curve25519.Signing.PrivateKey
    }
    public struct VerifyingKey: Sendable {
        let key: Curve25519.Signing.PublicKey
    }

    public static func generateSigningKey() throws(P2PCoreCrypto.CryptoError) -> SigningKey {
        SigningKey(key: Curve25519.Signing.PrivateKey())
    }
    public static func signingKey(rawRepresentation: Span<UInt8>) throws(P2PCoreCrypto.CryptoError) -> SigningKey {
        do {
            return SigningKey(key: try Curve25519.Signing.PrivateKey(
                rawRepresentation: rawRepresentation.providerData()))
        } catch {
            throw .invalidLength(expected: 32, actual: rawRepresentation.count)
        }
    }
    public static func verifyingKey(rawRepresentation: Span<UInt8>) throws(P2PCoreCrypto.CryptoError) -> VerifyingKey {
        do {
            return VerifyingKey(key: try Curve25519.Signing.PublicKey(
                rawRepresentation: rawRepresentation.providerData()))
        } catch {
            throw .invalidLength(expected: 32, actual: rawRepresentation.count)
        }
    }
    public static func verifyingKey(for signingKey: SigningKey) -> VerifyingKey {
        VerifyingKey(key: signingKey.key.publicKey)
    }
    public static func rawRepresentation(of signingKey: SigningKey) -> [UInt8] {
        [UInt8](signingKey.key.rawRepresentation)
    }
    public static func rawRepresentation(of verifyingKey: VerifyingKey) -> [UInt8] {
        [UInt8](verifyingKey.key.rawRepresentation)
    }
    public static func sign(_ message: Span<UInt8>, with signingKey: SigningKey) throws(P2PCoreCrypto.CryptoError) -> [UInt8] {
        do {
            return [UInt8](try signingKey.key.signature(for: message.providerData()))
        } catch {
            throw .providerFailure
        }
    }
    public static func isValid(
        signature: Span<UInt8>, for message: Span<UInt8>, with verifyingKey: VerifyingKey
    ) -> Bool {
        verifyingKey.key.isValidSignature(signature.providerData(), for: message.providerData())
    }
}

/// ECDSA P-256 signatures over swift-crypto (raw representation).
public enum NoiseFoundationP256Signature: P2PCoreCrypto.SignatureScheme {
    public struct SigningKey: Sendable {
        let key: P256.Signing.PrivateKey
    }
    public struct VerifyingKey: Sendable {
        let key: P256.Signing.PublicKey
    }

    public static func generateSigningKey() throws(P2PCoreCrypto.CryptoError) -> SigningKey {
        SigningKey(key: P256.Signing.PrivateKey())
    }
    public static func signingKey(rawRepresentation: Span<UInt8>) throws(P2PCoreCrypto.CryptoError) -> SigningKey {
        do {
            return SigningKey(key: try P256.Signing.PrivateKey(
                rawRepresentation: rawRepresentation.providerData()))
        } catch {
            throw .invalidLength(expected: 32, actual: rawRepresentation.count)
        }
    }
    public static func verifyingKey(rawRepresentation: Span<UInt8>) throws(P2PCoreCrypto.CryptoError) -> VerifyingKey {
        do {
            return VerifyingKey(key: try P256.Signing.PublicKey(
                x963Representation: rawRepresentation.providerData()))
        } catch {
            throw .invalidLength(expected: 65, actual: rawRepresentation.count)
        }
    }
    public static func verifyingKey(for signingKey: SigningKey) -> VerifyingKey {
        VerifyingKey(key: signingKey.key.publicKey)
    }
    public static func rawRepresentation(of signingKey: SigningKey) -> [UInt8] {
        [UInt8](signingKey.key.rawRepresentation)
    }
    public static func rawRepresentation(of verifyingKey: VerifyingKey) -> [UInt8] {
        [UInt8](verifyingKey.key.x963Representation)
    }
    public static func sign(_ message: Span<UInt8>, with signingKey: SigningKey) throws(P2PCoreCrypto.CryptoError) -> [UInt8] {
        do {
            return [UInt8](try signingKey.key.signature(for: message.providerData()).rawRepresentation)
        } catch {
            throw .providerFailure
        }
    }
    public static func isValid(
        signature: Span<UInt8>, for message: Span<UInt8>, with verifyingKey: VerifyingKey
    ) -> Bool {
        do {
            let sig = try P256.Signing.ECDSASignature(rawRepresentation: signature.providerData())
            return verifyingKey.key.isValidSignature(sig, for: message.providerData())
        } catch {
            return false
        }
    }
}

/// ECDSA P-384 signatures over swift-crypto (raw representation).
public enum NoiseFoundationP384Signature: P2PCoreCrypto.SignatureScheme {
    public struct SigningKey: Sendable {
        let key: P384.Signing.PrivateKey
    }
    public struct VerifyingKey: Sendable {
        let key: P384.Signing.PublicKey
    }

    public static func generateSigningKey() throws(P2PCoreCrypto.CryptoError) -> SigningKey {
        SigningKey(key: P384.Signing.PrivateKey())
    }
    public static func signingKey(rawRepresentation: Span<UInt8>) throws(P2PCoreCrypto.CryptoError) -> SigningKey {
        do {
            return SigningKey(key: try P384.Signing.PrivateKey(
                rawRepresentation: rawRepresentation.providerData()))
        } catch {
            throw .invalidLength(expected: 48, actual: rawRepresentation.count)
        }
    }
    public static func verifyingKey(rawRepresentation: Span<UInt8>) throws(P2PCoreCrypto.CryptoError) -> VerifyingKey {
        do {
            return VerifyingKey(key: try P384.Signing.PublicKey(
                x963Representation: rawRepresentation.providerData()))
        } catch {
            throw .invalidLength(expected: 97, actual: rawRepresentation.count)
        }
    }
    public static func verifyingKey(for signingKey: SigningKey) -> VerifyingKey {
        VerifyingKey(key: signingKey.key.publicKey)
    }
    public static func rawRepresentation(of signingKey: SigningKey) -> [UInt8] {
        [UInt8](signingKey.key.rawRepresentation)
    }
    public static func rawRepresentation(of verifyingKey: VerifyingKey) -> [UInt8] {
        [UInt8](verifyingKey.key.x963Representation)
    }
    public static func sign(_ message: Span<UInt8>, with signingKey: SigningKey) throws(P2PCoreCrypto.CryptoError) -> [UInt8] {
        do {
            return [UInt8](try signingKey.key.signature(for: message.providerData()).rawRepresentation)
        } catch {
            throw .providerFailure
        }
    }
    public static func isValid(
        signature: Span<UInt8>, for message: Span<UInt8>, with verifyingKey: VerifyingKey
    ) -> Bool {
        do {
            let sig = try P384.Signing.ECDSASignature(rawRepresentation: signature.providerData())
            return verifyingKey.key.isValidSignature(sig, for: message.providerData())
        } catch {
            return false
        }
    }
}
