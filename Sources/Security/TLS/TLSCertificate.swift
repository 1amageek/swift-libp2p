/// TLSCertificateHelper - Thin TLS wrapper over LibP2PCertificate
///
/// Delegates certificate generation and PeerID extraction to the shared
/// P2PCertificate module, wrapping results in TLSCore types.

import Foundation
import P2PCore
import P2PCertificate
import TLSCore

/// TLS-specific wrapper for libp2p certificate operations.
///
/// Delegates to `LibP2PCertificate` (P2PCertificate module) for the actual
/// certificate generation and PeerID extraction, then wraps results in
/// TLSCore types (`SigningKey`, `CertificateValidator`).
public enum TLSCertificateHelper {

    /// Generates a self-signed X.509 certificate with libp2p extension,
    /// returning the result in TLS-compatible types.
    ///
    /// - Parameter keyPair: The libp2p identity key pair
    /// - Returns: Certificate chain (DER) and TLSCore signing key
    public static func generate(keyPair: KeyPair) throws -> (certificateChain: [Data], signingKey: TLSCore.SigningKey) {
        let cert = try LibP2PCertificate.generate(keyPair: keyPair)
        return (
            certificateChain: [cert.certificateDER],
            signingKey: .p256(cert.privateKey)
        )
    }

    /// Creates a `CertificateValidator` callback for swift-tls configuration.
    ///
    /// The returned callback validates the libp2p extension in the peer's certificate
    /// and extracts the PeerID. The PeerID is returned as the `Sendable` value,
    /// accessible via `TLSConnection.validatedPeerInfo`.
    ///
    /// - Parameter expectedPeer: Optional expected PeerID to verify against
    /// - Returns: A CertificateValidator closure
    public static func makeCertificateValidator(expectedPeer: PeerID?) -> CertificateValidator {
        return { (certChain: [Data]) throws -> (any Sendable)? in
            guard let leafDER = certChain.first else {
                throw TLSError.missingLibP2PExtension
            }

            let peerID: PeerID
            do {
                peerID = try LibP2PCertificate.extractPeerID(from: leafDER)
            } catch is LibP2PCertificateError {
                throw TLSError.missingLibP2PExtension
            }

            if let expected = expectedPeer, expected != peerID {
                throw TLSError.peerIDMismatch(
                    expected: expected.description,
                    actual: peerID.description
                )
            }

            return peerID
        }
    }
}
