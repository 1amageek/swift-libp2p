/// Error types for libp2p TLS certificate handling.

import Foundation
import P2PCore

/// Errors related to TLS certificate operations.
///
/// These errors can occur during certificate generation, parsing,
/// or verification in the libp2p TLS handshake.
public enum TLSCertificateError: Error, Sendable {
    /// Certificate generation failed.
    case certificateGenerationFailed(underlying: any Error)

    /// Certificate parsing failed.
    case certificateParsingFailed(reason: String)

    /// The certificate is missing the libp2p extension.
    case missingLibp2pExtension

    /// The libp2p extension signature is invalid.
    case invalidExtensionSignature

    /// PeerID mismatch with expected peer.
    case peerIDMismatch(expected: PeerID, actual: PeerID)

    /// Certificate is not self-signed.
    case notSelfSigned

    /// Certificate chain has more than one certificate.
    case multipleCertificates

    /// ALPN negotiation failed.
    case alpnNegotiationFailed

    /// Certificate validity period check failed.
    case certificateExpired

    /// Certificate is not yet valid.
    case certificateNotYetValid

    /// Unsupported key type in certificate.
    case unsupportedKeyType(String)

    /// Invalid public key in libp2p extension.
    case invalidPublicKey(reason: String)

    /// ASN.1 encoding/decoding error.
    case asn1Error(reason: String)

    /// TLS handshake failed.
    case handshakeFailed(reason: String, underlying: (any Error)? = nil)
}

extension TLSCertificateError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .certificateGenerationFailed(let error):
            return "Certificate generation failed: \(error)"
        case .certificateParsingFailed(let reason):
            return "Certificate parsing failed: \(reason)"
        case .missingLibp2pExtension:
            return "Certificate is missing the libp2p extension (OID 1.3.6.1.4.1.53594.1.1)"
        case .invalidExtensionSignature:
            return "The libp2p extension signature is invalid"
        case .peerIDMismatch(let expected, let actual):
            return "PeerID mismatch: expected \(expected), got \(actual)"
        case .notSelfSigned:
            return "Certificate must be self-signed"
        case .multipleCertificates:
            return "Certificate chain must contain exactly one certificate"
        case .alpnNegotiationFailed:
            return "ALPN negotiation failed (expected 'libp2p')"
        case .certificateExpired:
            return "Certificate has expired"
        case .certificateNotYetValid:
            return "Certificate is not yet valid"
        case .unsupportedKeyType(let keyType):
            return "Unsupported key type: \(keyType)"
        case .invalidPublicKey(let reason):
            return "Invalid public key: \(reason)"
        case .asn1Error(let reason):
            return "ASN.1 error: \(reason)"
        case .handshakeFailed(let reason, let underlying):
            if let error = underlying {
                return "TLS handshake failed: \(reason) (\(error))"
            }
            return "TLS handshake failed: \(reason)"
        }
    }
}
