import Testing
import Foundation
@testable import P2P
@testable import P2PCore
@testable import P2PSecurity
@testable import P2PMux

@Suite("P2P Integration Tests")
struct P2PTests {

    // MARK: - NodeConfiguration Tests

    @Test("NodeConfiguration initializes with defaults")
    func testNodeConfigurationDefaults() {
        let config = NodeConfiguration()

        #expect(config.listenAddresses.isEmpty)
        #expect(config.transports.isEmpty)
        #expect(config.security.isEmpty)
        #expect(config.muxers.isEmpty)
        #expect(config.pool.limits.highWatermark == 100)
        #expect(config.pool.limits.maxConnectionsPerPeer == 2)
        #expect(config.pool.idleTimeout == .seconds(60))
    }

    @Test("NodeConfiguration accepts custom values")
    func testNodeConfigurationCustom() {
        let keyPair = KeyPair.generateEd25519()
        let config = NodeConfiguration(
            keyPair: keyPair,
            listenAddresses: [Multiaddr.tcp(host: "127.0.0.1", port: 4001)],
            pool: PoolConfiguration(
                limits: ConnectionLimits(highWatermark: 50, lowWatermark: 40, maxConnectionsPerPeer: 1),
                idleTimeout: .seconds(30)
            )
        )

        #expect(config.keyPair.peerID == keyPair.peerID)
        #expect(config.listenAddresses.count == 1)
        #expect(config.pool.limits.highWatermark == 50)
        #expect(config.pool.limits.maxConnectionsPerPeer == 1)
        #expect(config.pool.idleTimeout == .seconds(30))
    }

    // MARK: - Node Initialization Tests

    @Test("Node initializes with configuration")
    func testNodeInitialization() async {
        let keyPair = KeyPair.generateEd25519()
        let config = NodeConfiguration(keyPair: keyPair)
        let node = Node(configuration: config)

        let peerID = await node.peerID
        #expect(peerID == keyPair.peerID)
    }

    @Test("Node starts without listeners when no addresses configured")
    func testNodeStartsWithoutListeners() async throws {
        let config = NodeConfiguration()
        let node = Node(configuration: config)

        try await node.start()
        // Should not throw, just do nothing
        await node.stop()
    }

    @Test("Node registers protocol handlers")
    func testNodeProtocolHandlers() async {
        let config = NodeConfiguration()
        let node = Node(configuration: config)

        await node.handle("/test/1.0.0") { _ in }
        await node.handle("/chat/1.0.0") { _ in }

        let protocols = await node.supportedProtocols
        #expect(protocols.contains("/test/1.0.0"))
        #expect(protocols.contains("/chat/1.0.0"))
        #expect(protocols.count == 2)
    }

    @Test("Node reports no connected peers initially")
    func testNodeNoConnectedPeers() async {
        let config = NodeConfiguration()
        let node = Node(configuration: config)

        let peers = await node.connectedPeers
        #expect(peers.isEmpty)
        #expect(await node.connectionCount == 0)
    }

    // MARK: - ConnectionUpgrader Tests

    @Test("NegotiatingUpgrader initializes with security and muxers")
    func testNegotiatingUpgraderInit() {
        let upgrader = NegotiatingUpgrader(
            security: [MockSecurityUpgrader(id: "/noise")],
            muxers: [MockMuxer(id: "/yamux/1.0.0")]
        )
        // Just verify it compiles and doesn't crash
        _ = upgrader
    }

    @Test("NegotiatingUpgrader throws when no security upgraders")
    func testUpgraderNoSecurity() async {
        let upgrader = NegotiatingUpgrader(security: [], muxers: [MockMuxer(id: "/yamux/1.0.0")])
        let raw = MockRawConnection()

        await #expect(throws: UpgradeError.self) {
            _ = try await upgrader.upgrade(
                raw,
                localKeyPair: .generateEd25519(),
                role: .initiator,
                expectedPeer: nil
            )
        }
    }

    // MARK: - UpgradeResult Tests

    @Test("UpgradeResult stores negotiated protocols")
    func testUpgradeResult() {
        let mockConnection = MockMuxedConnection()
        let result = UpgradeResult(
            connection: mockConnection,
            securityProtocol: "/noise",
            muxerProtocol: "/yamux/1.0.0"
        )

        #expect(result.securityProtocol == "/noise")
        #expect(result.muxerProtocol == "/yamux/1.0.0")
    }

    // MARK: - NodeEvent Tests

    @Test("NodeEvent peer connected")
    func testNodeEventPeerConnected() {
        let peerID = KeyPair.generateEd25519().peerID
        let event = NodeEvent.peerConnected(peerID)

        if case .peerConnected(let peer) = event {
            #expect(peer == peerID)
        } else {
            Issue.record("Expected peerConnected event")
        }
    }

    @Test("NodeEvent peer disconnected")
    func testNodeEventPeerDisconnected() {
        let peerID = KeyPair.generateEd25519().peerID
        let event = NodeEvent.peerDisconnected(peerID)

        if case .peerDisconnected(let peer) = event {
            #expect(peer == peerID)
        } else {
            Issue.record("Expected peerDisconnected event")
        }
    }

    // MARK: - Multiaddr Extension Tests

    @Test("Multiaddr extracts PeerID when present")
    func testMultiaddrPeerIDExtraction() throws {
        let peerID = KeyPair.generateEd25519().peerID
        let addr = try Multiaddr("/ip4/127.0.0.1/tcp/4001/p2p/\(peerID)")

        #expect(addr.peerID == peerID)
    }

    @Test("Multiaddr returns nil when no PeerID")
    func testMultiaddrNoPeerID() {
        let addr = Multiaddr.tcp(host: "127.0.0.1", port: 4001)
        let extractedPeerID: PeerID? = addr.peerID
        #expect(extractedPeerID == nil)
    }
}

// MARK: - Mock Types for Testing

/// Mock security upgrader for testing
private struct MockSecurityUpgrader: SecurityUpgrader {
    let protocolID: String

    init(id: String) {
        self.protocolID = id
    }

    func secure(
        _ connection: any RawConnection,
        localKeyPair: KeyPair,
        as role: SecurityRole,
        expectedPeer: PeerID?
    ) async throws -> any SecuredConnection {
        fatalError("Not implemented in mock")
    }
}

/// Mock muxer for testing
private struct MockMuxer: Muxer {
    let protocolID: String

    init(id: String) {
        self.protocolID = id
    }

    func multiplex(
        _ connection: any SecuredConnection,
        isInitiator: Bool
    ) async throws -> MuxedConnection {
        fatalError("Not implemented in mock")
    }
}

/// Mock raw connection for testing
private final class MockRawConnection: RawConnection, Sendable {
    var localAddress: Multiaddr? { nil }
    var remoteAddress: Multiaddr { Multiaddr.tcp(host: "127.0.0.1", port: 4001) }

    func read() async throws -> Data {
        return Data()
    }

    func write(_ data: Data) async throws {}

    func close() async throws {}
}

/// Mock muxed connection for testing
private final class MockMuxedConnection: MuxedConnection, Sendable {
    let localPeer: PeerID = KeyPair.generateEd25519().peerID
    let remotePeer: PeerID = KeyPair.generateEd25519().peerID
    let localAddress: Multiaddr? = Multiaddr.tcp(host: "127.0.0.1", port: 4001)
    let remoteAddress: Multiaddr = Multiaddr.tcp(host: "127.0.0.1", port: 4002)

    func newStream() async throws -> MuxedStream {
        fatalError("Not implemented in mock")
    }

    func acceptStream() async throws -> MuxedStream {
        fatalError("Not implemented in mock")
    }

    var inboundStreams: AsyncStream<MuxedStream> {
        AsyncStream { _ in }
    }

    func close() async throws {}
}
