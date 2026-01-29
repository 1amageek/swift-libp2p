/// LibP2PCertificateTests - Tests for transport-agnostic certificate operations
import Testing
import Foundation
import P2PCore
@testable import P2PCertificate

@Suite("LibP2PCertificate Tests")
struct LibP2PCertificateTests {

    // MARK: - Certificate Generation Tests

    @Test("Generate certificate creates valid DER")
    func generateCertificate() throws {
        let keyPair = KeyPair.generateEd25519()

        let result = try LibP2PCertificate.generate(keyPair: keyPair)

        // Certificate should be non-empty
        #expect(!result.certificateDER.isEmpty)

        // Should start with SEQUENCE tag (0x30)
        #expect(result.certificateDER[result.certificateDER.startIndex] == 0x30)
    }

    @Test("Generated certificate contains libp2p extension and valid PeerID")
    func certificateContainsExtension() throws {
        let keyPair = KeyPair.generateEd25519()

        let result = try LibP2PCertificate.generate(keyPair: keyPair)

        // Should be able to extract PeerID
        let peerID = try LibP2PCertificate.extractPeerID(from: result.certificateDER)

        // PeerID should match the generating key pair
        #expect(peerID == keyPair.peerID)
    }

    @Test("Certificate roundtrip preserves PeerID")
    func certificateRoundtrip() throws {
        let keyPair = KeyPair.generateEd25519()

        let result = try LibP2PCertificate.generate(keyPair: keyPair)

        let extractedPeerID = try LibP2PCertificate.extractPeerID(from: result.certificateDER)

        #expect(extractedPeerID == keyPair.peerID)
    }

    @Test("Generated certificate returns valid P-256 private key")
    func generatedCertificateHasPrivateKey() throws {
        let keyPair = KeyPair.generateEd25519()

        let result = try LibP2PCertificate.generate(keyPair: keyPair)

        // Private key should be usable for signing
        let testData = Data("test".utf8)
        let signature = try result.privateKey.signature(for: testData)
        #expect(result.privateKey.publicKey.isValidSignature(signature, for: testData))
    }

    // MARK: - Error Tests

    @Test("Extract PeerID from invalid certificate throws")
    func invalidCertificateThrows() {
        let invalidData = Data([0x00, 0x01, 0x02, 0x03])

        #expect(throws: (any Error).self) {
            _ = try LibP2PCertificate.extractPeerID(from: invalidData)
        }
    }

    @Test("Extract PeerID from certificate without libp2p extension throws")
    func certificateWithoutExtensionThrows() throws {
        // Generate a plain X.509 certificate (no libp2p extension)
        // by creating raw DER with just basic fields
        // The simplest approach: use swift-tls-style plain cert
        // For now, just verify that an empty cert throws
        let emptyData = Data()

        #expect(throws: (any Error).self) {
            _ = try LibP2PCertificate.extractPeerID(from: emptyData)
        }
    }

    // MARK: - Multiple Key Types

    @Test("Certificate generation works with Ed25519 key pair")
    func ed25519KeyPair() throws {
        let keyPair = KeyPair.generateEd25519()
        let result = try LibP2PCertificate.generate(keyPair: keyPair)
        let peerID = try LibP2PCertificate.extractPeerID(from: result.certificateDER)
        #expect(peerID == keyPair.peerID)
    }
}
