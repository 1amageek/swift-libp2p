/// Deterministic certificate generation for WebTransport.
///
/// WebTransport in browsers requires self-signed certificates with:
/// - Maximum validity of 14 days
/// - SHA-256 certificate hash for verification
///
/// The certificate hash is included in the multiaddr so that browsers
/// can verify the server's identity without relying on the CA system.
///
/// ## Multiaddr Example
///
/// ```
/// /ip4/1.2.3.4/udp/1234/quic-v1/webtransport/certhash/uEi...
/// ```

import Foundation
import Crypto
import P2PCore

/// A deterministic self-signed certificate for WebTransport.
///
/// This certificate is designed for short-lived use (max 14 days) as required
/// by browser WebTransport implementations. The certificate hash is included
/// in the peer's multiaddr for out-of-band verification.
public struct DeterministicCertificate: Sendable {

    /// The SHA-256 hash of the DER-encoded certificate.
    public let certHash: [UInt8]

    /// The certificate hash encoded as a multibase base64url string.
    ///
    /// This is the format used in multiaddr `/certhash/<value>` components,
    /// prefixed with 'u' for base64url multibase encoding.
    public let certHashMultibase: String

    /// The start of the certificate's validity period.
    public let notBefore: Date

    /// The end of the certificate's validity period.
    ///
    /// This must be at most 14 days after `notBefore` for browser compatibility.
    public let notAfter: Date

    /// The DER-encoded certificate bytes.
    public let derEncoded: [UInt8]

    /// Creates a new deterministic certificate.
    ///
    /// - Parameters:
    ///   - certHash: SHA-256 hash of the DER-encoded certificate
    ///   - certHashMultibase: Multibase base64url encoded hash
    ///   - notBefore: Validity start date
    ///   - notAfter: Validity end date
    ///   - derEncoded: DER-encoded certificate bytes
    public init(
        certHash: [UInt8],
        certHashMultibase: String,
        notBefore: Date,
        notAfter: Date,
        derEncoded: [UInt8]
    ) {
        self.certHash = certHash
        self.certHashMultibase = certHashMultibase
        self.notBefore = notBefore
        self.notAfter = notAfter
        self.derEncoded = derEncoded
    }
}

/// Generator for deterministic self-signed certificates used in WebTransport.
///
/// Browsers connecting via WebTransport verify the server's certificate hash
/// against the hash embedded in the multiaddr. This generator creates
/// short-lived certificates with predictable hashes.
///
/// ## Usage
///
/// ```swift
/// let generator = DeterministicCertGenerator()
/// let keyPair = KeyPair.generateEd25519()
/// let cert = try generator.generate(for: keyPair)
///
/// // Use cert.certHashMultibase in multiaddr:
/// // /ip4/.../udp/.../quic-v1/webtransport/certhash/\(cert.certHashMultibase)
/// ```
public struct DeterministicCertGenerator: Sendable {

    /// Creates a new certificate generator.
    public init() {}

    /// Generates a deterministic self-signed certificate for WebTransport.
    ///
    /// The certificate is valid for 12 days (within the 14-day browser limit)
    /// and includes a SHA-256 hash for multiaddr embedding.
    ///
    /// - Parameter keyPair: The key pair to use for signing the certificate
    /// - Returns: A deterministic certificate with its hash
    /// - Throws: An error if certificate generation fails
    ///
    /// - Note: This is a simplified implementation that produces a minimal
    ///   self-signed structure. A full implementation would generate a proper
    ///   X.509 certificate using the key pair. The current implementation
    ///   creates a deterministic DER-like structure suitable for hash computation.
    public func generate(for keyPair: KeyPair) throws -> DeterministicCertificate {
        let now = Date()
        let notBefore = now
        // 12 days validity (within the 14-day browser maximum)
        let notAfter = now.addingTimeInterval(12 * 24 * 60 * 60)

        // Build a deterministic certificate-like structure from the public key.
        // A full implementation would create a proper X.509 v3 certificate;
        // this simplified version produces a stable byte sequence for hashing.
        let publicKeyBytes = keyPair.publicKey.rawBytes
        let derEncoded = buildDeterministicDER(
            publicKeyBytes: publicKeyBytes,
            notBefore: notBefore,
            notAfter: notAfter
        )

        // Sign the certificate content
        let signature = try keyPair.sign(Data(derEncoded))
        let signedDER = derEncoded + Array(signature)

        // Compute SHA-256 hash of the signed certificate
        let hashDigest = SHA256.hash(data: signedDER)
        let certHash = Array(hashDigest)

        // Encode as multihash (SHA-256 code = 0x12, length = 32)
        let multihashBytes: [UInt8] = [0x12, 0x20] + certHash

        // Encode as multibase base64url (prefix 'u')
        let certHashMultibase = encodeBase64URL(multihashBytes)

        return DeterministicCertificate(
            certHash: certHash,
            certHashMultibase: certHashMultibase,
            notBefore: notBefore,
            notAfter: notAfter,
            derEncoded: signedDER
        )
    }

    /// Verifies that a certificate hash matches the given certificate bytes.
    ///
    /// - Parameters:
    ///   - certHash: The expected SHA-256 hash
    ///   - certificate: The DER-encoded certificate bytes to verify
    /// - Returns: `true` if the hash matches
    public func verify(certHash: [UInt8], certificate: [UInt8]) -> Bool {
        let computed = Array(SHA256.hash(data: certificate))
        guard certHash.count == computed.count else { return false }
        // Constant-time comparison to prevent timing attacks
        var result: UInt8 = 0
        for i in 0..<certHash.count {
            result |= certHash[i] ^ computed[i]
        }
        return result == 0
    }

    // MARK: - Private

    /// Builds a deterministic DER-like byte sequence from public key material.
    ///
    /// This is a simplified representation. A production implementation would
    /// build a full ASN.1 DER-encoded X.509 v3 certificate.
    private func buildDeterministicDER(
        publicKeyBytes: Data,
        notBefore: Date,
        notAfter: Date
    ) -> [UInt8] {
        // Header: "WebTransport-cert-v1"
        let header = Array("WebTransport-cert-v1".utf8)

        // Encode timestamps as seconds since epoch (big-endian UInt64)
        let notBeforeSeconds = UInt64(notBefore.timeIntervalSince1970)
        let notAfterSeconds = UInt64(notAfter.timeIntervalSince1970)

        var result: [UInt8] = []
        result.append(contentsOf: header)
        result.append(contentsOf: withUnsafeBytes(of: notBeforeSeconds.bigEndian) { Array($0) })
        result.append(contentsOf: withUnsafeBytes(of: notAfterSeconds.bigEndian) { Array($0) })
        result.append(contentsOf: publicKeyBytes)

        return result
    }

    /// Encodes bytes as multibase base64url (prefix 'u', no padding).
    private func encodeBase64URL(_ bytes: [UInt8]) -> String {
        let base64 = Data(bytes).base64EncodedString()
        let base64url = base64
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "u" + base64url
    }
}
