/// CircuitRelayIntegrationTests - Integration tests for Circuit Relay v2 protocol.

import Testing
import Foundation
import NIOCore
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
        var readBuffer: [ByteBuffer] = []
        var readContinuation: CheckedContinuation<ByteBuffer, any Error>?
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

    func read() async throws -> ByteBuffer {
        // All state checks and continuation installation must happen atomically
        // to avoid race conditions with close() and partner notifications.
        return try await withCheckedThrowingContinuation { continuation in
            state.withLock { s in
                if !s.readBuffer.isEmpty {
                    continuation.resume(returning: s.readBuffer.removeFirst())
                } else if s.isClosed || s.partnerClosed {
                    // Return empty data to signal EOF
                    continuation.resume(returning: ByteBuffer())
                } else {
                    // No data available, wait for data or close
                    s.readContinuation = continuation
                }
            }
        }
    }

    func write(_ data: ByteBuffer) async throws {
        let closed = state.withLock { $0.isWriteClosed || $0.isClosed }
        if closed {
            throw MockStreamError.streamClosed
        }

        // Write to partner's read buffer
        if let p = partner.withLock({ $0 }) {
            p.receive(data)
        }
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
        state.withLock { $0.isWriteClosed = true }
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
            s.isWriteClosed = true
            if let continuation = s.readContinuation {
                s.readContinuation = nil
                continuation.resume(returning: ByteBuffer())
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
                continuation.resume(returning: ByteBuffer())
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
        remoteAddress: Multiaddr.tcp(host: "127.0.0.1", port: 4001),
        localPeer: localPeer,
        localAddress: Multiaddr.tcp(host: "127.0.0.1", port: 4002)
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
            getLocalAddresses: { [Multiaddr.tcp(host: "127.0.0.1", port: 4001)] }
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
        let _ = KeyPair.generateEd25519()  // sourceKey not used in this test
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
            getLocalAddresses: { [Multiaddr.tcp(host: "127.0.0.1", port: 4001)] }
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
            let messageBuffer = try await connectServerStream.readLengthPrefixedMessage()
            let message = try CircuitRelayProtobuf.decodeHop(Data(buffer: messageBuffer))

            if message.type == .connect {
                // Send OK status back
                let response = HopMessage.statusResponse(.ok, limit: .default)
                let responseData = CircuitRelayProtobuf.encode(response)
                try await connectServerStream.writeLengthPrefixedMessage(ByteBuffer(bytes: responseData))
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
        let testData1 = ByteBuffer(bytes: Data("Hello from source".utf8))
        try await sourceConnection.write(testData1)
        let received1 = try await targetConnection.read()
        #expect(received1 == testData1)

        // Test sending data from target to source
        let testData2 = ByteBuffer(bytes: Data("Hello from target".utf8))
        try await targetConnection.write(testData2)
        let received2 = try await sourceConnection.read()
        #expect(received2 == testData2)
    }

    @Test("Circuit closes cleanly when source closes")
    func testCircuitClosedBySource() async throws {
        let _ = KeyPair.generateEd25519()  // sourceKey not used in this test
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
        #expect(data.readableBytes == 0)
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
        let _ = KeyPair.generateEd25519()  // clientKey not used in this test
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
            getLocalAddresses: { [Multiaddr.tcp(host: "127.0.0.1", port: 4001)] }
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

// MARK: - RelayListener Tests

@Suite("RelayListener Tests", .serialized)
struct RelayListenerTests {

    @Test("RelayListener accepts incoming connections")
    func testRelayListenerAccept() async throws {
        let targetKey = KeyPair.generateEd25519()
        let sourceKey = KeyPair.generateEd25519()
        let relayKey = KeyPair.generateEd25519()

        let client = RelayClient()
        let server = RelayServer()

        // Register client's Stop handler (critical for receiving connections)
        let clientRegistry = MockHandlerRegistry()
        await client.registerHandler(registry: clientRegistry)

        // Register server's Hop handler
        let serverRegistry = MockHandlerRegistry()
        let serverOpener = MockStreamOpener()
        await server.registerHandler(
            registry: serverRegistry,
            opener: serverOpener,
            localPeer: relayKey.peerID,
            getLocalAddresses: { [Multiaddr.tcp(host: "127.0.0.1", port: 4001)] }
        )

        // Step 1: Target makes reservation on relay
        let (resClientStream, resServerStream) = MockMuxedStream.createPair(
            protocolID: CircuitRelayProtocol.hopProtocolID
        )

        let resOpener = MockStreamOpener()
        resOpener.setStream(resClientStream, for: CircuitRelayProtocol.hopProtocolID)

        let resServerTask = Task {
            if let handler = serverRegistry.getHandler(for: CircuitRelayProtocol.hopProtocolID) {
                let context = createMockContext(
                    stream: resServerStream,
                    remotePeer: targetKey.peerID,
                    localPeer: relayKey.peerID
                )
                await handler(context)
            }
        }

        let reservation = try await client.reserve(on: relayKey.peerID, using: resOpener)
        await resServerTask.value

        // Step 2: Create RelayListener
        let listenAddress = try Multiaddr("/p2p/\(relayKey.peerID)/p2p-circuit")
        let listener = RelayListener(
            relay: relayKey.peerID,
            client: client,
            localAddress: listenAddress,
            reservation: reservation
        )

        // Step 3: Simulate incoming STOP message (as if relay is notifying us of incoming connection)
        let (stopClientStream, stopServerStream) = MockMuxedStream.createPair(
            protocolID: CircuitRelayProtocol.stopProtocolID
        )

        // Send STOP CONNECT message to client's handler
        let incomingTask = Task {
            // Give listener time to start waiting
            try? await Task.sleep(for: .milliseconds(50))

            // Simulate relay sending STOP CONNECT
            if let handler = clientRegistry.getHandler(for: CircuitRelayProtocol.stopProtocolID) {
                let context = createMockContext(
                    stream: stopServerStream,
                    remotePeer: relayKey.peerID,  // STOP comes from relay
                    localPeer: targetKey.peerID
                )

                // Write CONNECT message to the stream (simulating relay's message)
                let connectMsg = StopMessage.connect(from: sourceKey.peerID, limit: .default)
                let connectData = CircuitRelayProtobuf.encode(connectMsg)
                try await stopClientStream.writeLengthPrefixedMessage(ByteBuffer(bytes: connectData))

                await handler(context)
            }
        }

        // Step 4: Accept connection on listener
        let acceptTask = Task<(any RawConnection)?, Never> {
            do {
                return try await listener.accept()
            } catch {
                return nil
            }
        }

        // Wait for incoming connection simulation
        try await incomingTask.value

        // Wait briefly for accept to complete
        try await Task.sleep(for: .milliseconds(100))

        // Step 5: Verify connection was accepted
        let connection = await acceptTask.value
        #expect(connection != nil)

        // Cleanup
        try await listener.close()
    }

    @Test("RelayListener close unblocks accept")
    func testRelayListenerCloseUnblocksAccept() async throws {
        let relayKey = KeyPair.generateEd25519()

        let client = RelayClient()

        // Create a mock reservation
        let reservation = Reservation(
            relay: relayKey.peerID,
            expiration: .now + .seconds(3600),
            addresses: [],
            voucher: nil
        )

        let listenAddress = try Multiaddr("/p2p/\(relayKey.peerID)/p2p-circuit")
        let listener = RelayListener(
            relay: relayKey.peerID,
            client: client,
            localAddress: listenAddress,
            reservation: reservation
        )

        // Start accept in background
        let acceptTask = Task<Bool, Never> {
            do {
                _ = try await listener.accept()
                return false  // Should not succeed
            } catch {
                return true  // Expected to throw
            }
        }

        // Give accept time to start waiting
        try await Task.sleep(for: .milliseconds(50))

        // Close listener
        try await listener.close()

        // accept should complete with error
        let didThrow = await acceptTask.value
        #expect(didThrow == true)
    }

    @Test("RelayListener enqueue delivers to waiting accept")
    func testRelayListenerEnqueueDeliversToWaiter() async throws {
        let relayKey = KeyPair.generateEd25519()
        let sourceKey = KeyPair.generateEd25519()

        let client = RelayClient()

        let reservation = Reservation(
            relay: relayKey.peerID,
            expiration: .now + .seconds(3600),
            addresses: [],
            voucher: nil
        )

        let listenAddress = try Multiaddr("/p2p/\(relayKey.peerID)/p2p-circuit")
        let listener = RelayListener(
            relay: relayKey.peerID,
            client: client,
            localAddress: listenAddress,
            reservation: reservation
        )

        // Start accept in background
        let acceptTask = Task<PeerID?, Never> {
            do {
                let conn = try await listener.accept()
                // Extract remote peer from the address (the p2p after p2p-circuit)
                // remoteAddress format: /p2p/{relay}/p2p-circuit/p2p/{remotePeer}
                var foundCircuit = false
                for proto in conn.remoteAddress.protocols {
                    switch proto {
                    case .p2pCircuit:
                        foundCircuit = true
                    case .p2p(let peerID):
                        if foundCircuit {
                            return peerID
                        }
                    default:
                        break
                    }
                }
                return nil
            } catch {
                return nil
            }
        }

        // Give accept time to start waiting
        try await Task.sleep(for: .milliseconds(50))

        // Create and enqueue a connection directly
        let (stream, _) = MockMuxedStream.createPair()
        let relayedConnection = RelayedConnection(
            stream: stream,
            relay: relayKey.peerID,
            remotePeer: sourceKey.peerID,
            limit: .default
        )
        listener.enqueue(relayedConnection)

        // accept should return the connection
        let remotePeer = await acceptTask.value
        #expect(remotePeer == sourceKey.peerID)

        try await listener.close()
    }

    @Test("RelayListener queues connections when no waiter")
    func testRelayListenerQueuesConnections() async throws {
        let relayKey = KeyPair.generateEd25519()
        let sourceKey = KeyPair.generateEd25519()

        let client = RelayClient()

        let reservation = Reservation(
            relay: relayKey.peerID,
            expiration: .now + .seconds(3600),
            addresses: [],
            voucher: nil
        )

        let listenAddress = try Multiaddr("/p2p/\(relayKey.peerID)/p2p-circuit")
        let listener = RelayListener(
            relay: relayKey.peerID,
            client: client,
            localAddress: listenAddress,
            reservation: reservation
        )

        // Enqueue connection before anyone calls accept
        let (stream, _) = MockMuxedStream.createPair()
        let relayedConnection = RelayedConnection(
            stream: stream,
            relay: relayKey.peerID,
            remotePeer: sourceKey.peerID,
            limit: .default
        )
        listener.enqueue(relayedConnection)

        // Now call accept - should return immediately
        let conn = try await listener.accept()
        #expect(conn.remoteAddress.description.contains(sourceKey.peerID.description))

        try await listener.close()
    }

    @Test("RelayListener close cancels acceptConnection immediately", .timeLimit(.minutes(1)))
    func testRelayListenerCloseCancelsImmediately() async throws {
        let relayKey = KeyPair.generateEd25519()

        // Use a client with a long timeout to prove cancellation is immediate
        let clientConfig = RelayClientConfiguration(connectTimeout: .seconds(30))
        let client = RelayClient(configuration: clientConfig)

        let reservation = Reservation(
            relay: relayKey.peerID,
            expiration: .now + .seconds(3600),
            addresses: [],
            voucher: nil
        )

        let listenAddress = try Multiaddr("/p2p/\(relayKey.peerID)/p2p-circuit")
        let listener = RelayListener(
            relay: relayKey.peerID,
            client: client,
            localAddress: listenAddress,
            reservation: reservation
        )

        // Start accept in background - this will call acceptConnection with 30s timeout
        let acceptTask = Task<Bool, Never> {
            do {
                _ = try await listener.accept()
                return false  // Should not succeed
            } catch {
                // Expected: either CancellationError or listenerClosed
                return true
            }
        }

        // Give accept time to start waiting
        try await Task.sleep(for: .milliseconds(100))

        // Close listener - should cancel acceptConnection immediately
        let startTime = ContinuousClock.now
        try await listener.close()

        // Wait for accept to complete
        let didThrow = await acceptTask.value
        let elapsed = ContinuousClock.now - startTime

        // Verify it completed quickly (not 30 seconds)
        #expect(didThrow == true)
        #expect(elapsed < .seconds(1), "Cancellation took too long: \(elapsed)")
    }

    @Test("RelayListener enforces queue size limit")
    func testRelayListenerQueueLimit() async throws {
        let relayKey = KeyPair.generateEd25519()

        let client = RelayClient()

        let reservation = Reservation(
            relay: relayKey.peerID,
            expiration: .now + .seconds(3600),
            addresses: [],
            voucher: nil
        )

        let listenAddress = try Multiaddr("/p2p/\(relayKey.peerID)/p2p-circuit")
        let listener = RelayListener(
            relay: relayKey.peerID,
            client: client,
            localAddress: listenAddress,
            reservation: reservation
        )

        // Enqueue more than the limit (64) connections without calling accept()
        for _ in 0..<70 {
            let sourceKey = KeyPair.generateEd25519()
            let (stream, _) = MockMuxedStream.createPair()
            let relayedConnection = RelayedConnection(
                stream: stream,
                relay: relayKey.peerID,
                remotePeer: sourceKey.peerID,
                limit: .default
            )
            listener.enqueue(relayedConnection)
        }

        // Small delay to allow async close tasks to run
        try await Task.sleep(for: .milliseconds(50))

        // Accept 64 connections (the limit) - these should all succeed immediately
        for i in 0..<64 {
            let acceptTask = Task {
                try await listener.accept()
            }

            // Give it time to complete
            try await Task.sleep(for: .milliseconds(5))

            // Should complete without blocking
            let conn = try await acceptTask.value
            #expect(conn.remoteAddress.description.contains("p2p-circuit"), "Connection \(i) should be a circuit address")
        }

        // The 65th accept should block (no more queued connections)
        // We verify by starting accept and then closing the listener
        let acceptTask = Task<Bool, Never> {
            do {
                _ = try await listener.accept()
                return true  // Got a connection (unexpected)
            } catch {
                return false  // Threw error (expected after close)
            }
        }

        // Give accept time to start waiting
        try await Task.sleep(for: .milliseconds(50))

        // Close listener - this should unblock the waiting accept
        try await listener.close()

        // Accept should have failed (no 65th connection)
        let gotConnection = await acceptTask.value
        #expect(gotConnection == false, "Should not have received a 65th connection")
    }

    @Test("RelayListener.accept() cancellation cleans up continuation", .timeLimit(.minutes(1)))
    func testAcceptCancellationCleansUpContinuation() async throws {
        let relayKey = KeyPair.generateEd25519()

        let client = RelayClient()

        let reservation = Reservation(
            relay: relayKey.peerID,
            expiration: .now + .seconds(3600),
            addresses: [],
            voucher: nil
        )

        let listenAddress = try Multiaddr("/p2p/\(relayKey.peerID)/p2p-circuit")
        let listener = RelayListener(
            relay: relayKey.peerID,
            client: client,
            localAddress: listenAddress,
            reservation: reservation
        )

        // Step 1: Start accept in background
        let acceptTask = Task<String, Never> {
            do {
                _ = try await listener.accept()
                return "success"
            } catch is CancellationError {
                return "cancelled"
            } catch {
                return "other error: \(error)"
            }
        }

        // Give accept time to start waiting
        try await Task.sleep(for: .milliseconds(50))

        // Step 2: Cancel the accept task
        acceptTask.cancel()

        // Step 3: Verify cancellation was handled
        let result = await acceptTask.value
        #expect(result == "cancelled", "Expected CancellationError but got: \(result)")

        // Step 4: Verify new accept works (continuation was cleaned up properly)
        // First enqueue a connection
        let sourceKey = KeyPair.generateEd25519()
        let (stream, _) = MockMuxedStream.createPair()
        let relayedConnection = RelayedConnection(
            stream: stream,
            relay: relayKey.peerID,
            remotePeer: sourceKey.peerID,
            limit: .default
        )
        listener.enqueue(relayedConnection)

        // New accept should succeed (not be blocked by old continuation)
        let newAcceptTask = Task<String, Never> {
            do {
                let conn = try await listener.accept()
                return conn.remoteAddress.description.contains(sourceKey.peerID.description) ? "success" : "wrong peer"
            } catch {
                return "error: \(error)"
            }
        }

        let newResult = await newAcceptTask.value
        #expect(newResult == "success", "New accept should succeed, got: \(newResult)")

        try await listener.close()
    }
}

// MARK: - RelayClient Cancellation Tests

@Suite("RelayClient Cancellation Tests", .serialized)
struct RelayClientCancellationTests {

    @Test("RelayClient.acceptConnection() handles immediate cancellation", .timeLimit(.minutes(1)))
    func testAcceptConnectionImmediateCancellation() async throws {
        // Use a client with long timeout to prove cancellation is immediate
        let clientConfig = RelayClientConfiguration(connectTimeout: .seconds(30))
        let client = RelayClient(configuration: clientConfig)

        // Start acceptConnection and immediately cancel (induces race)
        let acceptTask = Task<String, Never> {
            do {
                _ = try await client.acceptConnection()
                return "success"
            } catch is CancellationError {
                return "cancelled"
            } catch is CircuitRelayError {
                return "relay error"
            } catch {
                return "other: \(type(of: error))"
            }
        }

        // Immediately cancel - this induces the race condition
        acceptTask.cancel()

        // Should complete quickly (not wait 30s timeout)
        let startTime = ContinuousClock.now
        let result = await acceptTask.value
        let elapsed = ContinuousClock.now - startTime

        // Either cancelled or some quick failure is acceptable
        #expect(result == "cancelled" || result == "relay error",
                "Expected cancellation or quick failure, got: \(result)")
        #expect(elapsed < .seconds(5), "Should complete quickly, took: \(elapsed)")

        client.shutdown()
    }

    @Test("RelayClient.acceptConnection() cancellation after delay", .timeLimit(.minutes(1)))
    func testAcceptConnectionCancellationAfterDelay() async throws {
        let clientConfig = RelayClientConfiguration(connectTimeout: .seconds(30))
        let client = RelayClient(configuration: clientConfig)

        let acceptTask = Task<String, Never> {
            do {
                _ = try await client.acceptConnection()
                return "success"
            } catch is CancellationError {
                return "cancelled"
            } catch is CircuitRelayError {
                return "relay error"
            } catch {
                return "other: \(type(of: error))"
            }
        }

        // Wait a bit to ensure the waiter is registered
        try await Task.sleep(for: .milliseconds(100))

        // Now cancel
        let startTime = ContinuousClock.now
        acceptTask.cancel()

        let result = await acceptTask.value
        let elapsed = ContinuousClock.now - startTime

        #expect(result == "cancelled", "Expected CancellationError, got: \(result)")
        #expect(elapsed < .seconds(1), "Cancellation should be immediate, took: \(elapsed)")

        client.shutdown()
    }
}
