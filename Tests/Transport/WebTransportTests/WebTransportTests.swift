import Testing
import Foundation
import NIOCore
@testable import P2PTransportWebTransport
@testable import P2PCore

private enum WebTransportTestError: Error {
    case connectionStreamClosed
}

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

// MARK: - Address Parsing

@Suite("WebTransport Address Parser")
struct WebTransportAddressParserTests {

    @Test("Parse valid address with cert hash and peer ID")
    func parseValidAddress() throws {
        let keyPair = KeyPair.generateEd25519()
        let peerID = keyPair.peerID
        let hash = Data([0x12, 0x20] + Array(repeating: UInt8(0xAB), count: 32))

        let address = Multiaddr(uncheckedProtocols: [
            .ip4("127.0.0.1"),
            .udp(4433),
            .quicV1,
            .webtransport,
            .certhash(hash),
            .p2p(peerID),
        ])

        let components = try WebTransportAddressParser.parse(address, requireCertificateHash: true)
        #expect(components.hostValue == "127.0.0.1")
        #expect(components.port == 4433)
        #expect(components.isIPv6 == false)
        #expect(components.certificateHashes.count == 1)
        #expect(components.certificateHashes[0] == hash)
        #expect(components.peerID == peerID)
    }

    @Test("Parse valid DNS address")
    func parseDNSAddress() throws {
        let hash = Data([0x12, 0x20] + Array(repeating: UInt8(0xAA), count: 32))
        let address = Multiaddr(uncheckedProtocols: [
            .dns("example.com"),
            .udp(4433),
            .quicV1,
            .webtransport,
            .certhash(hash),
        ])

        let components = try WebTransportAddressParser.parse(address, requireCertificateHash: true)
        #expect(components.hostValue == "example.com")
        #expect(components.port == 4433)
        #expect(components.certificateHashes == [hash])
    }

    @Test("Reject duplicate certificate hash")
    func rejectDuplicateHash() {
        let hash = Data([0x12, 0x20] + Array(repeating: UInt8(0x42), count: 32))
        let address = Multiaddr(uncheckedProtocols: [
            .ip4("127.0.0.1"),
            .udp(4433),
            .quicV1,
            .webtransport,
            .certhash(hash),
            .certhash(hash),
        ])

        #expect(throws: WebTransportAddressError.self) {
            _ = try WebTransportAddressParser.parse(address, requireCertificateHash: true)
        }
    }

    @Test("Reject wrong protocol order")
    func rejectWrongOrder() {
        let hash = Data([0x12, 0x20] + Array(repeating: UInt8(0x42), count: 32))
        let address = Multiaddr(uncheckedProtocols: [
            .ip4("127.0.0.1"),
            .udp(4433),
            .webtransport,
            .quicV1,
            .certhash(hash),
        ])

        #expect(throws: WebTransportAddressError.self) {
            _ = try WebTransportAddressParser.parse(address, requireCertificateHash: true)
        }
    }

    @Test("Reject missing cert hash when required")
    func rejectMissingCertHash() {
        let address = Multiaddr(uncheckedProtocols: [
            .ip4("127.0.0.1"),
            .udp(4433),
            .quicV1,
            .webtransport,
        ])

        #expect(throws: WebTransportAddressError.self) {
            _ = try WebTransportAddressParser.parse(address, requireCertificateHash: true)
        }
    }
}

// MARK: - Certificate Store

@Suite("WebTransport Certificate Store")
struct WebTransportCertificateStoreTests {

    @Test("Advertised hashes include current and next")
    func advertisedHashes() throws {
        let keyPair = KeyPair.generateEd25519()
        let store = try WebTransportCertificateStore(
            localKeyPair: keyPair,
            rotationInterval: .seconds(60)
        )

        let hashes = try store.advertisedHashes()
        #expect(hashes.count == 2)
        #expect(hashes[0].count == 34)
        #expect(hashes[1].count == 34)
        #expect(hashes[0].prefix(2) == Data([0x12, 0x20]))
        #expect(hashes[1].prefix(2) == Data([0x12, 0x20]))
    }

    @Test("Current material is available")
    func currentMaterial() throws {
        let keyPair = KeyPair.generateEd25519()
        let store = try WebTransportCertificateStore(
            localKeyPair: keyPair,
            rotationInterval: .seconds(60)
        )

        let material = try store.currentMaterial()
        #expect(!material.certificateDER.isEmpty)
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

        #expect(cert.certHash.count == 32)
        #expect(!cert.derEncoded.isEmpty)

        let interval = cert.notAfter.timeIntervalSince(cert.notBefore)
        let expectedInterval = 12.0 * 24 * 60 * 60
        #expect(abs(interval - expectedInterval) < 1.0)
    }

    @Test("Certificate hash multibase is base64url encoded with u prefix")
    func certHashFormat() throws {
        let keyPair = KeyPair.generateEd25519()
        let generator = DeterministicCertGenerator()
        let cert = try generator.generate(for: keyPair)

        #expect(cert.certHashMultibase.hasPrefix("u"))
        #expect(!cert.certHashMultibase.contains("="))
        #expect(!cert.certHashMultibase.contains("+"))
        #expect(!cert.certHashMultibase.contains("/"))
    }
}

// MARK: - Legacy Connection State

@Suite("WebTransport Connection")
struct WebTransportConnectionTests {

    @Test("Initial state is connecting")
    func initialState() {
        let connection = WebTransportConnection()
        #expect(connection.currentState == .connecting)
    }

    @Test(.timeLimit(.minutes(1)))
    func closeTransitionsToClosedState() async throws {
        let connection = WebTransportConnection()
        try await connection.close()
        #expect(connection.currentState == .closed)
    }
}

// MARK: - Transport

@Suite("WebTransport Transport", .serialized)
struct WebTransportTransportTests {

    @Test("Transport protocols include webtransport over quic-v1")
    func protocols() {
        let transport = WebTransportTransport()
        #expect(transport.protocols.contains(["ip4", "udp", "quic-v1", "webtransport"]))
        #expect(transport.protocols.contains(["ip6", "udp", "quic-v1", "webtransport"]))
        #expect(transport.protocols.contains(["dns", "udp", "quic-v1", "webtransport"]))
        #expect(transport.protocols.contains(["dns4", "udp", "quic-v1", "webtransport"]))
        #expect(transport.protocols.contains(["dns6", "udp", "quic-v1", "webtransport"]))
    }

    @Test("canDial requires webtransport and cert hash")
    func canDialValidation() throws {
        let transport = WebTransportTransport()

        let withHash = Multiaddr(uncheckedProtocols: [
            .ip4("127.0.0.1"),
            .udp(4433),
            .quicV1,
            .webtransport,
            .certhash(Data([0x12, 0x20] + Array(repeating: UInt8(0xAA), count: 32))),
        ])
        #expect(transport.canDial(withHash))

        let noHash = Multiaddr(uncheckedProtocols: [
            .ip4("127.0.0.1"),
            .udp(4433),
            .quicV1,
            .webtransport,
        ])
        #expect(!transport.canDial(noHash))

        let dnsWithHash = Multiaddr(uncheckedProtocols: [
            .dns("example.com"),
            .udp(4433),
            .quicV1,
            .webtransport,
            .certhash(Data([0x12, 0x20] + Array(repeating: UInt8(0xBB), count: 32))),
        ])
        #expect(transport.canDial(dnsWithHash))

        let zeroPort = Multiaddr(uncheckedProtocols: [
            .ip4("127.0.0.1"),
            .udp(0),
            .quicV1,
            .webtransport,
            .certhash(Data([0x12, 0x20] + Array(repeating: UInt8(0xCC), count: 32))),
        ])
        #expect(!transport.canDial(zeroPort))
    }

    @Test("canListen rejects cert hash in listen address")
    func canListenValidation() throws {
        let transport = WebTransportTransport()

        let listenAddress = try Multiaddr("/ip4/127.0.0.1/udp/0/quic-v1/webtransport")
        #expect(transport.canListen(listenAddress))

        let withHash = Multiaddr(uncheckedProtocols: [
            .ip4("127.0.0.1"),
            .udp(0),
            .quicV1,
            .webtransport,
            .certhash(Data([0x12, 0x20] + Array(repeating: UInt8(0xAA), count: 32))),
        ])
        #expect(!transport.canListen(withHash))

        let dnsListen = Multiaddr(uncheckedProtocols: [
            .dns("example.com"),
            .udp(4433),
            .quicV1,
            .webtransport,
        ])
        #expect(!transport.canListen(dnsListen))
    }

    @Test("listenSecured and dialSecured establish muxed connection", .timeLimit(.minutes(1)))
    func securedDialListen() async throws {
        let serverKey = KeyPair.generateEd25519()
        let clientKey = KeyPair.generateEd25519()

        let serverTransport = WebTransportTransport()
        let clientTransport = WebTransportTransport()

        let listenAddress = try Multiaddr("/ip4/127.0.0.1/udp/0/quic-v1/webtransport")
        let listener = try await serverTransport.listenSecured(listenAddress, localKeyPair: serverKey)

        let acceptTask = Task {
            for await connection in listener.connections {
                return connection
            }
            throw WebTransportTestError.connectionStreamClosed
        }

        let dialAddress = listener.localAddress
        let clientConnection = try await clientTransport.dialSecured(dialAddress, localKeyPair: clientKey)
        let serverConnection = try await acceptTask.value

        async let acceptedStream = serverConnection.acceptStream()
        let outboundStream = try await clientConnection.newStream()

        let payload = ByteBuffer(bytes: Data("hello-webtransport".utf8))
        try await outboundStream.write(payload)
        let inboundStream = try await acceptedStream
        let received = try await inboundStream.read()

        #expect(Data(buffer: received) == Data("hello-webtransport".utf8))

        try await outboundStream.close()
        try await inboundStream.close()
        try await clientConnection.close()
        try await serverConnection.close()
        try await listener.close()
    }

    @Test("dialSecured rejects certificate hash mismatch", .timeLimit(.minutes(1)))
    func rejectsMismatchedCertHash() async throws {
        let serverKey = KeyPair.generateEd25519()
        let clientKey = KeyPair.generateEd25519()

        let serverTransport = WebTransportTransport()
        let clientTransport = WebTransportTransport()

        let listenAddress = try Multiaddr("/ip4/127.0.0.1/udp/0/quic-v1/webtransport")
        let listener = try await serverTransport.listenSecured(listenAddress, localKeyPair: serverKey)

        let parsed = try WebTransportAddressParser.parse(listener.localAddress, requireCertificateHash: true)
        let wrongHash = Data([0x12, 0x20] + Array(repeating: UInt8(0xCC), count: 32))
        let badAddress = parsed.toMultiaddr(certificateHashes: [wrongHash])

        do {
            _ = try await clientTransport.dialSecured(badAddress, localKeyPair: clientKey)
            Issue.record("Expected certificateVerificationFailed")
        } catch let error as WebTransportError {
            if case .certificateVerificationFailed = error {
                // expected
            } else {
                Issue.record("Expected certificateVerificationFailed, got \(error)")
            }
        } catch {
            Issue.record("Expected WebTransportError, got \(error)")
        }

        try await listener.close()
    }

    @Test("dialSecured supports dns4 addresses", .timeLimit(.minutes(1)))
    func securedDialListenWithDNS4Address() async throws {
        let serverKey = KeyPair.generateEd25519()
        let clientKey = KeyPair.generateEd25519()

        let serverTransport = WebTransportTransport()
        let clientTransport = WebTransportTransport()

        let listenAddress = try Multiaddr("/ip4/127.0.0.1/udp/0/quic-v1/webtransport")
        let listener = try await serverTransport.listenSecured(listenAddress, localKeyPair: serverKey)

        let acceptTask = Task {
            for await connection in listener.connections {
                return connection
            }
            throw WebTransportTestError.connectionStreamClosed
        }

        let parsed = try WebTransportAddressParser.parse(listener.localAddress, requireCertificateHash: true)
        let dnsDialAddress = Multiaddr(uncheckedProtocols: [
            .dns4("127.0.0.1"),
            .udp(parsed.port),
            .quicV1,
            .webtransport,
            .certhash(parsed.certificateHashes[0]),
            .certhash(parsed.certificateHashes[1]),
            .p2p(serverKey.peerID),
        ])

        let clientConnection = try await clientTransport.dialSecured(dnsDialAddress, localKeyPair: clientKey)
        let serverConnection = try await acceptTask.value

        try await clientConnection.close()
        try await serverConnection.close()
        try await listener.close()
    }

    @Test("dialSecured supports dns4 hostname addresses", .timeLimit(.minutes(1)))
    func securedDialListenWithDNS4HostnameAddress() async throws {
        let serverKey = KeyPair.generateEd25519()
        let clientKey = KeyPair.generateEd25519()

        let serverTransport = WebTransportTransport()
        let clientTransport = WebTransportTransport()

        let listenAddress = try Multiaddr("/ip4/127.0.0.1/udp/0/quic-v1/webtransport")
        let listener = try await serverTransport.listenSecured(listenAddress, localKeyPair: serverKey)

        let acceptTask = Task {
            for await connection in listener.connections {
                return connection
            }
            throw WebTransportTestError.connectionStreamClosed
        }

        let parsed = try WebTransportAddressParser.parse(listener.localAddress, requireCertificateHash: true)
        let dnsDialAddress = Multiaddr(uncheckedProtocols: [
            .dns4("localhost"),
            .udp(parsed.port),
            .quicV1,
            .webtransport,
            .certhash(parsed.certificateHashes[0]),
            .certhash(parsed.certificateHashes[1]),
            .p2p(serverKey.peerID),
        ])

        let clientConnection = try await clientTransport.dialSecured(dnsDialAddress, localKeyPair: clientKey)
        let serverConnection = try await acceptTask.value

        try await clientConnection.close()
        try await serverConnection.close()
        try await listener.close()
    }

    @Test("listener localAddress updates cert hashes after rotation", .timeLimit(.minutes(1)))
    func listenerAddressRotatesHashes() async throws {
        let serverKey = KeyPair.generateEd25519()
        let transport = WebTransportTransport(
            configuration: WebTransportConfiguration(
                certRotationInterval: .seconds(1),
                connectionTimeout: .seconds(10)
            )
        )

        let listenAddress = try Multiaddr("/ip4/127.0.0.1/udp/0/quic-v1/webtransport")
        let listener = try await transport.listenSecured(listenAddress, localKeyPair: serverKey)

        let initial = try WebTransportAddressParser.parse(listener.localAddress, requireCertificateHash: true)
        try await Task.sleep(for: .seconds(3))
        let updated = try WebTransportAddressParser.parse(listener.localAddress, requireCertificateHash: true)

        #expect(initial.certificateHashes.count == 2)
        #expect(updated.certificateHashes.count == 2)
        #expect(initial.certificateHashes != updated.certificateHashes)

        try await listener.close()
    }
}
