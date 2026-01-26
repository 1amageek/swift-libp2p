/// TLSCertificateTests - Tests for TLS certificate operations
import Testing
import Foundation
import P2PCore
@testable import P2PSecurityTLS

@Suite("TLSCertificate Tests")
struct TLSCertificateTests {

    // MARK: - Certificate Generation Tests

    @Test("Generate certificate creates valid DER")
    func generateCertificate() throws {
        let keyPair = KeyPair.generateEd25519()

        let result = try TLSCertificate.generate(keyPair: keyPair)

        // Certificate should be non-empty
        #expect(!result.certificateDER.isEmpty)

        // Should start with SEQUENCE tag (0x30)
        #expect(result.certificateDER[0] == 0x30)
    }

    @Test("Generated certificate contains libp2p extension")
    func certificateContainsExtension() throws {
        let keyPair = KeyPair.generateEd25519()

        let result = try TLSCertificate.generate(keyPair: keyPair)

        // Should be able to extract identity
        let identity = try TLSCertificate.extractIdentity(from: result.certificateDER)

        // Public key should match
        #expect(identity.publicKey == keyPair.publicKey.protobufEncoded)

        // Signature should be non-empty
        #expect(!identity.signature.isEmpty)
    }

    @Test("Certificate roundtrip preserves PeerID")
    func certificateRoundtrip() throws {
        let keyPair = KeyPair.generateEd25519()

        let result = try TLSCertificate.generate(keyPair: keyPair)

        // Extract SPKI from certificate
        // For this test, we'll verify the identity extraction works
        let identity = try TLSCertificate.extractIdentity(from: result.certificateDER)

        // Decode the public key
        let extractedPublicKey = try PublicKey(protobufEncoded: identity.publicKey)

        // PeerID should match
        #expect(extractedPublicKey.peerID == keyPair.peerID)
    }

    // MARK: - Configuration Tests

    @Test("Default TLS configuration values")
    func defaultConfiguration() {
        let config = TLSConfiguration.default

        #expect(config.handshakeTimeout == .seconds(30))
        #expect(config.alpnProtocols == ["libp2p"])
    }

    @Test("Custom TLS configuration")
    func customConfiguration() {
        let config = TLSConfiguration(
            handshakeTimeout: .seconds(60),
            alpnProtocols: ["libp2p", "custom"]
        )

        #expect(config.handshakeTimeout == .seconds(60))
        #expect(config.alpnProtocols == ["libp2p", "custom"])
    }

    // MARK: - Error Tests

    @Test("Extract identity from invalid certificate throws")
    func invalidCertificateThrows() {
        let invalidData = Data([0x00, 0x01, 0x02, 0x03])

        #expect(throws: TLSError.self) {
            _ = try TLSCertificate.extractIdentity(from: invalidData)
        }
    }

    // MARK: - Protocol ID Test

    @Test("TLS protocol ID is correct")
    func protocolID() {
        #expect(tlsProtocolID == "/tls/1.0.0")
    }

    // MARK: - TLSUpgrader Tests

    @Test("TLSUpgrader has correct protocol ID")
    func upgraderProtocolID() {
        let upgrader = TLSUpgrader()
        #expect(upgrader.protocolID == "/tls/1.0.0")
    }

    @Test("TLSUpgrader with custom configuration")
    func upgraderWithConfig() {
        let config = TLSConfiguration(handshakeTimeout: .seconds(10))
        let upgrader = TLSUpgrader(configuration: config)
        #expect(upgrader.protocolID == "/tls/1.0.0")
    }
}
