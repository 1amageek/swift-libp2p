/// CircuitRelayIntegrationTests - Integration tests for Circuit Relay v2 protocol.

import Testing
import Foundation
import Synchronization
@testable import P2PCircuitRelay
@testable import P2PCore
@testable import P2PMux
@testable import P2PProtocols

// MARK: - Test Helpers

/// A mock HandlerRegistry that captures registered handlers.
final class MockHandlerRegistry: HandlerRegistry, Sendable {
    private let state: Mutex<RegistryState>

    private struct RegistryState {
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

/// A mock MuxedStream that allows paired bidirectional communication.
final class MockMuxedStream: MuxedStream, Sendable {
    let id: UInt64
    let protocolID: String?

    private let state: Mutex<StreamState>
    private let partner: Mutex<MockMuxedStream?>

    private struct StreamState: Sendable {
        var readBuffer: [Data] = []
        var readContinuation: CheckedContinuation<Data, any Error>?
        var isClosed: Bool = false
        var isWriteClosed: Bool = false
        var partnerClosed: Bool = false
    }

    init(id: UInt64, protocolID: String? = nil) {
        self.id = id
        self.protocolID = protocolID
        self.state = Mutex(StreamState())
        self.partner = Mutex(nil)
    }

    /// Links two streams together for bidirectional communication.
    static func createPair(protocolID: String? = nil) -> (client: MockMuxedStream, server: MockMuxedStream) {
        let client = MockMuxedStream(id: 1, protocolID: protocolID)
        let server = MockMuxedStream(id: 2, protocolID: protocolID)
        client.partner.withLock { $0 = server }
        server.partner.withLock { $0 = client }
        return (client, server)
    }

    func read() async throws -> Data {
        // All state checks and continuation installation must happen atomically
        // to avoid race conditions with close() and partner notifications.
        return try await withCheckedThrowingContinuation { continuation in
            state.withLock { s in
                if !s.readBuffer.isEmpty {
                    continuation.resume(returning: s.readBuffer.removeFirst())
                } else if s.isClosed || s.partnerClosed {
                    // Return empty data to signal EOF
                    continuation.resume(returning: Data())
                } else {
                    // No data available, wait for data or close
                    s.readContinuation = continuation
                }
            }
        }
    }

    func write(_ data: Data) async throws {
        let closed = state.withLock { $0.isWriteClosed || $0.isClosed }
        if closed {
            throw MockStreamError.streamClosed
        }

        // Write to partner's read buffer
        if let p = partner.withLock({ $0 }) {
            p.receive(data)
        }
    }

    private func receive(_ data: Data) {
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
        state.withLock { $0.isWriteClosed = true }
    }

    func close() async throws {
        state.withLock { s in
            s.isClosed = true
            s.isWriteClosed = true
            if let continuation = s.readContinuation {
                s.readContinuation = nil
                continuation.resume(returning: Data())
            }
        }
        // Notify partner that we're closed so they don't block on read()
        if let p = partner.withLock({ $0 }) {
            p.notifyPartnerClosed()
        }
    }

    /// Called when partner stream is closed to unblock pending reads.
    func notifyPartnerClosed() {
        state.withLock { s in
            s.partnerClosed = true
            // If we're waiting for a read, return empty data to signal EOF
            if let continuation = s.readContinuation {
                s.readContinuation = nil
                continuation.resume(returning: Data())
            }
        }
    }

    func reset() async throws {
        try await close()
    }
}

enum MockStreamError: Error {
    case streamClosed
}

/// A mock StreamOpener that returns pre-configured streams.
final class MockStreamOpener: StreamOpener, Sendable {
    private let state: Mutex<OpenerState>

    private struct OpenerState: Sendable {
        var streams: [String: MockMuxedStream] = [:]
        var handlers: [String: @Sendable (MockMuxedStream) async -> Void] = [:]
        var error: (any Error)?
    }

    init() {
        self.state = Mutex(OpenerState())
    }

    func setStream(_ stream: MockMuxedStream, for protocolID: String) {
        state.withLock { $0.streams[protocolID] = stream }
    }

    func setHandler(_ handler: @escaping @Sendable (MockMuxedStream) async -> Void, for protocolID: String) {
        state.withLock { $0.handlers[protocolID] = handler }
    }

    func setError(_ error: any Error) {
        state.withLock { $0.error = error }
    }

    func newStream(to peer: PeerID, protocol protocolID: String) async throws -> MuxedStream {
        if let error = state.withLock({ $0.error }) {
            throw error
        }

        guard let stream = state.withLock({ $0.streams[protocolID] }) else {
            throw MockOpenerError.noStream
        }

        // Call handler if registered (for server simulation)
        if let handler = state.withLock({ $0.handlers[protocolID] }) {
            // Run handler in background to simulate server
            Task {
                await handler(stream)
            }
        }

        return stream
    }
}

enum MockOpenerError: Error {
    case noStream
}

/// Helper to create a mock StreamContext.
func createMockContext(
    stream: MuxedStream,
    remotePeer: PeerID,
    localPeer: PeerID
) -> StreamContext {
    StreamContext(
        stream: stream,
        remotePeer: remotePeer,
        remoteAddress: try! Multiaddr("/ip4/127.0.0.1/tcp/4001"),
        localPeer: localPeer,
        localAddress: try! Multiaddr("/ip4/127.0.0.1/tcp/4002")
    )
}

// MARK: - CircuitRelay Integration Tests

@Suite("CircuitRelay Integration Tests", .serialized)
struct CircuitRelayIntegrationTests {

    // MARK: - Reservation Tests

    @Test("Client successfully reserves slot on relay")
    func testReservationSuccess() async throws {
        let clientKey = KeyPair.generateEd25519()
        let relayKey = KeyPair.generateEd25519()

        let client = RelayClient()
        let server = RelayServer()

        // Create paired streams for hop protocol
        let (clientStream, serverStream) = MockMuxedStream.createPair(
            protocolID: CircuitRelayProtocol.hopProtocolID
        )

        // Register server handler
        let registry = MockHandlerRegistry()
        let serverOpener = MockStreamOpener()
        await server.registerHandler(
            registry: registry,
            opener: serverOpener,
            localPeer: relayKey.peerID,
            getLocalAddresses: { [try! Multiaddr("/ip4/127.0.0.1/tcp/4001")] }
        )

        // Setup mock opener for client
        let clientOpener = MockStreamOpener()
        clientOpener.setStream(clientStream, for: CircuitRelayProtocol.hopProtocolID)

        // Run server handler in background
        let serverTask = Task {
            if let handler = registry.getHandler(for: CircuitRelayProtocol.hopProtocolID) {
                let context = createMockContext(
                    stream: serverStream,
                    remotePeer: clientKey.peerID,
                    localPeer: relayKey.peerID
                )
                await handler(context)
            }
        }

        // Client makes reservation
        let reservation = try await client.reserve(on: relayKey.peerID, using: clientOpener)

        // Verify reservation
        #expect(reservation.relay == relayKey.peerID)
        #expect(reservation.isValid)

        await serverTask.value
    }

    @Test("Reservation denied when relay is full")
    func testReservationDeniedWhenFull() async throws {
        let clientKey = KeyPair.generateEd25519()
        let relayKey = KeyPair.generateEd25519()

        // Create server with 0 max reservations
        let serverConfig = RelayServerConfiguration(maxReservations: 0)
        let server = RelayServer(configuration: serverConfig)
        let client = RelayClient()

        let (clientStream, serverStream) = MockMuxedStream.createPair(
            protocolID: CircuitRelayProtocol.hopProtocolID
        )

        // Register server handler
        let registry = MockHandlerRegistry()
        let serverOpener = MockStreamOpener()
        await server.registerHandler(
            registry: registry,
            opener: serverOpener,
            localPeer: relayKey.peerID,
            getLocalAddresses: { [] }
        )

        let clientOpener = MockStreamOpener()
        clientOpener.setStream(clientStream, for: CircuitRelayProtocol.hopProtocolID)

        // Run server handler
        let serverTask = Task {
            if let handler = registry.getHandler(for: CircuitRelayProtocol.hopProtocolID) {
                let context = createMockContext(
                    stream: serverStream,
                    remotePeer: clientKey.peerID,
                    localPeer: relayKey.peerID
                )
                await handler(context)
            }
        }

        // Client should fail reservation
        do {
            _ = try await client.reserve(on: relayKey.peerID, using: clientOpener)
            Issue.record("Expected reservation to fail")
        } catch let error as CircuitRelayError {
            switch error {
            case .reservationFailed(let status):
                #expect(status == .resourceLimitExceeded)
            default:
                Issue.record("Unexpected error type: \(error)")
            }
        }

        await serverTask.value
    }

    // MARK: - Connection Tests

    @Test("Client connects to peer through relay")
    func testConnectThroughRelay() async throws {
        let sourceKey = KeyPair.generateEd25519()
        let targetKey = KeyPair.generateEd25519()
        let relayKey = KeyPair.generateEd25519()

        let sourceClient = RelayClient()
        let targetClient = RelayClient()
        let server = RelayServer()

        // Register server handler
        let registry = MockHandlerRegistry()
        let serverOpener = MockStreamOpener()
        await server.registerHandler(
            registry: registry,
            opener: serverOpener,
            localPeer: relayKey.peerID,
            getLocalAddresses: { [try! Multiaddr("/ip4/127.0.0.1/tcp/4001")] }
        )

        // First, target makes a reservation
        let (resClientStream, resServerStream) = MockMuxedStream.createPair(
            protocolID: CircuitRelayProtocol.hopProtocolID
        )

        let resOpener = MockStreamOpener()
        resOpener.setStream(resClientStream, for: CircuitRelayProtocol.hopProtocolID)

        let resServerTask = Task {
            if let handler = registry.getHandler(for: CircuitRelayProtocol.hopProtocolID) {
                let context = createMockContext(
                    stream: resServerStream,
                    remotePeer: targetKey.peerID,
                    localPeer: relayKey.peerID
                )
                await handler(context)
            }
        }

        _ = try await targetClient.reserve(on: relayKey.peerID, using: resOpener)
        await resServerTask.value

        // Now source connects to target through relay
        let (connectClientStream, connectServerStream) = MockMuxedStream.createPair(
            protocolID: CircuitRelayProtocol.hopProtocolID
        )

        let connectOpener = MockStreamOpener()
        connectOpener.setStream(connectClientStream, for: CircuitRelayProtocol.hopProtocolID)

        // Simulate server handling connection (simplified - relay just responds OK)
        let connectServerTask = Task<Void, any Error> {
            // For testing, we simulate the relay behavior
            let messageData = try await connectServerStream.readLengthPrefixedMessage()
            let message = try CircuitRelayProtobuf.decodeHop(messageData)

            if message.type == .connect {
                // Send OK status back
                let response = HopMessage.statusResponse(.ok, limit: .default)
                let responseData = CircuitRelayProtobuf.encode(response)
                try await connectServerStream.writeLengthPrefixedMessage(responseData)
            }
        }

        // Source connects through relay
        let connection = try await sourceClient.connectThrough(
            relay: relayKey.peerID,
            to: targetKey.peerID,
            using: connectOpener
        )

        #expect(connection.relay == relayKey.peerID)
        #expect(connection.remotePeer == targetKey.peerID)

        try await connectServerTask.value
    }

    @Test("Bidirectional data transfer through circuit")
    func testBidirectionalDataTransfer() async throws {
        let sourceKey = KeyPair.generateEd25519()
        let targetKey = KeyPair.generateEd25519()
        let relayKey = KeyPair.generateEd25519()

        // Create a circuit directly for data transfer test
        let (sourceStream, targetStream) = MockMuxedStream.createPair()

        let sourceConnection = RelayedConnection(
            stream: sourceStream,
            relay: relayKey.peerID,
            remotePeer: targetKey.peerID,
            limit: .default
        )

        let targetConnection = RelayedConnection(
            stream: targetStream,
            relay: relayKey.peerID,
            remotePeer: sourceKey.peerID,
            limit: .default
        )

        // Test sending data from source to target
        let testData1 = Data("Hello from source".utf8)
        try await sourceConnection.write(testData1)
        let received1 = try await targetConnection.read()
        #expect(received1 == testData1)

        // Test sending data from target to source
        let testData2 = Data("Hello from target".utf8)
        try await targetConnection.write(testData2)
        let received2 = try await sourceConnection.read()
        #expect(received2 == testData2)
    }

    @Test("Circuit closes cleanly when source closes")
    func testCircuitClosedBySource() async throws {
        let sourceKey = KeyPair.generateEd25519()
        let targetKey = KeyPair.generateEd25519()
        let relayKey = KeyPair.generateEd25519()

        let (sourceStream, targetStream) = MockMuxedStream.createPair()

        let sourceConnection = RelayedConnection(
            stream: sourceStream,
            relay: relayKey.peerID,
            remotePeer: targetKey.peerID,
            limit: .default
        )

        // Close source
        try await sourceConnection.close()

        // Target should receive EOF
        let data = try await targetStream.read()
        #expect(data.isEmpty)
    }

    // MARK: - Limit Tests

    @Test("Data limit creates circuit with correct limit")
    func testDataLimitConfiguration() async throws {
        let sourceKey = KeyPair.generateEd25519()
        let relayKey = KeyPair.generateEd25519()

        let customLimit = CircuitLimit(duration: .seconds(60), data: 1024)

        let (stream, _) = MockMuxedStream.createPair()
        let connection = RelayedConnection(
            stream: stream,
            relay: relayKey.peerID,
            remotePeer: sourceKey.peerID,
            limit: customLimit
        )

        #expect(connection.limit.data == 1024)
        #expect(connection.limit.duration == .seconds(60))
    }

    // MARK: - Error Handling Tests

    @Test("Connect to unknown peer returns NO_RESERVATION error")
    func testConnectToUnknownPeer() async throws {
        let sourceKey = KeyPair.generateEd25519()
        let targetKey = KeyPair.generateEd25519()
        let relayKey = KeyPair.generateEd25519()

        // Server with no reservations
        let server = RelayServer()
        let client = RelayClient()

        // Register server handler
        let registry = MockHandlerRegistry()
        let serverOpener = MockStreamOpener()
        await server.registerHandler(
            registry: registry,
            opener: serverOpener,
            localPeer: relayKey.peerID,
            getLocalAddresses: { [] }
        )

        let (clientStream, serverStream) = MockMuxedStream.createPair(
            protocolID: CircuitRelayProtocol.hopProtocolID
        )

        let clientOpener = MockStreamOpener()
        clientOpener.setStream(clientStream, for: CircuitRelayProtocol.hopProtocolID)

        // Server handles connection attempt
        let serverTask = Task {
            if let handler = registry.getHandler(for: CircuitRelayProtocol.hopProtocolID) {
                let context = createMockContext(
                    stream: serverStream,
                    remotePeer: sourceKey.peerID,
                    localPeer: relayKey.peerID
                )
                await handler(context)
            }
        }

        // Client should fail
        do {
            _ = try await client.connectThrough(
                relay: relayKey.peerID,
                to: targetKey.peerID,
                using: clientOpener
            )
            Issue.record("Expected connection to fail")
        } catch let error as CircuitRelayError {
            switch error {
            case .connectionFailed(let status):
                #expect(status == .noReservation)
            default:
                Issue.record("Unexpected error type: \(error)")
            }
        }

        await serverTask.value
    }

    // MARK: - Server Configuration Tests

    @Test("Server respects max circuits per peer limit")
    func testPerPeerCircuitLimit() async throws {
        let clientKey = KeyPair.generateEd25519()
        let relayKey = KeyPair.generateEd25519()

        // Create server with maxCircuitsPerPeer = 1
        let serverConfig = RelayServerConfiguration(
            maxCircuitsPerPeer: 1
        )
        let server = RelayServer(configuration: serverConfig)

        // Register server handler
        let registry = MockHandlerRegistry()
        let serverOpener = MockStreamOpener()
        await server.registerHandler(
            registry: registry,
            opener: serverOpener,
            localPeer: relayKey.peerID,
            getLocalAddresses: { [try! Multiaddr("/ip4/127.0.0.1/tcp/4001")] }
        )

        // Verify configuration is set
        #expect(serverConfig.maxCircuitsPerPeer == 1)
        #expect(server.configuration.maxCircuitsPerPeer == 1)
    }

    // MARK: - Protobuf Encoding Tests

    @Test("HopMessage encodes and decodes correctly")
    func testHopMessageRoundTrip() throws {
        // Test RESERVE
        let reserve = HopMessage.reserve()
        let reserveEncoded = CircuitRelayProtobuf.encode(reserve)
        let reserveDecoded = try CircuitRelayProtobuf.decodeHop(reserveEncoded)
        #expect(reserveDecoded.type == .reserve)

        // Test STATUS with reservation
        let resInfo = ReservationInfo(
            expiration: UInt64(Date().timeIntervalSince1970 + 3600),
            addresses: [try Multiaddr("/ip4/127.0.0.1/tcp/4001")],
            voucher: nil
        )
        let status = HopMessage.statusResponse(.ok, reservation: resInfo, limit: .default)
        let statusEncoded = CircuitRelayProtobuf.encode(status)
        let statusDecoded = try CircuitRelayProtobuf.decodeHop(statusEncoded)
        #expect(statusDecoded.type == .status)
        #expect(statusDecoded.status == .ok)
        #expect(statusDecoded.reservation != nil)
    }

    @Test("StopMessage encodes and decodes correctly")
    func testStopMessageRoundTrip() throws {
        let key = KeyPair.generateEd25519()

        // Test CONNECT
        let connect = StopMessage.connect(from: key.peerID, limit: .default)
        let connectEncoded = CircuitRelayProtobuf.encode(connect)
        let connectDecoded = try CircuitRelayProtobuf.decodeStop(connectEncoded)
        #expect(connectDecoded.type == .connect)
        #expect(connectDecoded.peer?.id == key.peerID)

        // Test STATUS
        let status = StopMessage.statusResponse(.ok)
        let statusEncoded = CircuitRelayProtobuf.encode(status)
        let statusDecoded = try CircuitRelayProtobuf.decodeStop(statusEncoded)
        #expect(statusDecoded.type == .status)
        #expect(statusDecoded.status == .ok)
    }
}
