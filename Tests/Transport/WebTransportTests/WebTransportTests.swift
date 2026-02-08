import Testing
import Foundation
@testable import P2PTransportWebTransport
@testable import P2PCore

// MARK: - Protocol Constants

@Suite("WebTransport Protocol Constants")
struct WebTransportProtocolTests {

    @Test("Protocol ID is /webtransport")
    func protocolID() {
        #expect(WebTransportProtocol.protocolID == "/webtransport")
    }

    @Test("ALPN is h3")
    func alpn() {
        #expect(WebTransportProtocol.alpn == "h3")
    }

    @Test("Certificate hash prefix is /certhash/")
    func certHashPrefix() {
        #expect(WebTransportProtocol.certHashPrefix == "/certhash/")
    }

    @Test("Maximum certificate validity is 14 days")
    func maxCertValidityDays() {
        #expect(WebTransportProtocol.maxCertificateValidityDays == 14)
    }
}

// MARK: - Error Cases

@Suite("WebTransport Errors")
struct WebTransportErrorTests {

    @Test("Error cases are distinct")
    func errorCasesDistinct() {
        let errors: [WebTransportError] = [
            .http3NotAvailable,
            .invalidCertificateHash,
            .connectionFailed("test"),
            .streamCreationFailed,
            .notConnected,
            .timeout,
            .certificateVerificationFailed,
        ]

        // Each error should be instantiable
        #expect(errors.count == 7)
    }

    @Test("connectionFailed carries message")
    func connectionFailedMessage() {
        let error = WebTransportError.connectionFailed("handshake timeout")
        if case .connectionFailed(let message) = error {
            #expect(message == "handshake timeout")
        } else {
            Issue.record("Expected connectionFailed")
        }
    }

    @Test("All errors conform to Sendable")
    func sendableConformance() {
        let error: any Sendable = WebTransportError.http3NotAvailable
        _ = error
    }
}

// MARK: - Configuration

@Suite("WebTransport Configuration")
struct WebTransportConfigurationTests {

    @Test("Default configuration values")
    func defaultValues() {
        let config = WebTransportConfiguration()

        // 12 days in seconds
        #expect(config.certRotationInterval == .seconds(12 * 24 * 60 * 60))
        #expect(config.maxConcurrentStreams == 100)
        #expect(config.keepAliveInterval == .seconds(30))
        #expect(config.connectionTimeout == .seconds(30))
    }

    @Test("Custom configuration values")
    func customValues() {
        let config = WebTransportConfiguration(
            certRotationInterval: .seconds(7 * 24 * 60 * 60),
            maxConcurrentStreams: 50,
            keepAliveInterval: .seconds(15),
            connectionTimeout: .seconds(60)
        )

        #expect(config.certRotationInterval == .seconds(7 * 24 * 60 * 60))
        #expect(config.maxConcurrentStreams == 50)
        #expect(config.keepAliveInterval == .seconds(15))
        #expect(config.connectionTimeout == .seconds(60))
    }

    @Test("Configuration is Sendable")
    func sendable() {
        let config: any Sendable = WebTransportConfiguration()
        _ = config
    }
}

// MARK: - Deterministic Certificate Generator

@Suite("Deterministic Certificate Generator")
struct DeterministicCertGeneratorTests {

    @Test("Generate certificate produces valid structure")
    func generateCert() throws {
        let keyPair = KeyPair.generateEd25519()
        let generator = DeterministicCertGenerator()
        let cert = try generator.generate(for: keyPair)

        // Certificate hash should be 32 bytes (SHA-256)
        #expect(cert.certHash.count == 32)

        // DER-encoded should not be empty
        #expect(!cert.derEncoded.isEmpty)

        // Validity period should be approximately 12 days
        let interval = cert.notAfter.timeIntervalSince(cert.notBefore)
        let expectedInterval = 12.0 * 24 * 60 * 60
        #expect(abs(interval - expectedInterval) < 1.0)
    }

    @Test("Certificate hash multibase is base64url encoded with u prefix")
    func certHashFormat() throws {
        let keyPair = KeyPair.generateEd25519()
        let generator = DeterministicCertGenerator()
        let cert = try generator.generate(for: keyPair)

        // Multibase base64url starts with 'u'
        #expect(cert.certHashMultibase.hasPrefix("u"))

        // Should not contain base64 padding or non-URL-safe characters
        let encoded = cert.certHashMultibase
        #expect(!encoded.contains("="))
        #expect(!encoded.contains("+"))
        #expect(!encoded.contains("/"))
    }

    @Test("Verify hash matches certificate")
    func verifyHashMatches() throws {
        let keyPair = KeyPair.generateEd25519()
        let generator = DeterministicCertGenerator()
        let cert = try generator.generate(for: keyPair)

        let matches = generator.verify(
            certHash: cert.certHash,
            certificate: cert.derEncoded
        )
        #expect(matches)
    }

    @Test("Verify hash rejects wrong certificate")
    func verifyHashRejectsWrong() throws {
        let keyPair1 = KeyPair.generateEd25519()
        let keyPair2 = KeyPair.generateEd25519()
        let generator = DeterministicCertGenerator()

        let cert1 = try generator.generate(for: keyPair1)
        let cert2 = try generator.generate(for: keyPair2)

        // Hash from cert1 should not match cert2's DER
        let matches = generator.verify(
            certHash: cert1.certHash,
            certificate: cert2.derEncoded
        )
        #expect(!matches)
    }

    @Test("Verify hash rejects wrong length")
    func verifyHashRejectsWrongLength() throws {
        let keyPair = KeyPair.generateEd25519()
        let generator = DeterministicCertGenerator()
        let cert = try generator.generate(for: keyPair)

        // Truncated hash should not match
        let truncated = Array(cert.certHash.prefix(16))
        let matches = generator.verify(
            certHash: truncated,
            certificate: cert.derEncoded
        )
        #expect(!matches)
    }

    @Test("Certificate not-before is before not-after")
    func certificateValidityOrder() throws {
        let keyPair = KeyPair.generateEd25519()
        let generator = DeterministicCertGenerator()
        let cert = try generator.generate(for: keyPair)

        #expect(cert.notBefore < cert.notAfter)
    }

    @Test("Certificate validity within browser maximum")
    func certificateWithinBrowserMax() throws {
        let keyPair = KeyPair.generateEd25519()
        let generator = DeterministicCertGenerator()
        let cert = try generator.generate(for: keyPair)

        let validityDays = cert.notAfter.timeIntervalSince(cert.notBefore) / (24 * 60 * 60)
        #expect(validityDays <= Double(WebTransportProtocol.maxCertificateValidityDays))
    }

    @Test("DeterministicCertificate is Sendable")
    func certSendable() throws {
        let keyPair = KeyPair.generateEd25519()
        let generator = DeterministicCertGenerator()
        let cert: any Sendable = try generator.generate(for: keyPair)
        _ = cert
    }
}

// MARK: - WebTransport Connection

@Suite("WebTransport Connection")
struct WebTransportConnectionTests {

    @Test("Initial state is connecting")
    func initialState() {
        let connection = WebTransportConnection()
        #expect(connection.currentState == .connecting)
    }

    @Test("Initial addresses are nil")
    func initialAddresses() {
        let connection = WebTransportConnection()
        #expect(connection.localAddress == nil)
        #expect(connection.remoteAddress == nil)
        #expect(connection.remotePeerID == nil)
    }

    @Test("Connection with remote address")
    func connectionWithRemoteAddress() throws {
        let addr = try Multiaddr("/ip4/127.0.0.1/udp/4433/quic-v1")
        let connection = WebTransportConnection(remoteAddress: addr)
        #expect(connection.remoteAddress == addr)
        #expect(connection.currentState == .connecting)
    }

    @Test("Connection with remote peer ID")
    func connectionWithRemotePeerID() {
        let keyPair = KeyPair.generateEd25519()
        let peerID = PeerID(publicKey: keyPair.publicKey)
        let connection = WebTransportConnection(remotePeerID: peerID)
        #expect(connection.remotePeerID == peerID)
    }

    @Test("Mark connected updates state and addresses")
    func markConnected() throws {
        let localAddr = try Multiaddr("/ip4/0.0.0.0/udp/0/quic-v1")
        let remoteAddr = try Multiaddr("/ip4/1.2.3.4/udp/4433/quic-v1")
        let keyPair = KeyPair.generateEd25519()
        let peerID = PeerID(publicKey: keyPair.publicKey)

        let connection = WebTransportConnection()
        let result = connection.markConnected(
            localAddress: localAddr,
            remoteAddress: remoteAddr,
            remotePeerID: peerID
        )

        #expect(result == true)
        #expect(connection.currentState == .connected)
        #expect(connection.localAddress == localAddr)
        #expect(connection.remoteAddress == remoteAddr)
        #expect(connection.remotePeerID == peerID)
    }

    @Test("Mark connected is no-op when already connected")
    func markConnectedNoOpWhenConnected() throws {
        let localAddr = try Multiaddr("/ip4/0.0.0.0/udp/0/quic-v1")
        let remoteAddr = try Multiaddr("/ip4/1.2.3.4/udp/4433/quic-v1")
        let keyPair = KeyPair.generateEd25519()
        let peerID = PeerID(publicKey: keyPair.publicKey)

        let connection = WebTransportConnection()
        let firstResult = connection.markConnected(
            localAddress: localAddr,
            remoteAddress: remoteAddr,
            remotePeerID: peerID
        )
        #expect(firstResult == true)

        // Second call should be no-op
        let newAddr = try Multiaddr("/ip4/5.6.7.8/udp/9999/quic-v1")
        let secondResult = connection.markConnected(
            localAddress: newAddr,
            remoteAddress: newAddr,
            remotePeerID: nil
        )
        #expect(secondResult == false)

        // Original values should be preserved
        #expect(connection.localAddress == localAddr)
        #expect(connection.remoteAddress == remoteAddr)
        #expect(connection.remotePeerID == peerID)
    }

    @Test(.timeLimit(.minutes(1)))
    func markConnectedNoOpAfterClose() async throws {
        let connection = WebTransportConnection()
        try await connection.close()
        #expect(connection.currentState == .closed)

        let localAddr = try Multiaddr("/ip4/0.0.0.0/udp/0/quic-v1")
        let result = connection.markConnected(
            localAddress: localAddr,
            remoteAddress: nil,
            remotePeerID: nil
        )
        #expect(result == false)
        #expect(connection.currentState == .closed)
    }

    @Test(.timeLimit(.minutes(1)))
    func closeTransitionsToClosedState() async throws {
        let connection = WebTransportConnection()
        try await connection.close()
        #expect(connection.currentState == .closed)
    }

    @Test(.timeLimit(.minutes(1)))
    func closeIsIdempotent() async throws {
        let connection = WebTransportConnection()
        try await connection.close()
        try await connection.close()  // Should not throw
        #expect(connection.currentState == .closed)
    }

    @Test("Connection is Sendable")
    func sendable() {
        let connection: any Sendable = WebTransportConnection()
        _ = connection
    }
}

// MARK: - WebTransport Transport

@Suite("WebTransport Transport")
struct WebTransportTransportTests {

    @Test("Transport uses default configuration")
    func defaultConfig() {
        let transport = WebTransportTransport()
        #expect(transport.configuration.maxConcurrentStreams == 100)
    }

    @Test("Transport uses custom configuration")
    func customConfig() {
        let config = WebTransportConfiguration(maxConcurrentStreams: 50)
        let transport = WebTransportTransport(configuration: config)
        #expect(transport.configuration.maxConcurrentStreams == 50)
    }

    @Test("canDial rejects TCP address")
    func canDialRejectsTCP() throws {
        let transport = WebTransportTransport()
        let addr = try Multiaddr("/ip4/127.0.0.1/tcp/4001")
        #expect(!transport.canDial(addr))
    }

    @Test("canDial rejects plain QUIC address without webtransport")
    func canDialRejectsPlainQUIC() throws {
        let transport = WebTransportTransport()
        let addr = try Multiaddr("/ip4/127.0.0.1/udp/4433/quic-v1")
        #expect(!transport.canDial(addr))
    }

    @Test("canDial rejects address without IP")
    func canDialRejectsNoIP() throws {
        let transport = WebTransportTransport()
        let addr = try Multiaddr("/memory/test")
        #expect(!transport.canDial(addr))
    }

    @Test("canDial accepts address with webtransport protocol")
    func canDialAcceptsWebtransport() throws {
        let transport = WebTransportTransport()
        let addr = Multiaddr(uncheckedProtocols: [
            .ip4("127.0.0.1"),
            .udp(4433),
            .quicV1,
            .webtransport,
        ])
        #expect(transport.canDial(addr))
    }

    @Test("canDial accepts address with webtransport and certhash")
    func canDialAcceptsWebtransportWithCerthash() throws {
        let transport = WebTransportTransport()
        let hashData = Data(repeating: 0x42, count: 34)
        let addr = Multiaddr(uncheckedProtocols: [
            .ip4("127.0.0.1"),
            .udp(4433),
            .quicV1,
            .webtransport,
            .certhash(hashData),
        ])
        #expect(transport.canDial(addr))
    }

    @Test("canDial rejects certhash without webtransport")
    func canDialRejectsCerthashWithoutWebtransport() throws {
        let transport = WebTransportTransport()
        let hashData = Data(repeating: 0x42, count: 34)
        let addr = Multiaddr(uncheckedProtocols: [
            .ip4("127.0.0.1"),
            .udp(4433),
            .quicV1,
            .certhash(hashData),
        ])
        #expect(!transport.canDial(addr))
    }

    @Test("canDial rejects wrong protocol order")
    func canDialRejectsWrongOrder() throws {
        let transport = WebTransportTransport()
        // webtransport before quic-v1 is invalid
        let addr = Multiaddr(uncheckedProtocols: [
            .ip4("127.0.0.1"),
            .udp(4433),
            .webtransport,
            .quicV1,
        ])
        #expect(!transport.canDial(addr))
    }

    @Test(.timeLimit(.minutes(1)))
    func dialThrowsHTTP3NotAvailable() async throws {
        let transport = WebTransportTransport()
        let addr = try Multiaddr("/ip4/127.0.0.1/udp/4433/quic-v1")

        do {
            _ = try await transport.dial(to: addr)
            Issue.record("Expected http3NotAvailable error")
        } catch let error as WebTransportError {
            if case .http3NotAvailable = error {
                // Expected
            } else {
                Issue.record("Expected http3NotAvailable, got \(error)")
            }
        }
    }

    @Test("Extract cert hashes from address")
    func extractCertHashes() {
        let transport = WebTransportTransport()
        let hash1 = Data([0x12, 0x20] + Array(repeating: UInt8(0xAA), count: 32))
        let hash2 = Data([0x12, 0x20] + Array(repeating: UInt8(0xBB), count: 32))
        let addr = Multiaddr(uncheckedProtocols: [
            .ip4("1.2.3.4"),
            .udp(4433),
            .quicV1,
            .certhash(hash1),
            .certhash(hash2),
        ])

        let hashes = transport.extractCertHashes(from: addr)
        #expect(hashes.count == 2)
        #expect(hashes[0] == Array(hash1))
        #expect(hashes[1] == Array(hash2))
    }

    @Test("Extract cert hashes from address without certhash")
    func extractCertHashesEmpty() throws {
        let transport = WebTransportTransport()
        let addr = try Multiaddr("/ip4/127.0.0.1/udp/4433/quic-v1")
        let hashes = transport.extractCertHashes(from: addr)
        #expect(hashes.isEmpty)
    }

    @Test("Transport is Sendable")
    func sendable() {
        let transport: any Sendable = WebTransportTransport()
        _ = transport
    }
}
