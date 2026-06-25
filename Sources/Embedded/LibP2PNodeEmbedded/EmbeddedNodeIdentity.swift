// EmbeddedNodeIdentity.swift
// The local libp2p identity for the Embedded node: an Ed25519 signing key plus its
// protobuf-encoded public key. Used by the Noise upgrader to sign the static-key
// proof and to advertise the local identity in the handshake payload.
// Embedded-clean: generic over `C: CryptoProvider`, `[UInt8]` currency, no `any`.

import P2PCoreBytes
import P2PCoreCrypto
import LibP2PCore

/// The local node's libp2p identity, specialised at the crypto seam `C`.
///
/// The minimal node identifies with an Ed25519 key (libp2p key type 1). It holds
/// the signing key (to prove ownership of the Noise static key) and the
/// protobuf-encoded public key (the identity advertised in the Noise payload, and
/// the basis of the local PeerID).
public struct EmbeddedNodeIdentity<C: CryptoProvider>: Sendable {

    /// The Ed25519 signing key.
    public let signingKey: C.Ed25519.SigningKey

    /// The libp2p `PublicKey` protobuf bytes (keyType 1 || raw Ed25519 key).
    public let protobufPublicKey: [UInt8]

    /// Wraps an existing Ed25519 signing key.
    public init(signingKey: C.Ed25519.SigningKey) {
        self.signingKey = signingKey
        let verifying = C.Ed25519.verifyingKey(for: signingKey)
        let raw = C.Ed25519.rawRepresentation(of: verifying)
        self.protobufPublicKey = PublicKeyProtobuf.encode(
            keyType: LibP2PIdentityKeyType.ed25519.rawValue, keyData: raw
        )
    }

    /// Generates a fresh Ed25519 identity through the crypto seam.
    ///
    /// - Throws: ``EmbeddedNodeError/noiseHandshakeFailed`` if key generation fails
    ///   in the backend (surfaced as a node error so callers fail-closed).
    public static func generate() throws(EmbeddedNodeError) -> EmbeddedNodeIdentity<C> {
        let key: C.Ed25519.SigningKey
        do {
            key = try C.Ed25519.generateSigningKey()
        } catch {
            throw .noiseHandshakeFailed
        }
        return EmbeddedNodeIdentity(signingKey: key)
    }

    /// Signs `message` with the identity key.
    ///
    /// - Throws: ``EmbeddedNodeError/noiseHandshakeFailed`` if signing fails.
    func sign(_ message: [UInt8]) throws(EmbeddedNodeError) -> [UInt8] {
        do {
            return try C.Ed25519.sign(message.span, with: signingKey)
        } catch {
            throw .noiseHandshakeFailed
        }
    }
}
