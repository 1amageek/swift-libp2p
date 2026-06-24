/// TLSCertificateHelper - Thin TLS facade wrapper over LibP2PCertificate
///
/// Delegates certificate generation and PeerID extraction to the shared
/// P2PCertificate module, wrapping results in the swift-tls Tier-1 `TLS` facade
/// types (`TLSIdentity`, `Certificate`).

import Foundation
import P2PCore
import P2PCertificate
import TLS

/// TLS-facade wrapper for libp2p certificate operations.
///
/// Delegates to `LibP2PCertificate` (P2PCertificate module) for the actual
/// certificate generation and PeerID extraction, then wraps results in the
/// `TLS` facade currency types (`TLSIdentity` carrying the ECDSA P-256 signing
/// key + DER leaf, `Certificate` for the validator chain).
public enum TLSCertificateHelper {

    /// Generates a self-signed X.509 certificate with the libp2p extension,
    /// returning the result as a `TLS` facade identity.
    ///
    /// The ephemeral certificate key is ECDSA P-256 (libp2p TLS convention); the
    /// facade `TLSIdentity` carries its raw 32-byte private scalar plus the DER
    /// leaf certificate.
    ///
    /// - Parameter keyPair: The libp2p identity key pair.
    /// - Returns: A `TLSIdentity` for the local endpoint.
    public static func makeIdentity(keyPair: KeyPair) throws -> TLSIdentity {
        let cert = try LibP2PCertificate.generate(keyPair: keyPair)
        // The libp2p TLS leaf uses an ephemeral ECDSA P-256 key; the facade
        // wants the raw 32-byte private scalar (`rawRepresentation`), not the
        // PKCS#8/DER encoding.
        let rawPrivateKey = [UInt8](cert.privateKey.rawRepresentation)
        return TLSIdentity(
            privateKey: rawPrivateKey,
            keyType: .ecdsaP256,
            certificateChain: [Certificate(der: [UInt8](cert.certificateDER))]
        )
    }

    /// Creates a `certificateValidator` callback for the facade `TLSConfiguration`.
    ///
    /// The returned callback validates the libp2p extension in the peer's
    /// certificate and re-derives the PeerID, surfacing it as the `PeerIdentity`
    /// identifier bytes (the PeerID's binary multihash). It throws (aborting the
    /// handshake) when the leaf is missing, the libp2p extension/signature is
    /// invalid, or the peer's identity does not match `expectedPeer` — never
    /// silently accepting an unauthenticated peer.
    ///
    /// - Parameter expectedPeer: Optional expected PeerID to verify against.
    /// - Returns: A facade certificate-validator closure.
    public static func makeCertificateValidator(
        expectedPeer: PeerID?
    ) -> (@Sendable ([Certificate]) throws(TLS.TLSError) -> PeerIdentity?) {
        return { (certChain: [Certificate]) throws(TLS.TLSError) -> PeerIdentity? in
            guard let leaf = certChain.first else {
                throw .verificationFailed(reason: "missing libp2p leaf certificate")
            }

            let peerID: PeerID
            do {
                peerID = try LibP2PCertificate.extractPeerID(from: Data(leaf.der))
            } catch {
                throw .verificationFailed(reason: "libp2p certificate extension invalid: \(error)")
            }

            if let expected = expectedPeer, expected != peerID {
                throw .verificationFailed(
                    reason: "peer ID mismatch: expected \(expected), got \(peerID)"
                )
            }

            return PeerIdentity(identifier: [UInt8](peerID.bytes), certificates: [leaf])
        }
    }
}
