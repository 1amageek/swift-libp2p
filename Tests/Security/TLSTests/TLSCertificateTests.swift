/// TLSCertificateTests - Tests for TLS certificate operations
import Testing
import Foundation
import P2PCore
import P2PCertificate
import P2PSecurity
@testable import P2PSecurityTLS

@Suite("TLSCertificate Tests")
struct TLSCertificateTests {

    // MARK: - Certificate Generation Tests

    @Test("Generate certificate creates valid DER")
    func generateCertificate() throws {
        let keyPair = KeyPair.generateEd25519()

        let result = try TLSCertificateHelper.generate(keyPair: keyPair)

        // Certificate chain should have exactly one certificate (self-signed)
        #expect(result.certificateChain.count == 1)

        let certDER = result.certificateChain[0]

        // Certificate should be non-empty
        #expect(!certDER.isEmpty)

        // Should start with SEQUENCE tag (0x30)
        #expect(certDER[certDER.startIndex] == 0x30)
    }

    @Test("Generated certificate contains libp2p extension and valid PeerID")
    func certificateContainsExtension() throws {
        let keyPair = KeyPair.generateEd25519()

        let result = try TLSCertificateHelper.generate(keyPair: keyPair)

        // Should be able to extract PeerID
        let peerID = try LibP2PCertificate.extractPeerID(from: result.certificateChain[0])

        // PeerID should match the generating key pair
        #expect(peerID == keyPair.peerID)
    }

    @Test("Certificate roundtrip preserves PeerID")
    func certificateRoundtrip() throws {
        let keyPair = KeyPair.generateEd25519()

        let result = try TLSCertificateHelper.generate(keyPair: keyPair)

        let extractedPeerID = try LibP2PCertificate.extractPeerID(from: result.certificateChain[0])

        #expect(extractedPeerID == keyPair.peerID)
    }

    // MARK: - CertificateValidator Tests

    @Test("CertificateValidator extracts PeerID")
    func certificateValidatorExtractsPeerID() throws {
        let keyPair = KeyPair.generateEd25519()
        let result = try TLSCertificateHelper.generate(keyPair: keyPair)

        let validator = TLSCertificateHelper.makeCertificateValidator(expectedPeer: nil)
        let peerInfo = try validator(result.certificateChain)

        let peerID = peerInfo as? PeerID
        #expect(peerID == keyPair.peerID)
    }

    @Test("CertificateValidator succeeds with matching expected peer")
    func certificateValidatorMatchingPeer() throws {
        let keyPair = KeyPair.generateEd25519()
        let result = try TLSCertificateHelper.generate(keyPair: keyPair)

        let validator = TLSCertificateHelper.makeCertificateValidator(expectedPeer: keyPair.peerID)
        let peerInfo = try validator(result.certificateChain)

        let peerID = peerInfo as? PeerID
        #expect(peerID == keyPair.peerID)
    }

    @Test("CertificateValidator rejects mismatched expected peer")
    func certificateValidatorMismatchedPeer() throws {
        let keyPair = KeyPair.generateEd25519()
        let otherKeyPair = KeyPair.generateEd25519()
        let result = try TLSCertificateHelper.generate(keyPair: keyPair)

        let validator = TLSCertificateHelper.makeCertificateValidator(expectedPeer: otherKeyPair.peerID)

        #expect(throws: TLSError.self) {
            _ = try validator(result.certificateChain)
        }
    }

    // MARK: - Configuration Tests

    @Test("Default TLS upgrader configuration values")
    func defaultConfiguration() {
        let config = TLSUpgraderConfiguration.default

        #expect(config.handshakeTimeout == .seconds(30))
    }

    @Test("Custom TLS upgrader configuration")
    func customConfiguration() {
        let config = TLSUpgraderConfiguration(
            handshakeTimeout: .seconds(60)
        )

        #expect(config.handshakeTimeout == .seconds(60))
    }

    // MARK: - Error Tests

    @Test("Extract PeerID from invalid certificate throws")
    func invalidCertificateThrows() {
        let invalidData = Data([0x00, 0x01, 0x02, 0x03])

        #expect(throws: (any Error).self) {
            _ = try LibP2PCertificate.extractPeerID(from: invalidData)
        }
    }

    @Test("Extract PeerID from empty certificate chain throws")
    func emptyCertificateChainThrows() throws {
        let validator = TLSCertificateHelper.makeCertificateValidator(expectedPeer: nil)

        #expect(throws: TLSError.self) {
            _ = try validator([])
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
        let config = TLSUpgraderConfiguration(handshakeTimeout: .seconds(10))
        let upgrader = TLSUpgrader(configuration: config)
        #expect(upgrader.protocolID == "/tls/1.0.0")
    }

    // MARK: - Early Muxer Negotiation (ALPN) Tests

    @Test("Build ALPN protocols with muxer hints")
    func buildALPNWithMuxers() {
        let alpn = TLSUpgrader.buildALPNProtocols(muxerProtocols: ["/yamux/1.0.0", "/mplex/6.7.0"])

        #expect(alpn.count == 3)
        #expect(alpn[0] == "libp2p/yamux/1.0.0")
        #expect(alpn[1] == "libp2p/mplex/6.7.0")
        #expect(alpn[2] == "libp2p")
    }

    @Test("Build ALPN protocols without muxer hints")
    func buildALPNWithoutMuxers() {
        let alpn = TLSUpgrader.buildALPNProtocols(muxerProtocols: [])

        #expect(alpn.count == 1)
        #expect(alpn[0] == "libp2p")
    }

    @Test("Extract muxer protocol from ALPN with muxer hint")
    func extractMuxerFromALPN() {
        let muxer = TLSUpgrader.extractMuxerProtocol(from: "libp2p/yamux/1.0.0")
        #expect(muxer == "/yamux/1.0.0")
    }

    @Test("Extract muxer protocol from base ALPN returns nil")
    func extractMuxerFromBaseALPN() {
        let muxer = TLSUpgrader.extractMuxerProtocol(from: "libp2p")
        #expect(muxer == nil)
    }

    @Test("Extract muxer protocol from mplex ALPN")
    func extractMuxerFromMplexALPN() {
        let muxer = TLSUpgrader.extractMuxerProtocol(from: "libp2p/mplex/6.7.0")
        #expect(muxer == "/mplex/6.7.0")
    }

    @Test("TLSUpgrader conforms to EarlyMuxerNegotiating")
    func upgraderConformsToEarlyMuxer() {
        let upgrader = TLSUpgrader()
        #expect(upgrader is EarlyMuxerNegotiating)
    }
}
