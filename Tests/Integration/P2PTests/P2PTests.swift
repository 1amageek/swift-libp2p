import Testing
import Foundation
import NIOCore
import Synchronization
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
        await node.shutdown()
    }

    @Test("Node registers protocol handlers")
    func testNodeProtocolHandlers() async {
        let config = NodeConfiguration()
        let node = Node(configuration: config)

        await node.handle("/test/1.0.0") { _ in }
        await node.handle("/chat/1.0.0") { _ in }

        let protocols = await node.supportedProtocols()
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

    @Test("Node exposes trim report snapshot")
    func testNodeConnectionTrimReport() async {
        let node = Node(configuration: .init())

        let report = await node.connectionTrimReport()
        #expect(report.activeConnectionCount == 0)
        #expect(report.totalEntryCount == 0)
        #expect(report.highWatermark == 100)
        #expect(report.lowWatermark == 80)
        #expect(report.targetTrimCount == 0)
        #expect(report.selectedCount == 0)
        #expect(report.trimmableCount == 0)
        #expect(!report.requiresTrim)
        #expect(report.candidates.isEmpty)
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

    @Test("ConnectionEvent trimmedWithContext supports structured metadata")
    func testConnectionEventTrimmedStructuredContext() {
        let peerID = KeyPair.generateEd25519().peerID
        let context = ConnectionTrimmedContext(
            rank: 1,
            tagCount: 2,
            idleDuration: .seconds(15),
            direction: .inbound
        )
        let event = ConnectionEvent.trimmedWithContext(peer: peerID, context: context)

        #expect(event.peer == peerID)
        #expect(event.isNegative)
        #expect(event.trimContext?.rank == 1)
        #expect(event.trimContext?.tagCount == 2)
        #expect(event.trimContext?.direction == .inbound)
        #expect(event.trimReason != nil)
    }

    @Test("ConnectionEvent trimmed legacy reason remains available")
    func testConnectionEventTrimmedLegacyReason() {
        let peerID = KeyPair.generateEd25519().peerID
        let reason = "Connection limit exceeded"
        let event = ConnectionEvent.trimmed(peer: peerID, reason: reason)

        #expect(event.peer == peerID)
        #expect(event.isNegative)
        #expect(event.trimContext == nil)
        #expect(event.trimReason == reason)
    }

    @Test("ConnectionEvent trimConstrained exposes structured counts")
    func testConnectionEventTrimConstrained() {
        let event = ConnectionEvent.trimConstrained(
            target: 3,
            selected: 1,
            trimmable: 1,
            active: 5
        )

        #expect(event.peer == nil)
        #expect(event.isNegative)
        #expect(event.trimContext == nil)
        #expect(event.trimReason == nil)
        #expect(event.description.contains("trimConstrained"))
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

@Suite("Buffered Stream Negotiation Tests")
struct BufferedStreamNegotiationTests {

    @Test("BufferedStreamReader drains remainder from coalesced read")
    func bufferedReaderDrainRemainder() async throws {
        let encoded = MultistreamSelect.encode("/test/1.0.0")
        let extra = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let stream = QueueMuxedStream(reads: [ByteBuffer(bytes: encoded + extra)])
        let reader = BufferedStreamReader(stream: stream)

        let message = try await reader.readMessage()
        let remainder = reader.drainRemainder()

        #expect(message == encoded)
        #expect(remainder == extra)
        #expect(reader.drainRemainder().isEmpty)
    }

    @Test("BufferedMuxedStream returns initial bytes before underlying stream")
    func bufferedMuxedStreamReadsInitialBufferFirst() async throws {
        let first = Data([0x01, 0x02, 0x03])
        let second = Data([0xAA, 0xBB])
        let underlying = QueueMuxedStream(reads: [ByteBuffer(bytes: second)])
        let stream = BufferedMuxedStream(stream: underlying, initialBuffer: first)

        let firstRead = try await stream.read()
        let secondRead = try await stream.read()

        #expect(Data(buffer: firstRead) == first)
        #expect(Data(buffer: secondRead) == second)
    }
}

@Suite("Upgrade and Node Error Tests")
struct UpgradeAndNodeErrorTests {

    @Test("NegotiatingUpgrader throws noMuxers after successful security negotiation")
    func upgraderNoMuxers() async throws {
        let securityProtocol = "/mock-security/1.0.0"
        let handshakeResponse =
            MultistreamSelect.encode(MultistreamSelect.protocolID)
            + MultistreamSelect.encode(securityProtocol)
        let raw = ScriptedRawConnection(reads: [Data(handshakeResponse)])
        let upgrader = NegotiatingUpgrader(
            security: [PassthroughSecurityUpgrader(id: securityProtocol)],
            muxers: []
        )

        do {
            _ = try await upgrader.upgrade(
                raw,
                localKeyPair: .generateEd25519(),
                role: .initiator,
                expectedPeer: nil
            )
            Issue.record("Expected noMuxers")
        } catch let error as UpgradeError {
            guard case .noMuxers = error else {
                Issue.record("Expected noMuxers but got \(error)")
                return
            }
        }
    }

    @Test("NegotiatingUpgrader throws connectionClosed when peer closes during negotiation")
    func upgraderConnectionClosed() async throws {
        let raw = ScriptedRawConnection(reads: [Data()])
        let upgrader = NegotiatingUpgrader(
            security: [PassthroughSecurityUpgrader(id: "/mock-security/1.0.0")],
            muxers: [MockMuxer(id: "/yamux/1.0.0")]
        )

        do {
            _ = try await upgrader.upgrade(
                raw,
                localKeyPair: .generateEd25519(),
                role: .initiator,
                expectedPeer: nil
            )
            Issue.record("Expected connectionClosed")
        } catch let error as UpgradeError {
            guard case .connectionClosed = error else {
                Issue.record("Expected connectionClosed but got \(error)")
                return
            }
        }
    }

    @Test("NegotiatingUpgrader throws messageTooLarge on oversized negotiation frame")
    func upgraderMessageTooLarge() async throws {
        let oversizedLength = Varint.encode(70_000)
        let raw = ScriptedRawConnection(reads: [oversizedLength])
        let upgrader = NegotiatingUpgrader(
            security: [PassthroughSecurityUpgrader(id: "/mock-security/1.0.0")],
            muxers: [MockMuxer(id: "/yamux/1.0.0")]
        )

        do {
            _ = try await upgrader.upgrade(
                raw,
                localKeyPair: .generateEd25519(),
                role: .initiator,
                expectedPeer: nil
            )
            Issue.record("Expected messageTooLarge")
        } catch let error as UpgradeError {
            switch error {
            case .messageTooLarge(let size, let max):
                #expect(size > max)
            default:
                Issue.record("Expected messageTooLarge but got \(error)")
            }
        }
    }

    @Test("NegotiatingUpgrader throws invalidVarint on malformed length prefix")
    func upgraderInvalidVarint() async throws {
        let malformedVarint = Data(repeating: 0x80, count: 11)
        let raw = ScriptedRawConnection(reads: [malformedVarint])
        let upgrader = NegotiatingUpgrader(
            security: [PassthroughSecurityUpgrader(id: "/mock-security/1.0.0")],
            muxers: [MockMuxer(id: "/yamux/1.0.0")]
        )

        do {
            _ = try await upgrader.upgrade(
                raw,
                localKeyPair: .generateEd25519(),
                role: .initiator,
                expectedPeer: nil
            )
            Issue.record("Expected invalidVarint")
        } catch let error as UpgradeError {
            guard case .invalidVarint = error else {
                Issue.record("Expected invalidVarint but got \(error)")
                return
            }
        }
    }

    @Test("Node.connect throws noSuitableTransport when no transport can dial")
    func nodeNoSuitableTransport() async throws {
        let node = Node(configuration: .init(transports: [], security: [], muxers: []))
        let address = Multiaddr.tcp(host: "127.0.0.1", port: 4001)

        do {
            _ = try await node.connect(to: address)
            Issue.record("Expected noSuitableTransport")
        } catch let error as NodeError {
            guard case .noSuitableTransport = error else {
                Issue.record("Expected noSuitableTransport but got \(error)")
                return
            }
        }
    }

    @Test("Node.newStream throws notConnected for unknown peer")
    func nodeNotConnected() async throws {
        let node = Node(configuration: .init(transports: [], security: [], muxers: []))
        let peer = KeyPair.generateEd25519().peerID

        do {
            _ = try await node.newStream(to: peer, protocol: "/test/1.0.0")
            Issue.record("Expected notConnected")
        } catch let error as NodeError {
            guard case .notConnected(let gotPeer) = error else {
                Issue.record("Expected notConnected but got \(error)")
                return
            }
            #expect(gotPeer == peer)
        }
    }

    @Test("NodeError associated values are preserved")
    func nodeErrorAssociatedValues() {
        let peer = KeyPair.generateEd25519().peerID
        let cases: [NodeError] = [
            .noSuitableTransport,
            .notConnected(peer),
            .protocolNegotiationFailed,
            .streamClosed,
            .connectionLimitReached,
            .connectionGated(stage: .secured),
            .nodeNotRunning,
            .messageTooLarge(size: 1024, max: 512),
            .resourceLimitExceeded(scope: "peer", resource: "streams")
        ]

        for error in cases {
            switch error {
            case .notConnected(let gotPeer):
                #expect(gotPeer == peer)
            case .connectionGated(let stage):
                #expect(stage == .secured)
            case .messageTooLarge(let size, let max):
                #expect(size == 1024)
                #expect(max == 512)
            case .resourceLimitExceeded(let scope, let resource):
                #expect(scope == "peer")
                #expect(resource == "streams")
            default:
                continue
            }
        }
    }

    @Test("UpgradeError associated values are preserved")
    func upgradeErrorAssociatedValues() {
        let cases: [UpgradeError] = [
            .noSecurityUpgraders,
            .noMuxers,
            .securityNegotiationFailed("/noise"),
            .muxerNegotiationFailed("/yamux/1.0.0"),
            .connectionClosed,
            .messageTooLarge(size: 100, max: 64),
            .invalidVarint
        ]

        for error in cases {
            switch error {
            case .securityNegotiationFailed(let protocolID):
                #expect(protocolID == "/noise")
            case .muxerNegotiationFailed(let protocolID):
                #expect(protocolID == "/yamux/1.0.0")
            case .messageTooLarge(let size, let max):
                #expect(size == 100)
                #expect(max == 64)
            default:
                continue
            }
        }
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

    func read() async throws -> ByteBuffer {
        return ByteBuffer()
    }

    func write(_ data: ByteBuffer) async throws {}

    func close() async throws {}
}

/// Queue-based muxed stream for deterministic read behavior in tests.
private final class QueueMuxedStream: MuxedStream, Sendable {
    let id: UInt64 = 1
    let protocolID: String? = nil
    private let queuedReads: Mutex<[ByteBuffer]>

    init(reads: [ByteBuffer]) {
        self.queuedReads = Mutex(reads)
    }

    func read() async throws -> ByteBuffer {
        queuedReads.withLock { reads in
            guard !reads.isEmpty else { return ByteBuffer() }
            return reads.removeFirst()
        }
    }

    func write(_ data: ByteBuffer) async throws {}

    func closeWrite() async throws {}

    func closeRead() async throws {}

    func close() async throws {}

    func reset() async throws {}
}

/// RawConnection with deterministic queued reads for negotiation tests.
private final class ScriptedRawConnection: RawConnection, Sendable {
    var localAddress: Multiaddr? { nil }
    var remoteAddress: Multiaddr { Multiaddr.tcp(host: "127.0.0.1", port: 4001) }
    private let queuedReads: Mutex<[ByteBuffer]>

    init(reads: [Data]) {
        self.queuedReads = Mutex(reads.map { ByteBuffer(bytes: $0) })
    }

    func read() async throws -> ByteBuffer {
        queuedReads.withLock { reads in
            guard !reads.isEmpty else { return ByteBuffer() }
            return reads.removeFirst()
        }
    }

    func write(_ data: ByteBuffer) async throws {}

    func close() async throws {}
}

/// SecurityUpgrader that returns a static secured connection for upgrader pipeline tests.
private struct PassthroughSecurityUpgrader: SecurityUpgrader {
    let protocolID: String
    private let localPeer: PeerID
    private let remotePeer: PeerID

    init(id: String) {
        self.protocolID = id
        self.localPeer = KeyPair.generateEd25519().peerID
        self.remotePeer = KeyPair.generateEd25519().peerID
    }

    func secure(
        _ connection: any RawConnection,
        localKeyPair: KeyPair,
        as role: SecurityRole,
        expectedPeer: PeerID?
    ) async throws -> any SecuredConnection {
        PassthroughSecuredConnection(
            underlying: connection,
            localPeer: localPeer,
            remotePeer: remotePeer
        )
    }
}

private final class PassthroughSecuredConnection: SecuredConnection, Sendable {
    let localPeer: PeerID
    let remotePeer: PeerID
    private let underlying: any RawConnection

    var localAddress: Multiaddr? { underlying.localAddress }
    var remoteAddress: Multiaddr { underlying.remoteAddress }

    init(underlying: any RawConnection, localPeer: PeerID, remotePeer: PeerID) {
        self.underlying = underlying
        self.localPeer = localPeer
        self.remotePeer = remotePeer
    }

    func read() async throws -> ByteBuffer {
        try await underlying.read()
    }

    func write(_ data: ByteBuffer) async throws {
        try await underlying.write(data)
    }

    func close() async throws {
        try await underlying.close()
    }
}

/// Mock muxed connection for testing
private final class MockMuxedConnection: MuxedConnection, Sendable {
    let localPeer: PeerID = KeyPair.generateEd25519().peerID
    let remotePeer: PeerID = KeyPair.generateEd25519().peerID
    let localAddress: Multiaddr? = Multiaddr.tcp(host: "127.0.0.1", port: 4001)
    let remoteAddress: Multiaddr = Multiaddr.tcp(host: "127.0.0.1", port: 4002)
    var hasActiveStreams: Bool { false }

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
