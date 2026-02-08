/// AutoTLS - Automatic TLS certificate generation and rotation for libp2p peer identities
///
/// Generates self-signed X.509 certificates with the libp2p extension
/// (OID 1.3.6.1.4.1.53594.1.1) and manages automatic rotation before expiry.
///
/// Thread-safe via `Mutex` — suitable for high-frequency certificate access.

import Foundation
import Crypto
import P2PCore
import P2PCertificate
import Synchronization

/// Manages automatic TLS certificate generation and rotation for libp2p identities.
///
/// Certificates are cached per key pair and automatically rotated before expiry
/// based on the configured rotation buffer.
///
/// ## Usage
///
/// ```swift
/// let autoTLS = AutoTLS()
/// let cert = try autoTLS.currentCertificate(for: keyPair)
/// // cert is cached and auto-rotated when nearing expiry
/// ```
public final class AutoTLS: Sendable {

    /// Configuration for certificate generation and rotation.
    public struct Configuration: Sendable {
        /// How long a certificate is considered valid. Default: 24 hours.
        public var certificateLifetime: Duration

        /// How long before expiry to trigger rotation. Default: 1 hour.
        /// A certificate is rotated when the remaining validity is less than this buffer.
        public var rotationBuffer: Duration

        /// Creates an AutoTLS configuration.
        ///
        /// - Parameters:
        ///   - certificateLifetime: Certificate validity duration (default: 24 hours)
        ///   - rotationBuffer: Time before expiry to rotate (default: 1 hour)
        public init(
            certificateLifetime: Duration = .seconds(24 * 3600),
            rotationBuffer: Duration = .seconds(3600)
        ) {
            self.certificateLifetime = certificateLifetime
            self.rotationBuffer = rotationBuffer
        }
    }

    private let configuration: Configuration
    private let state: Mutex<AutoTLSState>

    private struct AutoTLSState: Sendable {
        /// Cached certificates keyed by PeerID description (stable identifier).
        var certificates: [String: CertificateInfo] = [:]
    }

    /// Creates an AutoTLS manager.
    ///
    /// - Parameter configuration: Configuration for certificate lifetime and rotation
    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
        self.state = Mutex(AutoTLSState())
    }

    /// Generate a new libp2p TLS certificate for the given key pair.
    ///
    /// The certificate encodes the peer ID in the libp2p extension
    /// (OID 1.3.6.1.4.1.53594.1.1). Each call generates a fresh certificate
    /// with a new ephemeral P-256 key.
    ///
    /// - Parameter keyPair: The libp2p identity key pair
    /// - Returns: Certificate information including DER-encoded chain and private key
    public func generateCertificate(for keyPair: KeyPair) throws -> CertificateInfo {
        let generated = try LibP2PCertificate.generate(keyPair: keyPair)

        let now = Date()
        let lifetimeSeconds = Double(configuration.certificateLifetime.components.seconds)
            + Double(configuration.certificateLifetime.components.attoseconds) / 1e18
        let notBefore = now
        let notAfter = now.addingTimeInterval(lifetimeSeconds)

        // Compute SHA-256 fingerprint of the DER-encoded certificate
        let fingerprint = computeFingerprint(of: generated.certificateDER)

        // Serialize the P-256 private key to DER (PKCS#8)
        let privateKeyDER = generated.privateKey.derRepresentation

        return CertificateInfo(
            certificateChain: [UInt8](generated.certificateDER),
            privateKey: [UInt8](privateKeyDER),
            peerID: keyPair.peerID,
            notBefore: notBefore,
            notAfter: notAfter,
            fingerprint: fingerprint
        )
    }

    /// Check if a certificate needs rotation based on expiry and rotation buffer.
    ///
    /// A certificate needs rotation when the current time plus the rotation buffer
    /// exceeds the certificate's expiry time.
    ///
    /// - Parameter cert: The certificate to check
    /// - Returns: `true` if the certificate should be rotated
    public func certificateNeedsRotation(_ cert: CertificateInfo) -> Bool {
        let now = Date()
        let bufferSeconds = Double(configuration.rotationBuffer.components.seconds)
            + Double(configuration.rotationBuffer.components.attoseconds) / 1e18
        let rotationDeadline = cert.notAfter.addingTimeInterval(-bufferSeconds)
        return now >= rotationDeadline
    }

    /// Get or create a certificate, auto-rotating if expired or nearing expiry.
    ///
    /// Returns the cached certificate if still valid, otherwise generates a new one.
    /// The new certificate is cached for subsequent calls.
    ///
    /// The entire check-and-generate operation is performed within a single lock
    /// scope to prevent a TOCTOU race where two concurrent callers both see a
    /// stale/missing cache entry and redundantly generate certificates.
    ///
    /// - Parameter keyPair: The libp2p identity key pair
    /// - Returns: A valid certificate (either cached or freshly generated)
    public func currentCertificate(for keyPair: KeyPair) throws -> CertificateInfo {
        try state.withLock { state -> CertificateInfo in
            let peerKey = keyPair.peerID.description

            // Return cached certificate if still valid
            if let cached = state.certificates[peerKey],
               !certificateNeedsRotation(cached) {
                return cached
            }

            // Generate a new certificate and cache it (all within the same lock scope).
            // generateCertificate only reads self.configuration (immutable) so this is safe.
            let newCert = try generateCertificate(for: keyPair)
            state.certificates[peerKey] = newCert
            return newCert
        }
    }

    /// Force rotation of the cached certificate.
    ///
    /// Generates a new certificate regardless of the current certificate's validity
    /// and updates the cache.
    ///
    /// - Parameter keyPair: The libp2p identity key pair
    /// - Returns: A freshly generated certificate
    @discardableResult
    public func rotateCertificate(for keyPair: KeyPair) throws -> CertificateInfo {
        let newCert = try generateCertificate(for: keyPair)
        let peerKey = keyPair.peerID.description
        state.withLock { state in
            state.certificates[peerKey] = newCert
        }
        return newCert
    }

    // MARK: - Private

    /// Computes the SHA-256 fingerprint of DER-encoded certificate data.
    private func computeFingerprint(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined(separator: ":")
    }
}

/// Information about a generated libp2p TLS certificate.
public struct CertificateInfo: Sendable {
    /// DER-encoded certificate chain (single self-signed certificate).
    public let certificateChain: [UInt8]

    /// DER-encoded private key (PKCS#8 P-256).
    public let privateKey: [UInt8]

    /// The PeerID this certificate belongs to.
    public let peerID: PeerID

    /// Certificate validity start time.
    public let notBefore: Date

    /// Certificate validity end time.
    public let notAfter: Date

    /// SHA-256 fingerprint of the DER-encoded certificate (colon-separated hex).
    public let fingerprint: String
}
