/// AutoTLSTests - Tests for automatic TLS certificate generation and rotation
import Testing
import Foundation
import P2PCore
import P2PCertificate
@testable import P2PSecurityTLS

@Suite("AutoTLS Tests")
struct AutoTLSTests {

    // MARK: - Configuration Tests

    @Test("Default configuration has 24 hour lifetime and 1 hour rotation buffer")
    func defaultConfiguration() {
        let config = AutoTLS.Configuration()

        #expect(config.certificateLifetime == .seconds(24 * 3600))
        #expect(config.rotationBuffer == .seconds(3600))
    }

    @Test("Custom configuration preserves values")
    func customConfiguration() {
        let config = AutoTLS.Configuration(
            certificateLifetime: .seconds(48 * 3600),
            rotationBuffer: .seconds(7200)
        )

        #expect(config.certificateLifetime == .seconds(48 * 3600))
        #expect(config.rotationBuffer == .seconds(7200))
    }

    // MARK: - Certificate Generation Tests

    @Test("Certificate generation produces valid CertificateInfo")
    func generateCertificateProducesValidInfo() throws {
        let autoTLS = AutoTLS()
        let keyPair = KeyPair.generateEd25519()

        let cert = try autoTLS.generateCertificate(for: keyPair)

        // Certificate chain should be non-empty DER
        #expect(!cert.certificateChain.isEmpty)
        // Should start with ASN.1 SEQUENCE tag (0x30)
        #expect(cert.certificateChain[0] == 0x30)

        // Private key should be non-empty
        #expect(!cert.privateKey.isEmpty)

        // PeerID should match key pair
        #expect(cert.peerID == keyPair.peerID)

        // Fingerprint should be colon-separated hex (SHA-256 = 32 bytes = 95 chars with colons)
        #expect(cert.fingerprint.contains(":"))
        let hexParts = cert.fingerprint.split(separator: ":")
        #expect(hexParts.count == 32)

        // Each part should be exactly 2 hex characters
        for part in hexParts {
            #expect(part.count == 2)
        }
    }

    @Test("Certificate has correct lifetime based on configuration")
    func certificateHasCorrectLifetime() throws {
        let lifetimeSeconds: Int = 12 * 3600  // 12 hours
        let config = AutoTLS.Configuration(
            certificateLifetime: .seconds(lifetimeSeconds)
        )
        let autoTLS = AutoTLS(configuration: config)
        let keyPair = KeyPair.generateEd25519()

        let beforeGeneration = Date()
        let cert = try autoTLS.generateCertificate(for: keyPair)
        let afterGeneration = Date()

        // notBefore should be approximately now
        #expect(cert.notBefore >= beforeGeneration)
        #expect(cert.notBefore <= afterGeneration)

        // notAfter should be approximately now + lifetime
        let expectedNotAfter = cert.notBefore.addingTimeInterval(Double(lifetimeSeconds))
        let timeDifference = abs(cert.notAfter.timeIntervalSince(expectedNotAfter))
        #expect(timeDifference < 1.0)  // Less than 1 second tolerance
    }

    @Test("Generated certificate can be verified by LibP2PCertificate")
    func certificateVerifiableByLibP2PCertificate() throws {
        let autoTLS = AutoTLS()
        let keyPair = KeyPair.generateEd25519()

        let cert = try autoTLS.generateCertificate(for: keyPair)

        // The underlying certificate should be parseable and contain valid PeerID
        let extractedPeerID = try LibP2PCertificate.extractPeerID(from: Data(cert.certificateChain))
        #expect(extractedPeerID == keyPair.peerID)
    }

    // MARK: - Rotation Check Tests

    @Test("Certificate needs rotation when expired")
    func certificateNeedsRotationWhenExpired() throws {
        let config = AutoTLS.Configuration(
            certificateLifetime: .seconds(1),  // 1 second lifetime
            rotationBuffer: .seconds(0)        // No buffer
        )
        let autoTLS = AutoTLS(configuration: config)

        // Create a CertificateInfo that is already expired
        let expiredCert = CertificateInfo(
            certificateChain: [0x30],
            privateKey: [0x00],
            peerID: PeerID(publicKey: KeyPair.generateEd25519().publicKey),
            notBefore: Date().addingTimeInterval(-3600),
            notAfter: Date().addingTimeInterval(-1),  // Expired 1 second ago
            fingerprint: "00:00"
        )

        #expect(autoTLS.certificateNeedsRotation(expiredCert))
    }

    @Test("Certificate needs rotation when within rotation buffer")
    func certificateNeedsRotationWithinBuffer() throws {
        let config = AutoTLS.Configuration(
            certificateLifetime: .seconds(3600),
            rotationBuffer: .seconds(3600)  // 1 hour buffer
        )
        let autoTLS = AutoTLS(configuration: config)

        // Certificate that expires in 30 minutes (within 1 hour buffer)
        let cert = CertificateInfo(
            certificateChain: [0x30],
            privateKey: [0x00],
            peerID: PeerID(publicKey: KeyPair.generateEd25519().publicKey),
            notBefore: Date().addingTimeInterval(-3600),
            notAfter: Date().addingTimeInterval(1800),  // 30 minutes from now
            fingerprint: "00:00"
        )

        #expect(autoTLS.certificateNeedsRotation(cert))
    }

    @Test("Certificate does NOT need rotation when fresh")
    func certificateDoesNotNeedRotationWhenFresh() throws {
        let config = AutoTLS.Configuration(
            certificateLifetime: .seconds(24 * 3600),
            rotationBuffer: .seconds(3600)
        )
        let autoTLS = AutoTLS(configuration: config)

        // Certificate that expires in 23 hours (well outside 1 hour buffer)
        let freshCert = CertificateInfo(
            certificateChain: [0x30],
            privateKey: [0x00],
            peerID: PeerID(publicKey: KeyPair.generateEd25519().publicKey),
            notBefore: Date(),
            notAfter: Date().addingTimeInterval(23 * 3600),
            fingerprint: "00:00"
        )

        #expect(!autoTLS.certificateNeedsRotation(freshCert))
    }

    // MARK: - Caching Tests

    @Test("Current certificate returns same cert on repeated calls")
    func currentCertificateCaching() throws {
        let autoTLS = AutoTLS()
        let keyPair = KeyPair.generateEd25519()

        let cert1 = try autoTLS.currentCertificate(for: keyPair)
        let cert2 = try autoTLS.currentCertificate(for: keyPair)

        // Same fingerprint means same certificate
        #expect(cert1.fingerprint == cert2.fingerprint)
        #expect(cert1.peerID == cert2.peerID)
        #expect(cert1.notBefore == cert2.notBefore)
        #expect(cert1.notAfter == cert2.notAfter)
    }

    @Test("Force rotation produces new certificate")
    func forceRotationProducesNewCert() throws {
        let autoTLS = AutoTLS()
        let keyPair = KeyPair.generateEd25519()

        let cert1 = try autoTLS.currentCertificate(for: keyPair)
        let cert2 = try autoTLS.rotateCertificate(for: keyPair)

        // Different fingerprints: each generation uses a new ephemeral P-256 key
        #expect(cert1.fingerprint != cert2.fingerprint)
        // Same PeerID
        #expect(cert1.peerID == cert2.peerID)
    }

    @Test("After force rotation, current certificate returns the rotated cert")
    func currentCertificateAfterRotation() throws {
        let autoTLS = AutoTLS()
        let keyPair = KeyPair.generateEd25519()

        _ = try autoTLS.currentCertificate(for: keyPair)
        let rotated = try autoTLS.rotateCertificate(for: keyPair)
        let current = try autoTLS.currentCertificate(for: keyPair)

        #expect(current.fingerprint == rotated.fingerprint)
    }

    // MARK: - Multiple Key Pairs

    @Test("Multiple key pairs produce different certificates")
    func multipleKeyPairsProduceDifferentCerts() throws {
        let autoTLS = AutoTLS()
        let keyPair1 = KeyPair.generateEd25519()
        let keyPair2 = KeyPair.generateEd25519()

        let cert1 = try autoTLS.currentCertificate(for: keyPair1)
        let cert2 = try autoTLS.currentCertificate(for: keyPair2)

        #expect(cert1.peerID != cert2.peerID)
        #expect(cert1.fingerprint != cert2.fingerprint)
    }

    // MARK: - Concurrent Safety

    @Test("Concurrent certificate access is safe", .timeLimit(.minutes(1)))
    func concurrentSafety() async throws {
        let autoTLS = AutoTLS()
        let keyPair = KeyPair.generateEd25519()

        // Seed the initial certificate
        _ = try autoTLS.currentCertificate(for: keyPair)

        // Access concurrently from multiple tasks
        try await withThrowingTaskGroup(of: CertificateInfo.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    try autoTLS.currentCertificate(for: keyPair)
                }
            }

            var fingerprints: Set<String> = []
            for try await cert in group {
                fingerprints.insert(cert.fingerprint)
                #expect(cert.peerID == keyPair.peerID)
            }

            // All should return the same cached cert (no rotation triggered)
            #expect(fingerprints.count == 1)
        }
    }
}
