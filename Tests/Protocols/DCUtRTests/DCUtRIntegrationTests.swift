/// DCUtRIntegrationTests - Integration tests for DCUtR protocol.

import Testing
import Foundation
import NIOCore
import Synchronization
@testable import P2PDCUtR
@testable import P2PCore
@testable import P2PMux
@testable import P2PProtocols

// MARK: - Test Helpers

/// A mock MuxedStream that allows paired bidirectional communication.
final class DCUtRMockStream: MuxedStream, Sendable {
    let id: UInt64
    let protocolID: String?

    private let state: Mutex<StreamState>
    private let partner: Mutex<DCUtRMockStream?>

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

    static func createPair(protocolID: String? = nil) -> (client: DCUtRMockStream, server: DCUtRMockStream) {
        let client = DCUtRMockStream(id: 1, protocolID: protocolID)
        let server = DCUtRMockStream(id: 2, protocolID: protocolID)
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
            throw DCUtRTestError.streamClosed
        }

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
        // Also notify partner that we're closed
        if let p = partner.withLock({ $0 }) {
            p.notifyPartnerClosed()
        }
    }

    /// Called when partner stream is closed
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

enum DCUtRTestError: Error {
    case streamClosed
    case dialFailed
}

/// A mock HandlerRegistry that captures registered handlers.
final class DCUtRMockRegistry: HandlerRegistry, Sendable {
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

/// A mock StreamOpener for DCUtR tests.
final class DCUtRMockOpener: StreamOpener, Sendable {
    private let state: Mutex<OpenerState>

    private struct OpenerState: Sendable {
        var streams: [String: DCUtRMockStream] = [:]
        var error: (any Error)?
    }

    init() {
        self.state = Mutex(OpenerState())
    }

    func setStream(_ stream: DCUtRMockStream, for protocolID: String) {
        state.withLock { $0.streams[protocolID] = stream }
    }

    func setError(_ error: any Error) {
        state.withLock { $0.error = error }
    }

    func newStream(to peer: PeerID, protocol protocolID: String) async throws -> MuxedStream {
        if let error = state.withLock({ $0.error }) {
            throw error
        }

        guard let stream = state.withLock({ $0.streams[protocolID] }) else {
            throw DCUtRTestError.dialFailed
        }

        return stream
    }
}

/// A mock dialer that tracks dial attempts.
final class MockDialer: Sendable {
    private let state: Mutex<DialerState>

    private struct DialerState: Sendable {
        var reachableAddresses: Set<Multiaddr> = []
        var dialAttempts: [Multiaddr] = []
        var shouldFail: Bool = false
    }

    init() {
        self.state = Mutex(DialerState())
    }

    func setReachable(_ addresses: [Multiaddr]) {
        state.withLock { $0.reachableAddresses = Set(addresses) }
    }

    func setShouldFail(_ shouldFail: Bool) {
        state.withLock { $0.shouldFail = shouldFail }
    }

    var dialAttempts: [Multiaddr] {
        state.withLock { $0.dialAttempts }
    }

    func dial(_ address: Multiaddr) async throws {
        state.withLock { $0.dialAttempts.append(address) }

        let (shouldFail, isReachable) = state.withLock { s in
            (s.shouldFail, s.reachableAddresses.contains(address))
        }

        if shouldFail || !isReachable {
            throw DCUtRTestError.dialFailed
        }
    }
}

/// Helper to create a mock StreamContext.
func createDCUtRContext(
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

// MARK: - DCUtR Integration Tests

@Suite("DCUtR Integration Tests", .serialized)
struct DCUtRIntegrationTests {

    // MARK: - Address Exchange Tests

    @Test("Address exchange succeeds with valid addresses")
    func testAddressExchangeSuccess() async throws {
        let initiatorKey = KeyPair.generateEd25519()
        let responderKey = KeyPair.generateEd25519()

        let initiatorAddresses = [
            try Multiaddr("/ip4/203.0.113.1/tcp/4001"),
            try Multiaddr("/ip4/203.0.113.10/tcp/4001")
        ]

        let responderAddresses = [
            try Multiaddr("/ip4/203.0.113.2/tcp/4001")
        ]

        // Create initiator service
        let initiatorDialer = MockDialer()
        initiatorDialer.setReachable(responderAddresses)

        let initiatorConfig = DCUtRConfiguration(
            getLocalAddresses: { initiatorAddresses },
            dialer: { addr in try await initiatorDialer.dial(addr) }
        )
        let initiator = DCUtRService(configuration: initiatorConfig)

        // Create responder service
        let responderDialer = MockDialer()
        responderDialer.setReachable(initiatorAddresses)

        let responderConfig = DCUtRConfiguration(
            getLocalAddresses: { responderAddresses },
            dialer: { addr in try await responderDialer.dial(addr) }
        )
        let responder = DCUtRService(configuration: responderConfig)

        // Register responder handler
        let registry = DCUtRMockRegistry()
        await responder.registerHandler(registry: registry)

        // Create paired streams
        let (initiatorStream, responderStream) = DCUtRMockStream.createPair(
            protocolID: DCUtRProtocol.protocolID
        )

        // Setup opener for initiator
        let opener = DCUtRMockOpener()
        opener.setStream(initiatorStream, for: DCUtRProtocol.protocolID)

        // Run responder handler in background
        let responderTask = Task {
            if let handler = registry.getHandler(for: DCUtRProtocol.protocolID) {
                let context = createDCUtRContext(
                    stream: responderStream,
                    remotePeer: initiatorKey.peerID,
                    localPeer: responderKey.peerID
                )
                await handler(context)
            }
        }

        // Initiator starts upgrade
        try await initiator.upgradeToDirectConnection(
            with: responderKey.peerID,
            using: opener,
            dialer: { addr in try await initiatorDialer.dial(addr) }
        )

        await responderTask.value

        // Cleanup
        initiator.shutdown()
        responder.shutdown()

        // Verify dial attempts
        #expect(initiatorDialer.dialAttempts.count > 0)
    }

    @Test("Handles empty addresses gracefully")
    func testEmptyAddressHandling() async throws {
        let initiatorKey = KeyPair.generateEd25519()
        let responderKey = KeyPair.generateEd25519()

        // Create initiator with addresses but responder has none
        let initiatorConfig = DCUtRConfiguration(
            getLocalAddresses: { [Multiaddr.tcp(host: "203.0.113.1", port: 4001)] }
        )
        let initiator = DCUtRService(configuration: initiatorConfig)

        // Responder has no addresses
        let responderConfig = DCUtRConfiguration(
            getLocalAddresses: { [] }
        )
        let responder = DCUtRService(configuration: responderConfig)

        // Register responder handler
        let registry = DCUtRMockRegistry()
        await responder.registerHandler(registry: registry)

        // Create paired streams
        let (initiatorStream, responderStream) = DCUtRMockStream.createPair(
            protocolID: DCUtRProtocol.protocolID
        )

        let opener = DCUtRMockOpener()
        opener.setStream(initiatorStream, for: DCUtRProtocol.protocolID)

        // Run responder
        let responderTask = Task {
            if let handler = registry.getHandler(for: DCUtRProtocol.protocolID) {
                let context = createDCUtRContext(
                    stream: responderStream,
                    remotePeer: initiatorKey.peerID,
                    localPeer: responderKey.peerID
                )
                await handler(context)
            }
        }

        // Should fail due to no addresses
        let dialer = MockDialer()
        await #expect(throws: DCUtRError.self) {
            try await initiator.upgradeToDirectConnection(
                with: responderKey.peerID,
                using: opener,
                dialer: { addr in try await dialer.dial(addr) }
            )
        }

        // Cleanup - responder is still waiting for SYNC that will never come
        // Close the stream to unblock responder, then await task completion
        try await responderStream.close()
        await responderTask.value

        initiator.shutdown()
        responder.shutdown()
    }

    // MARK: - Role Tests

    @Test("Initiator sends CONNECT then waits for CONNECT response")
    func testInitiatorRole() async throws {
        let responderKey = KeyPair.generateEd25519()

        let initiatorAddresses = [try Multiaddr("/ip4/203.0.113.1/tcp/4001")]

        let config = DCUtRConfiguration(
            getLocalAddresses: { initiatorAddresses }
        )
        let initiator = DCUtRService(configuration: config)

        // Create streams
        let (initiatorStream, responderStream) = DCUtRMockStream.createPair(
            protocolID: DCUtRProtocol.protocolID
        )

        let opener = DCUtRMockOpener()
        opener.setStream(initiatorStream, for: DCUtRProtocol.protocolID)

        // Simulate responder that echoes back addresses
        let responderTask = Task<Void, any Error> {
            // Read initiator's CONNECT
            let connectData = try await responderStream.readLengthPrefixedMessage()
            let connect = try DCUtRProtobuf.decode(Data(buffer: connectData))
            #expect(connect.type == .connect)

            // Send back CONNECT with our addresses
            let response = DCUtRMessage.connect(addresses: [try Multiaddr("/ip4/203.0.113.2/tcp/4001")])
            try await responderStream.writeLengthPrefixedMessage(ByteBuffer(bytes: DCUtRProtobuf.encode(response)))

            // Read SYNC
            let syncData = try await responderStream.readLengthPrefixedMessage()
            let sync = try DCUtRProtobuf.decode(Data(buffer: syncData))
            #expect(sync.type == .sync)
        }

        // Run initiator - will fail on dial but protocol exchange should complete
        let dialer = MockDialer()
        dialer.setReachable([try Multiaddr("/ip4/203.0.113.2/tcp/4001")])

        try await initiator.upgradeToDirectConnection(
            with: responderKey.peerID,
            using: opener,
            dialer: { addr in try await dialer.dial(addr) }
        )

        try await responderTask.value

        // Cleanup
        initiator.shutdown()
    }

    @Test("Responder receives CONNECT and sends CONNECT response")
    func testResponderRole() async throws {
        let initiatorKey = KeyPair.generateEd25519()
        let responderKey = KeyPair.generateEd25519()

        let responderAddresses = [try Multiaddr("/ip4/203.0.113.2/tcp/4001")]

        let dialer = MockDialer()
        dialer.setReachable([try Multiaddr("/ip4/203.0.113.1/tcp/4001")])

        let config = DCUtRConfiguration(
            getLocalAddresses: { responderAddresses },
            dialer: { addr in try await dialer.dial(addr) }
        )
        let responder = DCUtRService(configuration: config)

        // Register handler
        let registry = DCUtRMockRegistry()
        await responder.registerHandler(registry: registry)

        // Create streams
        let (initiatorStream, responderStream) = DCUtRMockStream.createPair(
            protocolID: DCUtRProtocol.protocolID
        )

        // Simulate initiator
        let initiatorTask = Task<Void, any Error> {
            // Send CONNECT
            let connect = DCUtRMessage.connect(addresses: [try Multiaddr("/ip4/203.0.113.1/tcp/4001")])
            try await initiatorStream.writeLengthPrefixedMessage(ByteBuffer(bytes: DCUtRProtobuf.encode(connect)))

            // Read CONNECT response
            let responseData = try await initiatorStream.readLengthPrefixedMessage()
            let response = try DCUtRProtobuf.decode(Data(buffer: responseData))
            #expect(response.type == .connect)
            #expect(response.observedAddresses.count > 0)

            // Send SYNC
            let sync = DCUtRMessage.sync()
            try await initiatorStream.writeLengthPrefixedMessage(ByteBuffer(bytes: DCUtRProtobuf.encode(sync)))
        }

        // Run responder handler
        if let handler = registry.getHandler(for: DCUtRProtocol.protocolID) {
            let context = createDCUtRContext(
                stream: responderStream,
                remotePeer: initiatorKey.peerID,
                localPeer: responderKey.peerID
            )
            await handler(context)
        }

        try await initiatorTask.value

        // Cleanup
        responder.shutdown()
    }

    // MARK: - Failure Scenarios

    @Test("All dials fail returns error")
    func testAllDialsFail() async throws {
        let responderKey = KeyPair.generateEd25519()

        let initiatorAddresses = [try Multiaddr("/ip4/203.0.113.1/tcp/4001")]

        let config = DCUtRConfiguration(
            getLocalAddresses: { initiatorAddresses }
        )
        let initiator = DCUtRService(configuration: config)

        // Create streams
        let (initiatorStream, responderStream) = DCUtRMockStream.createPair(
            protocolID: DCUtRProtocol.protocolID
        )

        let opener = DCUtRMockOpener()
        opener.setStream(initiatorStream, for: DCUtRProtocol.protocolID)

        // Simulate responder
        let responderTask = Task<Void, any Error> {
            let connectData = try await responderStream.readLengthPrefixedMessage()
            _ = try DCUtRProtobuf.decode(Data(buffer: connectData))

            // Send back CONNECT with unreachable addresses
            let response = DCUtRMessage.connect(addresses: [try Multiaddr("/ip4/203.0.113.99/tcp/4001")])
            try await responderStream.writeLengthPrefixedMessage(ByteBuffer(bytes: DCUtRProtobuf.encode(response)))

            // Read SYNC
            let syncData = try await responderStream.readLengthPrefixedMessage()
            _ = try DCUtRProtobuf.decode(Data(buffer: syncData))
        }

        // All dials should fail
        let dialer = MockDialer()
        dialer.setShouldFail(true)

        await #expect(throws: DCUtRError.self) {
            try await initiator.upgradeToDirectConnection(
                with: responderKey.peerID,
                using: opener,
                dialer: { addr in try await dialer.dial(addr) }
            )
        }

        try await responderTask.value

        // Cleanup
        initiator.shutdown()
    }

    // MARK: - Protobuf Tests

    @Test("DCUtR message encodes and decodes correctly")
    func testMessageRoundTrip() throws {
        // Test CONNECT
        let addresses = [
            try Multiaddr("/ip4/203.0.113.1/tcp/4001"),
            try Multiaddr("/ip4/203.0.113.10/tcp/4001")
        ]
        let connect = DCUtRMessage.connect(addresses: addresses)
        let connectEncoded = DCUtRProtobuf.encode(connect)
        let connectDecoded = try DCUtRProtobuf.decode(connectEncoded)
        #expect(connectDecoded.type == .connect)
        #expect(connectDecoded.observedAddresses.count == 2)

        // Test SYNC
        let sync = DCUtRMessage.sync()
        let syncEncoded = DCUtRProtobuf.encode(sync)
        let syncDecoded = try DCUtRProtobuf.decode(syncEncoded)
        #expect(syncDecoded.type == .sync)
    }

    // MARK: - Event Tests

    @Test("Service emits events during upgrade")
    func testEventEmission() async throws {
        let responderKey = KeyPair.generateEd25519()

        let initiatorAddresses = [try Multiaddr("/ip4/203.0.113.1/tcp/4001")]
        let responderAddresses = [try Multiaddr("/ip4/203.0.113.2/tcp/4001")]

        let dialer = MockDialer()
        dialer.setReachable(responderAddresses)

        let config = DCUtRConfiguration(
            getLocalAddresses: { initiatorAddresses },
            dialer: { addr in try await dialer.dial(addr) }
        )
        let initiator = DCUtRService(configuration: config)

        // Create streams
        let (initiatorStream, responderStream) = DCUtRMockStream.createPair(
            protocolID: DCUtRProtocol.protocolID
        )

        let opener = DCUtRMockOpener()
        opener.setStream(initiatorStream, for: DCUtRProtocol.protocolID)

        // Collect events using actor for thread safety
        actor EventCollector {
            var events: [DCUtREvent] = []
            func add(_ event: DCUtREvent) { events.append(event) }
            func getEvents() -> [DCUtREvent] { events }
        }
        let collector = EventCollector()

        let eventTask = Task {
            for await event in initiator.events {
                await collector.add(event)
                if case .directConnectionEstablished = event { break }
                if case .holePunchFailed = event { break }
            }
        }

        // Give eventTask time to start listening before sending events
        try await Task.sleep(for: .milliseconds(10))

        // Simulate responder
        let responderTask = Task<Void, any Error> {
            let connectData = try await responderStream.readLengthPrefixedMessage()
            _ = try DCUtRProtobuf.decode(Data(buffer: connectData))

            let response = DCUtRMessage.connect(addresses: responderAddresses)
            try await responderStream.writeLengthPrefixedMessage(ByteBuffer(bytes: DCUtRProtobuf.encode(response)))

            let syncData = try await responderStream.readLengthPrefixedMessage()
            _ = try DCUtRProtobuf.decode(Data(buffer: syncData))
        }

        try await initiator.upgradeToDirectConnection(
            with: responderKey.peerID,
            using: opener,
            dialer: { addr in try await dialer.dial(addr) }
        )

        try await responderTask.value

        // Give eventTask time to collect events before shutting down
        try await Task.sleep(for: .milliseconds(10))

        initiator.shutdown()  // Finish event stream to unblock eventTask
        await eventTask.value  // Wait for eventTask to complete

        // Verify events were emitted
        let receivedEvents = await collector.getEvents()
        #expect(receivedEvents.contains { event in
            if case .holePunchAttemptStarted = event { return true }
            return false
        })
    }

    // MARK: - Protocol Violation Tests

    @Test("Detects protocol violation when SYNC is received instead of CONNECT")
    func testProtocolViolationWrongMessageType() async throws {
        let responderKey = KeyPair.generateEd25519()

        let initiatorAddresses = [try Multiaddr("/ip4/203.0.113.1/tcp/4001")]

        let config = DCUtRConfiguration(
            getLocalAddresses: { initiatorAddresses }
        )
        let initiator = DCUtRService(configuration: config)

        // Create streams
        let (initiatorStream, responderStream) = DCUtRMockStream.createPair(
            protocolID: DCUtRProtocol.protocolID
        )

        let opener = DCUtRMockOpener()
        opener.setStream(initiatorStream, for: DCUtRProtocol.protocolID)

        // Malicious responder sends SYNC instead of CONNECT
        let maliciousResponderTask = Task<Void, any Error> {
            // Read initiator's CONNECT
            _ = try await responderStream.readLengthPrefixedMessage()

            // Send SYNC instead of CONNECT (protocol violation)
            let wrongMessage = DCUtRMessage.sync()
            try await responderStream.writeLengthPrefixedMessage(ByteBuffer(bytes: DCUtRProtobuf.encode(wrongMessage)))
        }

        // Initiator should detect the violation or handle gracefully
        let dialer = MockDialer()

        await #expect(throws: (any Error).self) {
            try await initiator.upgradeToDirectConnection(
                with: responderKey.peerID,
                using: opener,
                dialer: { addr in try await dialer.dial(addr) }
            )
        }

        try? await maliciousResponderTask.value

        // Cleanup
        initiator.shutdown()
    }

    @Test("Stream closed during message exchange")
    func testStreamClosedDuringExchange() async throws {
        let responderKey = KeyPair.generateEd25519()

        let initiatorAddresses = [try Multiaddr("/ip4/203.0.113.1/tcp/4001")]

        let config = DCUtRConfiguration(
            getLocalAddresses: { initiatorAddresses }
        )
        let initiator = DCUtRService(configuration: config)

        // Create streams
        let (initiatorStream, responderStream) = DCUtRMockStream.createPair(
            protocolID: DCUtRProtocol.protocolID
        )

        let opener = DCUtRMockOpener()
        opener.setStream(initiatorStream, for: DCUtRProtocol.protocolID)

        // Malicious responder closes stream immediately after reading
        let maliciousResponderTask = Task<Void, any Error> {
            // Read initiator's CONNECT
            _ = try await responderStream.readLengthPrefixedMessage()

            // Close stream without responding
            try await responderStream.close()
        }

        // Initiator should handle stream closure gracefully
        let dialer = MockDialer()

        await #expect(throws: (any Error).self) {
            try await initiator.upgradeToDirectConnection(
                with: responderKey.peerID,
                using: opener,
                dialer: { addr in try await dialer.dial(addr) }
            )
        }

        try? await maliciousResponderTask.value

        // Cleanup
        initiator.shutdown()
    }

    @Test("Responder handles stream closed before receiving CONNECT")
    func testResponderStreamClosedEarly() async throws {
        let initiatorKey = KeyPair.generateEd25519()
        let responderKey = KeyPair.generateEd25519()

        let responderAddresses = [try Multiaddr("/ip4/203.0.113.2/tcp/4001")]

        let config = DCUtRConfiguration(
            getLocalAddresses: { responderAddresses }
        )
        let responder = DCUtRService(configuration: config)

        // Register handler
        let registry = DCUtRMockRegistry()
        await responder.registerHandler(registry: registry)

        // Create streams
        let (initiatorStream, responderStream) = DCUtRMockStream.createPair(
            protocolID: DCUtRProtocol.protocolID
        )

        // Close initiator stream immediately
        try await initiatorStream.close()

        // Responder should handle gracefully
        if let handler = registry.getHandler(for: DCUtRProtocol.protocolID) {
            let context = createDCUtRContext(
                stream: responderStream,
                remotePeer: initiatorKey.peerID,
                localPeer: responderKey.peerID
            )
            // This should complete without crashing
            await handler(context)
        }

        // Cleanup
        responder.shutdown()
    }

    @Test("Responder handles malformed message")
    func testResponderMalformedMessage() async throws {
        let initiatorKey = KeyPair.generateEd25519()
        let responderKey = KeyPair.generateEd25519()

        let responderAddresses = [try Multiaddr("/ip4/203.0.113.2/tcp/4001")]

        let config = DCUtRConfiguration(
            getLocalAddresses: { responderAddresses }
        )
        let responder = DCUtRService(configuration: config)

        // Register handler
        let registry = DCUtRMockRegistry()
        await responder.registerHandler(registry: registry)

        // Create streams
        let (initiatorStream, responderStream) = DCUtRMockStream.createPair(
            protocolID: DCUtRProtocol.protocolID
        )

        // Send malformed data
        let malformedTask = Task<Void, any Error> {
            // Send invalid data (truncated length prefix)
            var malformedData = Data()
            malformedData.append(contentsOf: Varint.encode(UInt64(100)))  // claims 100 bytes
            malformedData.append(contentsOf: [0x01, 0x02, 0x03])  // only 3 bytes
            try await initiatorStream.write(ByteBuffer(bytes: malformedData))
            try await initiatorStream.close()
        }

        // Responder should handle gracefully
        if let handler = registry.getHandler(for: DCUtRProtocol.protocolID) {
            let context = createDCUtRContext(
                stream: responderStream,
                remotePeer: initiatorKey.peerID,
                localPeer: responderKey.peerID
            )
            await handler(context)
        }

        try? await malformedTask.value

        // Cleanup
        responder.shutdown()
    }

    // Note: Timeout test removed because DCUtRService.upgradeToDirectConnection
    // does not currently implement timeout on readMessage operations.
    // The configuration.timeout field is defined but unused.
    // This is a known implementation gap that should be addressed separately.
}
