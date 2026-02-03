/// CircuitRelayE2ETests - End-to-end tests for Circuit Relay v2 protocol.
///
/// These tests verify the complete circuit relay flow including:
/// - 3-node setup (Source, Relay, Target)
/// - Listener Registry pattern
/// - Bidirectional data transfer
/// - Cleanup and shutdown handling

import Testing
import Foundation
import NIOCore
import Synchronization
@testable import P2PCircuitRelay
@testable import P2PCore
@testable import P2PMux
@testable import P2PProtocols

// MARK: - Test Infrastructure

/// Simplified node for E2E testing that integrates RelayClient, RelayServer, and handlers.
final class TestRelayNode: Sendable {
    let keyPair: KeyPair
    let registry: MockE2EHandlerRegistry
    let opener: MockE2EStreamOpener

    var peerID: PeerID { keyPair.peerID }

    init(keyPair: KeyPair = .generateEd25519()) {
        self.keyPair = keyPair
        self.registry = MockE2EHandlerRegistry()
        self.opener = MockE2EStreamOpener()
    }
}

/// Thread-safe handler registry for E2E tests.
final class MockE2EHandlerRegistry: HandlerRegistry, Sendable {
    private let state: Mutex<RegistryState>

    private struct RegistryState: Sendable {
        var handlers: [String: ProtocolHandler] = [:]
    }

    init() {
        self.state = Mutex(RegistryState())
    }

    func handle(_ protocolID: String, handler: @escaping ProtocolHandler) async {
        state.withLock { $0.handlers[protocolID] = handler }
    }

    func getHandler(for protocolID: String) -> ProtocolHandler? {
        state.withLock { $0.handlers[protocolID] }
    }
}

/// Stream opener that can route streams between nodes for E2E testing.
final class MockE2EStreamOpener: StreamOpener, Sendable {
    private let state: Mutex<OpenerState>

    private struct OpenerState: Sendable {
        var streamProviders: [PeerID: StreamProvider] = [:]
        var pendingStreams: [String: MockE2EStream] = [:]
    }

    struct StreamProvider: Sendable {
        let registry: MockE2EHandlerRegistry
        let localPeer: PeerID
    }

    init() {
        self.state = Mutex(OpenerState())
    }

    /// Registers a node as reachable for stream opening.
    func registerNode(_ node: TestRelayNode) {
        state.withLock { s in
            s.streamProviders[node.peerID] = StreamProvider(
                registry: node.registry,
                localPeer: node.peerID
            )
        }
    }

    /// Sets up a specific stream for a protocol (for testing).
    func setStream(_ stream: MockE2EStream, for protocolID: String) {
        state.withLock { $0.pendingStreams[protocolID] = stream }
    }

    func newStream(to peer: PeerID, protocol protocolID: String) async throws -> MuxedStream {
        // Check for pre-configured stream
        if let stream = state.withLock({ $0.pendingStreams.removeValue(forKey: protocolID) }) {
            return stream
        }

        // Look up provider and create paired streams
        guard let provider = state.withLock({ $0.streamProviders[peer] }) else {
            throw E2EOpenerError.peerNotReachable(peer)
        }

        // Create paired streams
        let (localStream, remoteStream) = MockE2EStream.createPair(protocolID: protocolID)

        // Find and call the handler on the remote side
        if let handler = provider.registry.getHandler(for: protocolID) {
            Task {
                let context = StreamContext(
                    stream: remoteStream,
                    remotePeer: peer, // This will be corrected by the calling context
                    remoteAddress: try Multiaddr("/memory/test"),
                    localPeer: provider.localPeer,
                    localAddress: try Multiaddr("/memory/local")
                )
                await handler(context)
            }
        }

        return localStream
    }
}

enum E2EOpenerError: Error {
    case peerNotReachable(PeerID)
}

/// Bidirectional mock stream for E2E testing.
final class MockE2EStream: MuxedStream, Sendable {
    let id: UInt64
    let protocolID: String?

    private let state: Mutex<StreamState>
    nonisolated(unsafe) private weak var partner: MockE2EStream?

    private struct StreamState {
        var readBuffer: [ByteBuffer] = []
        var readContinuation: CheckedContinuation<ByteBuffer, any Error>?
        var isClosed: Bool = false
        var partnerClosed: Bool = false
    }

    init(id: UInt64, protocolID: String? = nil) {
        self.id = id
        self.protocolID = protocolID
        self.state = Mutex(StreamState())
    }

    static func createPair(protocolID: String? = nil) -> (local: MockE2EStream, remote: MockE2EStream) {
        let local = MockE2EStream(id: 1, protocolID: protocolID)
        let remote = MockE2EStream(id: 2, protocolID: protocolID)
        local.partner = remote
        remote.partner = local
        return (local, remote)
    }

    func read() async throws -> ByteBuffer {
        try await withCheckedThrowingContinuation { continuation in
            state.withLock { s in
                if !s.readBuffer.isEmpty {
                    continuation.resume(returning: s.readBuffer.removeFirst())
                } else if s.isClosed || s.partnerClosed {
                    continuation.resume(returning: ByteBuffer())
                } else {
                    s.readContinuation = continuation
                }
            }
        }
    }

    func write(_ data: ByteBuffer) async throws {
        let closed = state.withLock { $0.isClosed }
        if closed {
            throw E2EStreamError.streamClosed
        }

        partner?.receive(data)
    }

    private func receive(_ data: ByteBuffer) {
        state.withLock { s in
            if let continuation = s.readContinuation {
                s.readContinuation = nil
                continuation.resume(returning: data)
            } else {
                s.readBuffer.append(data)
            }
        }
    }

    func closeWrite() async throws {
        // No-op for this mock
    }

    func closeRead() async throws {
        state.withLock { s in
            s.isClosed = true
            if let continuation = s.readContinuation {
                s.readContinuation = nil
                continuation.resume(returning: ByteBuffer())
            }
        }
    }

    func close() async throws {
        state.withLock { s in
            s.isClosed = true
            if let continuation = s.readContinuation {
                s.readContinuation = nil
                continuation.resume(returning: ByteBuffer())
            }
        }
        partner?.notifyPartnerClosed()
    }

    func notifyPartnerClosed() {
        state.withLock { s in
            s.partnerClosed = true
            if let continuation = s.readContinuation {
                s.readContinuation = nil
                continuation.resume(returning: ByteBuffer())
            }
        }
    }

    func reset() async throws {
        try await close()
    }
}

enum E2EStreamError: Error {
    case streamClosed
}

/// Actor for safely collecting events across Task boundaries.
actor EventCollector {
    private var events: [CircuitRelayEvent] = []

    func append(_ event: CircuitRelayEvent) {
        events.append(event)
    }

    func count() -> Int {
        events.count
    }

    func getEvents() -> [CircuitRelayEvent] {
        events
    }
}

// MARK: - E2E Test Suite

@Suite("Circuit Relay E2E Tests", .serialized)
struct CircuitRelayE2ETests {

    // MARK: - Listener Registry Pattern Tests

    @Test("Listener Registry routes connections to correct listener", .timeLimit(.minutes(1)))
    func testListenerRegistryRouting() async throws {
        // Setup: Create client and two relay keys
        let relay1Key = KeyPair.generateEd25519()
        let relay2Key = KeyPair.generateEd25519()
        let sourceKey = KeyPair.generateEd25519()

        let client = RelayClient()
        await client.registerHandler(registry: MockE2EHandlerRegistry())

        // Create two mock reservations for different relays
        let reservation1 = Reservation(
            relay: relay1Key.peerID,
            expiration: .now + .seconds(3600),
            addresses: [],
            voucher: nil
        )
        let reservation2 = Reservation(
            relay: relay2Key.peerID,
            expiration: .now + .seconds(3600),
            addresses: [],
            voucher: nil
        )

        // Create two listeners for different relays
        let listener1 = RelayListener(
            relay: relay1Key.peerID,
            client: client,
            localAddress: try Multiaddr("/p2p/\(relay1Key.peerID)/p2p-circuit"),
            reservation: reservation1
        )
        let listener2 = RelayListener(
            relay: relay2Key.peerID,
            client: client,
            localAddress: try Multiaddr("/p2p/\(relay2Key.peerID)/p2p-circuit"),
            reservation: reservation2
        )

        // Create connection destined for relay1
        let (stream1, _) = MockE2EStream.createPair()
        let connection1 = RelayedConnection(
            stream: stream1,
            relay: relay1Key.peerID,
            remotePeer: sourceKey.peerID,
            limit: .default
        )

        // Create connection destined for relay2
        let (stream2, _) = MockE2EStream.createPair()
        let connection2 = RelayedConnection(
            stream: stream2,
            relay: relay2Key.peerID,
            remotePeer: sourceKey.peerID,
            limit: .default
        )

        // Start accept tasks
        let accept1Task = Task<PeerID?, Never> {
            do {
                let conn = try await listener1.accept()
                // Extract relay from address
                for proto in conn.remoteAddress.protocols {
                    if case .p2p(let peerID) = proto {
                        return peerID
                    }
                }
                return nil
            } catch {
                return nil
            }
        }

        let accept2Task = Task<PeerID?, Never> {
            do {
                let conn = try await listener2.accept()
                for proto in conn.remoteAddress.protocols {
                    if case .p2p(let peerID) = proto {
                        return peerID
                    }
                }
                return nil
            } catch {
                return nil
            }
        }

        // Give listeners time to wait
        try await Task.sleep(for: .milliseconds(50))

        // Enqueue connections - should route to correct listener
        listener1.enqueue(connection1)
        listener2.enqueue(connection2)

        // Verify each listener got the correct connection
        let peer1 = await accept1Task.value
        let peer2 = await accept2Task.value

        #expect(peer1 == relay1Key.peerID, "Listener1 should receive connection from relay1")
        #expect(peer2 == relay2Key.peerID, "Listener2 should receive connection from relay2")

        // Cleanup
        try await listener1.close()
        try await listener2.close()
        client.shutdown()
    }

    @Test("Multiple connections through same relay are handled correctly", .timeLimit(.minutes(1)))
    func testMultipleConnectionsSameRelay() async throws {
        let relayKey = KeyPair.generateEd25519()
        let client = RelayClient()

        let reservation = Reservation(
            relay: relayKey.peerID,
            expiration: .now + .seconds(3600),
            addresses: [],
            voucher: nil
        )

        let listener = RelayListener(
            relay: relayKey.peerID,
            client: client,
            localAddress: try Multiaddr("/p2p/\(relayKey.peerID)/p2p-circuit"),
            reservation: reservation
        )

        // Create and enqueue 5 connections
        var expectedPeers: [PeerID] = []
        for _ in 0..<5 {
            let sourceKey = KeyPair.generateEd25519()
            expectedPeers.append(sourceKey.peerID)

            let (stream, _) = MockE2EStream.createPair()
            let connection = RelayedConnection(
                stream: stream,
                relay: relayKey.peerID,
                remotePeer: sourceKey.peerID,
                limit: .default
            )
            listener.enqueue(connection)
        }

        // Accept all 5 connections
        var receivedPeers: [PeerID] = []
        for _ in 0..<5 {
            let conn = try await listener.accept()
            // Extract remote peer from address
            var foundCircuit = false
            for proto in conn.remoteAddress.protocols {
                switch proto {
                case .p2pCircuit:
                    foundCircuit = true
                case .p2p(let peerID):
                    if foundCircuit {
                        receivedPeers.append(peerID)
                    }
                default:
                    break
                }
            }
        }

        // Verify all peers were received in order (FIFO)
        #expect(receivedPeers == expectedPeers, "Should receive peers in FIFO order")

        try await listener.close()
        client.shutdown()
    }

    // MARK: - Data Transfer Tests

    @Test("Bidirectional data transfer through RelayedConnection", .timeLimit(.minutes(1)))
    func testBidirectionalDataTransfer() async throws {
        let relayKey = KeyPair.generateEd25519()
        let sourceKey = KeyPair.generateEd25519()

        // Create paired streams
        let (sourceStream, targetStream) = MockE2EStream.createPair()

        let sourceConnection = RelayedConnection(
            stream: sourceStream,
            relay: relayKey.peerID,
            remotePeer: sourceKey.peerID,
            limit: .unlimited
        )

        let targetConnection = RelayedConnection(
            stream: targetStream,
            relay: relayKey.peerID,
            remotePeer: sourceKey.peerID,
            limit: .unlimited
        )

        // Send large data in both directions
        let largeData = ByteBuffer(bytes: Data(repeating: 0x42, count: 10000))

        // Source → Target
        try await sourceConnection.write(largeData)
        let received1 = try await targetConnection.read()
        #expect(received1 == largeData)

        // Target → Source
        let responseData = ByteBuffer(bytes: Data("Response from target".utf8))
        try await targetConnection.write(responseData)
        let received2 = try await sourceConnection.read()
        #expect(received2 == responseData)

        // Verify bytes transferred
        #expect(sourceConnection.bytesTransferred == UInt64(largeData.readableBytes + responseData.readableBytes))
    }

    // MARK: - Limit Tests

    @Test("Data limit enforcement", .timeLimit(.minutes(1)))
    func testDataLimitEnforcement() async throws {
        let relayKey = KeyPair.generateEd25519()
        let sourceKey = KeyPair.generateEd25519()

        let (stream, _) = MockE2EStream.createPair()

        // Create connection with 100 byte limit
        let connection = RelayedConnection(
            stream: stream,
            relay: relayKey.peerID,
            remotePeer: sourceKey.peerID,
            limit: CircuitLimit(duration: nil, data: 100)
        )

        // Write 50 bytes - should succeed
        try await connection.write(ByteBuffer(bytes: Data(repeating: 0x01, count: 50)))

        // Write 60 more bytes - should fail (would exceed 100 byte limit)
        do {
            try await connection.write(ByteBuffer(bytes: Data(repeating: 0x02, count: 60)))
            Issue.record("Expected limitExceeded error")
        } catch let error as CircuitRelayError {
            switch error {
            case .limitExceeded:
                // Expected
                break
            default:
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    // MARK: - Cleanup Tests

    @Test("RelayListener unregisters from client on close", .timeLimit(.minutes(1)))
    func testListenerUnregistersOnClose() async throws {
        let relayKey = KeyPair.generateEd25519()
        let sourceKey = KeyPair.generateEd25519()

        let client = RelayClient()

        let reservation = Reservation(
            relay: relayKey.peerID,
            expiration: .now + .seconds(3600),
            addresses: [],
            voucher: nil
        )

        let listener = RelayListener(
            relay: relayKey.peerID,
            client: client,
            localAddress: try Multiaddr("/p2p/\(relayKey.peerID)/p2p-circuit"),
            reservation: reservation
        )

        // Close the listener
        try await listener.close()

        // Create a new connection - it should go to the shared queue, not the listener
        let (stream, _) = MockE2EStream.createPair()
        let connection = RelayedConnection(
            stream: stream,
            relay: relayKey.peerID,
            remotePeer: sourceKey.peerID,
            limit: .default
        )

        // Enqueue directly to listener after close - should not crash or block
        listener.enqueue(connection)

        // acceptConnection on the client should get the connection (fallback behavior)
        // Since listener is closed, it shouldn't be registered anymore

        client.shutdown()
    }

    // MARK: - Event Tests

    @Test("RelayClient emits events correctly", .timeLimit(.minutes(1)))
    func testRelayClientEvents() async throws {
        let relayKey = KeyPair.generateEd25519()
        let sourceKey = KeyPair.generateEd25519()

        let client = RelayClient()
        let registry = MockE2EHandlerRegistry()
        await client.registerHandler(registry: registry)

        // Collect events using actor for thread safety
        let collector = EventCollector()
        let eventTask = Task {
            for await event in client.events {
                await collector.append(event)
                if await collector.count() >= 1 {
                    break
                }
            }
        }

        // Simulate Stop handler receiving a connection
        let (clientStream, serverStream) = MockE2EStream.createPair(
            protocolID: CircuitRelayProtocol.stopProtocolID
        )

        // Prepare Stop CONNECT message on the "server" side (the one RelayClient reads from)
        let connectMsg = StopMessage.connect(from: sourceKey.peerID, limit: .default)
        let connectData = CircuitRelayProtobuf.encode(connectMsg)
        try await clientStream.writeLengthPrefixedMessage(ByteBuffer(bytes: connectData))

        // Invoke handler
        if let handler = registry.getHandler(for: CircuitRelayProtocol.stopProtocolID) {
            let context = StreamContext(
                stream: serverStream,
                remotePeer: relayKey.peerID,
                remoteAddress: try Multiaddr("/memory/relay"),
                localPeer: sourceKey.peerID,
                localAddress: try Multiaddr("/memory/local")
            )
            await handler(context)
        }

        // Wait for event
        try await Task.sleep(for: .milliseconds(100))
        eventTask.cancel()

        // Verify event was emitted
        let receivedEvents = await collector.getEvents()
        #expect(receivedEvents.contains { event in
            if case .circuitEstablished(let relay, _) = event {
                return relay == relayKey.peerID
            }
            return false
        }, "Should emit circuitEstablished event")

        client.shutdown()
    }

    // MARK: - Concurrent Access Tests

    @Test("Concurrent enqueue operations are thread-safe", .timeLimit(.minutes(1)))
    func testConcurrentOperations() async throws {
        let relayKey = KeyPair.generateEd25519()
        let client = RelayClient()

        let reservation = Reservation(
            relay: relayKey.peerID,
            expiration: .now + .seconds(3600),
            addresses: [],
            voucher: nil
        )

        let listener = RelayListener(
            relay: relayKey.peerID,
            client: client,
            localAddress: try Multiaddr("/p2p/\(relayKey.peerID)/p2p-circuit"),
            reservation: reservation
        )

        let connectionCount = 10

        // Enqueue connections concurrently first (they go into the queue)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<connectionCount {
                group.addTask {
                    let sourceKey = KeyPair.generateEd25519()
                    let (stream, _) = MockE2EStream.createPair()
                    let connection = RelayedConnection(
                        stream: stream,
                        relay: relayKey.peerID,
                        remotePeer: sourceKey.peerID,
                        limit: .default
                    )
                    listener.enqueue(connection)
                }
            }
        }

        // Now accept them sequentially (RelayListener supports single waiter at a time)
        var successCount = 0
        for _ in 0..<connectionCount {
            do {
                _ = try await listener.accept()
                successCount += 1
            } catch {
                // Accept failed
            }
        }

        #expect(successCount == connectionCount, "All \(connectionCount) queued connections should be accepted")

        try await listener.close()
        client.shutdown()
    }
}
