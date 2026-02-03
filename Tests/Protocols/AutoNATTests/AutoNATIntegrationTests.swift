/// AutoNATIntegrationTests - Integration tests for AutoNAT protocol.

import Testing
import Foundation
import NIOCore
import Synchronization
@testable import P2PAutoNAT
@testable import P2PCore
@testable import P2PMux
@testable import P2PProtocols

// MARK: - Test Helpers

/// A mock MuxedStream that allows paired bidirectional communication.
final class AutoNATMockStream: MuxedStream, Sendable {
    let id: UInt64
    let protocolID: String?

    private let state: Mutex<StreamState>
    private let partner: Mutex<AutoNATMockStream?>

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

    static func createPair(protocolID: String? = nil) -> (client: AutoNATMockStream, server: AutoNATMockStream) {
        let client = AutoNATMockStream(id: 1, protocolID: protocolID)
        let server = AutoNATMockStream(id: 2, protocolID: protocolID)
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
            throw AutoNATTestError.streamClosed
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

enum AutoNATTestError: Error {
    case streamClosed
    case dialFailed
}

/// A mock HandlerRegistry for AutoNAT tests.
final class AutoNATMockRegistry: HandlerRegistry, Sendable {
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

/// A mock StreamOpener for AutoNAT tests.
final class AutoNATMockOpener: StreamOpener, Sendable {
    private let state: Mutex<OpenerState>

    private struct OpenerState: Sendable {
        var streams: [PeerID: AutoNATMockStream] = [:]
        var error: (any Error)?
    }

    init() {
        self.state = Mutex(OpenerState())
    }

    func setStream(_ stream: AutoNATMockStream, for peer: PeerID) {
        state.withLock { $0.streams[peer] = stream }
    }

    func setError(_ error: any Error) {
        state.withLock { $0.error = error }
    }

    func newStream(to peer: PeerID, protocol protocolID: String) async throws -> MuxedStream {
        if let error = state.withLock({ $0.error }) {
            throw error
        }

        guard let stream = state.withLock({ $0.streams[peer] }) else {
            throw AutoNATTestError.dialFailed
        }

        return stream
    }
}

/// A mock dialer that tracks dial-back attempts.
final class AutoNATMockDialer: Sendable {
    private let state: Mutex<DialerState>

    private struct DialerState: Sendable {
        var reachableAddresses: Set<Multiaddr> = []
        var dialAttempts: [Multiaddr] = []
    }

    init() {
        self.state = Mutex(DialerState())
    }

    func setReachable(_ addresses: [Multiaddr]) {
        state.withLock { $0.reachableAddresses = Set(addresses) }
    }

    var dialAttempts: [Multiaddr] {
        state.withLock { $0.dialAttempts }
    }

    func dial(_ address: Multiaddr) async throws {
        state.withLock { $0.dialAttempts.append(address) }

        let isReachable = state.withLock { $0.reachableAddresses.contains(address) }
        if !isReachable {
            throw AutoNATTestError.dialFailed
        }
    }
}

/// Helper to create a mock StreamContext.
func createAutoNATContext(
    stream: MuxedStream,
    remotePeer: PeerID,
    localPeer: PeerID,
    remoteAddress: Multiaddr = Multiaddr.tcp(host: "192.168.1.1", port: 4001)
) -> StreamContext {
    StreamContext(
        stream: stream,
        remotePeer: remotePeer,
        remoteAddress: remoteAddress,
        localPeer: localPeer,
        localAddress: Multiaddr.tcp(host: "127.0.0.1", port: 4002)
    )
}

// MARK: - AutoNAT Integration Tests

@Suite("AutoNAT Integration Tests", .serialized)
struct AutoNATIntegrationTests {

    // MARK: - Status Tests

    @Test("Initial status is Unknown")
    func testInitialStatusUnknown() async throws {
        let config = AutoNATConfiguration()
        let service = AutoNATService(configuration: config)

        #expect(service.status == .unknown)
        #expect(service.confidence == 0)
    }

    @Test("Status becomes Public when probes succeed")
    func testStatusPublicWhenReachable() async throws {
        let clientKey = KeyPair.generateEd25519()
        let serverKey = KeyPair.generateEd25519()

        let clientAddresses = [try Multiaddr("/ip4/192.168.1.1/tcp/4001")]

        // Create server that reports OK
        let serverDialer = AutoNATMockDialer()
        serverDialer.setReachable(clientAddresses)

        let serverConfig = AutoNATConfiguration(
            dialer: { addr in try await serverDialer.dial(addr) }
        )
        let server = AutoNATService(configuration: serverConfig)

        // Register server handler
        let registry = AutoNATMockRegistry()
        await server.registerHandler(registry: registry)

        // Create client
        let clientConfig = AutoNATConfiguration(
            minProbes: 1,
            getLocalAddresses: { clientAddresses }
        )
        let client = AutoNATService(configuration: clientConfig)

        // Create paired streams
        let (clientStream, serverStream) = AutoNATMockStream.createPair(
            protocolID: AutoNATProtocol.protocolID
        )

        // Setup opener
        let opener = AutoNATMockOpener()
        opener.setStream(clientStream, for: serverKey.peerID)

        // Run server handler
        let serverTask = Task {
            if let handler = registry.getHandler(for: AutoNATProtocol.protocolID) {
                let context = createAutoNATContext(
                    stream: serverStream,
                    remotePeer: clientKey.peerID,
                    localPeer: serverKey.peerID,
                    remoteAddress: clientAddresses[0]  // Match client IP
                )
                await handler(context)
            }
        }

        // Client probes server
        let status = try await client.probe(using: opener, servers: [serverKey.peerID])

        await serverTask.value

        #expect(status.isPublic)
    }

    @Test("Status becomes Private when probes fail")
    func testStatusPrivateWhenUnreachable() async throws {
        let clientKey = KeyPair.generateEd25519()
        let serverKey = KeyPair.generateEd25519()

        let clientAddresses = [try Multiaddr("/ip4/192.168.1.1/tcp/4001")]

        // Create server that reports dial error (unreachable)
        let serverDialer = AutoNATMockDialer()
        // Don't set any reachable addresses - all dials will fail

        let serverConfig = AutoNATConfiguration(
            dialer: { addr in try await serverDialer.dial(addr) }
        )
        let server = AutoNATService(configuration: serverConfig)

        // Register server handler
        let registry = AutoNATMockRegistry()
        await server.registerHandler(registry: registry)

        // Create client
        let clientConfig = AutoNATConfiguration(
            minProbes: 1,
            getLocalAddresses: { clientAddresses }
        )
        let client = AutoNATService(configuration: clientConfig)

        // Create paired streams
        let (clientStream, serverStream) = AutoNATMockStream.createPair(
            protocolID: AutoNATProtocol.protocolID
        )

        // Setup opener
        let opener = AutoNATMockOpener()
        opener.setStream(clientStream, for: serverKey.peerID)

        // Run server handler
        let serverTask = Task {
            if let handler = registry.getHandler(for: AutoNATProtocol.protocolID) {
                let context = createAutoNATContext(
                    stream: serverStream,
                    remotePeer: clientKey.peerID,
                    localPeer: serverKey.peerID,
                    remoteAddress: clientAddresses[0]
                )
                await handler(context)
            }
        }

        // Client probes server
        let status = try await client.probe(using: opener, servers: [serverKey.peerID])

        await serverTask.value

        #expect(status == .privateBehindNAT)
    }

    // MARK: - Server Tests

    @Test("Server dials back to client addresses")
    func testServerDialsBack() async throws {
        let clientKey = KeyPair.generateEd25519()
        let serverKey = KeyPair.generateEd25519()

        let clientAddress = try Multiaddr("/ip4/192.168.1.100/tcp/4001")

        let dialer = AutoNATMockDialer()
        dialer.setReachable([clientAddress])

        let serverConfig = AutoNATConfiguration(
            dialer: { addr in try await dialer.dial(addr) }
        )
        let server = AutoNATService(configuration: serverConfig)

        // Register handler
        let registry = AutoNATMockRegistry()
        await server.registerHandler(registry: registry)

        // Create streams
        let (clientStream, serverStream) = AutoNATMockStream.createPair(
            protocolID: AutoNATProtocol.protocolID
        )

        // Simulate client sending DIAL request
        let clientTask = Task<AutoNATDialResponse, any Error> {
            // Send DIAL request
            let request = AutoNATMessage.dial(addresses: [clientAddress])
            let requestData = AutoNATProtobuf.encode(request)
            try await clientStream.writeLengthPrefixedMessage(ByteBuffer(bytes: requestData))

            // Read response
            let responseData = try await clientStream.readLengthPrefixedMessage()
            let response = try AutoNATProtobuf.decode(Data(buffer: responseData))

            guard let dialResponse = response.dialResponse else {
                throw AutoNATTestError.dialFailed
            }
            return dialResponse
        }

        // Run server handler
        if let handler = registry.getHandler(for: AutoNATProtocol.protocolID) {
            let context = createAutoNATContext(
                stream: serverStream,
                remotePeer: clientKey.peerID,
                localPeer: serverKey.peerID,
                remoteAddress: clientAddress  // Same IP as client
            )
            await handler(context)
        }

        let response = try await clientTask.value

        // Verify server dialed back
        #expect(dialer.dialAttempts.count > 0)
        #expect(response.status == .ok)
    }

    @Test("Server filters addresses by observed IP")
    func testServerIPFiltering() async throws {
        let clientKey = KeyPair.generateEd25519()
        let serverKey = KeyPair.generateEd25519()

        // Client claims addresses from different IPs
        let validAddress = try Multiaddr("/ip4/192.168.1.100/tcp/4001")
        let invalidAddress = try Multiaddr("/ip4/10.0.0.1/tcp/4001")  // Different IP

        let dialer = AutoNATMockDialer()
        dialer.setReachable([validAddress, invalidAddress])

        let serverConfig = AutoNATConfiguration(
            dialer: { addr in try await dialer.dial(addr) }
        )
        let server = AutoNATService(configuration: serverConfig)

        // Register handler
        let registry = AutoNATMockRegistry()
        await server.registerHandler(registry: registry)

        // Create streams
        let (clientStream, serverStream) = AutoNATMockStream.createPair(
            protocolID: AutoNATProtocol.protocolID
        )

        // Client sends both addresses
        let clientTask = Task<AutoNATDialResponse, any Error> {
            let request = AutoNATMessage.dial(addresses: [validAddress, invalidAddress])
            let requestData = AutoNATProtobuf.encode(request)
            try await clientStream.writeLengthPrefixedMessage(ByteBuffer(bytes: requestData))

            let responseData = try await clientStream.readLengthPrefixedMessage()
            let response = try AutoNATProtobuf.decode(Data(buffer: responseData))
            return response.dialResponse!
        }

        // Run server - observed address matches validAddress IP
        if let handler = registry.getHandler(for: AutoNATProtocol.protocolID) {
            let context = createAutoNATContext(
                stream: serverStream,
                remotePeer: clientKey.peerID,
                localPeer: serverKey.peerID,
                remoteAddress: try Multiaddr("/ip4/192.168.1.100/tcp/5000")  // Same IP as validAddress
            )
            await handler(context)
        }

        let response = try await clientTask.value

        // Server should only dial validAddress (matching IP)
        #expect(response.status == .ok)
        // Only the matching IP should be dialed
        #expect(dialer.dialAttempts.allSatisfy { addr in
            addr.description.contains("192.168.1.100")
        })
    }

    @Test("Server returns error for no valid addresses")
    func testServerNoValidAddresses() async throws {
        let clientKey = KeyPair.generateEd25519()
        let serverKey = KeyPair.generateEd25519()

        // Client claims address from different IP than observed
        let claimedAddress = try Multiaddr("/ip4/10.0.0.1/tcp/4001")

        let dialer = AutoNATMockDialer()

        let serverConfig = AutoNATConfiguration(
            dialer: { addr in try await dialer.dial(addr) }
        )
        let server = AutoNATService(configuration: serverConfig)

        // Register handler
        let registry = AutoNATMockRegistry()
        await server.registerHandler(registry: registry)

        // Create streams
        let (clientStream, serverStream) = AutoNATMockStream.createPair(
            protocolID: AutoNATProtocol.protocolID
        )

        // Client sends address
        let clientTask = Task<AutoNATDialResponse, any Error> {
            let request = AutoNATMessage.dial(addresses: [claimedAddress])
            let requestData = AutoNATProtobuf.encode(request)
            try await clientStream.writeLengthPrefixedMessage(ByteBuffer(bytes: requestData))

            let responseData = try await clientStream.readLengthPrefixedMessage()
            let response = try AutoNATProtobuf.decode(Data(buffer: responseData))
            return response.dialResponse!
        }

        // Run server with different observed IP
        if let handler = registry.getHandler(for: AutoNATProtocol.protocolID) {
            let context = createAutoNATContext(
                stream: serverStream,
                remotePeer: clientKey.peerID,
                localPeer: serverKey.peerID,
                remoteAddress: try Multiaddr("/ip4/192.168.1.100/tcp/5000")  // Different IP
            )
            await handler(context)
        }

        let response = try await clientTask.value

        // Should return dialRefused
        #expect(response.status == .dialRefused)
        #expect(dialer.dialAttempts.isEmpty)
    }

    // MARK: - Client Tests

    @Test("Client probes multiple servers")
    func testMultipleServerProbing() async throws {
        let clientKey = KeyPair.generateEd25519()
        let server1Key = KeyPair.generateEd25519()
        let server2Key = KeyPair.generateEd25519()

        let clientAddresses = [try Multiaddr("/ip4/192.168.1.1/tcp/4001")]

        // Create servers
        let server1Dialer = AutoNATMockDialer()
        server1Dialer.setReachable(clientAddresses)
        let server1Config = AutoNATConfiguration(
            dialer: { addr in try await server1Dialer.dial(addr) }
        )
        let server1 = AutoNATService(configuration: server1Config)

        let server2Dialer = AutoNATMockDialer()
        server2Dialer.setReachable(clientAddresses)
        let server2Config = AutoNATConfiguration(
            dialer: { addr in try await server2Dialer.dial(addr) }
        )
        let server2 = AutoNATService(configuration: server2Config)

        // Register handlers
        let registry1 = AutoNATMockRegistry()
        await server1.registerHandler(registry: registry1)

        let registry2 = AutoNATMockRegistry()
        await server2.registerHandler(registry: registry2)

        // Create client
        let clientConfig = AutoNATConfiguration(
            minProbes: 2,
            getLocalAddresses: { clientAddresses }
        )
        let client = AutoNATService(configuration: clientConfig)

        // Create streams
        let (clientStream1, serverStream1) = AutoNATMockStream.createPair(
            protocolID: AutoNATProtocol.protocolID
        )
        let (clientStream2, serverStream2) = AutoNATMockStream.createPair(
            protocolID: AutoNATProtocol.protocolID
        )

        // Setup opener with both streams
        let opener = AutoNATMockOpener()
        opener.setStream(clientStream1, for: server1Key.peerID)
        opener.setStream(clientStream2, for: server2Key.peerID)

        // Run server handlers
        let serverTask1 = Task {
            if let handler = registry1.getHandler(for: AutoNATProtocol.protocolID) {
                let context = createAutoNATContext(
                    stream: serverStream1,
                    remotePeer: clientKey.peerID,
                    localPeer: server1Key.peerID,
                    remoteAddress: clientAddresses[0]
                )
                await handler(context)
            }
        }

        let serverTask2 = Task {
            if let handler = registry2.getHandler(for: AutoNATProtocol.protocolID) {
                let context = createAutoNATContext(
                    stream: serverStream2,
                    remotePeer: clientKey.peerID,
                    localPeer: server2Key.peerID,
                    remoteAddress: clientAddresses[0]
                )
                await handler(context)
            }
        }

        // Client probes both servers
        let status = try await client.probe(
            using: opener,
            servers: [server1Key.peerID, server2Key.peerID]
        )

        await serverTask1.value
        await serverTask2.value

        #expect(status.isPublic)
        // With minProbes=2, after 2 successful probes, confidence should be 1
        // (first probe doesn't increment confidence until minProbes threshold is met)
        #expect(client.confidence >= 1)
    }

    @Test("Client throws error when no servers provided")
    func testNoServersAvailable() async throws {
        let config = AutoNATConfiguration(
            getLocalAddresses: { [Multiaddr.tcp(host: "192.168.1.1", port: 4001)] }
        )
        let client = AutoNATService(configuration: config)

        let opener = AutoNATMockOpener()

        await #expect(throws: AutoNATError.self) {
            _ = try await client.probe(using: opener, servers: [])
        }
    }

    @Test("Client throws error when no local addresses")
    func testNoLocalAddresses() async throws {
        let serverKey = KeyPair.generateEd25519()

        let config = AutoNATConfiguration(
            getLocalAddresses: { [] }  // No local addresses
        )
        let client = AutoNATService(configuration: config)

        let opener = AutoNATMockOpener()
        let (stream, _) = AutoNATMockStream.createPair()
        opener.setStream(stream, for: serverKey.peerID)

        await #expect(throws: AutoNATError.self) {
            _ = try await client.probe(using: opener, servers: [serverKey.peerID])
        }
    }

    // MARK: - Reset Tests

    @Test("Status resets correctly")
    func testStatusReset() async throws {
        let config = AutoNATConfiguration(minProbes: 1)
        let service = AutoNATService(configuration: config)

        // Initial state
        #expect(service.status == .unknown)
        #expect(service.confidence == 0)

        // Reset
        service.resetStatus()

        #expect(service.status == .unknown)
        #expect(service.confidence == 0)
    }

    // MARK: - Protobuf Tests

    @Test("AutoNAT message encodes and decodes correctly")
    func testMessageRoundTrip() throws {
        // Test DIAL request
        let addresses = [
            try Multiaddr("/ip4/192.168.1.1/tcp/4001"),
            try Multiaddr("/ip4/10.0.0.1/tcp/4001")
        ]
        let dial = AutoNATMessage.dial(addresses: addresses)
        let dialEncoded = AutoNATProtobuf.encode(dial)
        let dialDecoded = try AutoNATProtobuf.decode(dialEncoded)
        #expect(dialDecoded.type == .dial)
        #expect(dialDecoded.dial?.peer.addresses.count == 2)

        // Test DIAL_RESPONSE
        let response = AutoNATMessage.dialResponse(.ok(address: addresses[0]))
        let responseEncoded = AutoNATProtobuf.encode(response)
        let responseDecoded = try AutoNATProtobuf.decode(responseEncoded)
        #expect(responseDecoded.type == .dialResponse)
        #expect(responseDecoded.dialResponse?.status == .ok)
    }

    // MARK: - Address Truncation Tests

    @Test("Client truncates addresses to maxAddresses")
    func testMaxAddressesTruncation() async throws {
        let serverKey = KeyPair.generateEd25519()

        // Create 20 addresses (more than default maxAddresses of 16)
        var manyAddresses: [Multiaddr] = []
        for i in 1...20 {
            try manyAddresses.append(Multiaddr("/ip4/192.168.1.\(i)/tcp/4001"))
        }
        let addressesCopy = manyAddresses  // Capture as let for Sendable closure

        let serverDialer = AutoNATMockDialer()
        serverDialer.setReachable(manyAddresses)

        let serverConfig = AutoNATConfiguration(
            dialer: { addr in try await serverDialer.dial(addr) }
        )
        let server = AutoNATService(configuration: serverConfig)

        let registry = AutoNATMockRegistry()
        await server.registerHandler(registry: registry)

        // Client with maxAddresses = 5 (smaller for easier testing)
        let clientConfig = AutoNATConfiguration(
            minProbes: 1,
            maxAddresses: 5,
            getLocalAddresses: { addressesCopy }
        )
        let client = AutoNATService(configuration: clientConfig)

        // Create streams
        let (clientStream, serverStream) = AutoNATMockStream.createPair(
            protocolID: AutoNATProtocol.protocolID
        )

        let opener = AutoNATMockOpener()
        opener.setStream(clientStream, for: serverKey.peerID)

        // Capture the DIAL request on server side
        actor RequestCapture {
            var receivedAddressCount: Int = 0
            func set(_ count: Int) { receivedAddressCount = count }
            func get() -> Int { receivedAddressCount }
        }
        let capture = RequestCapture()

        let serverTask = Task {
            // Read DIAL request directly to capture address count
            let requestData = try await serverStream.readLengthPrefixedMessage()
            let request = try AutoNATProtobuf.decode(Data(buffer: requestData))
            await capture.set(request.dial?.peer.addresses.count ?? 0)

            // Send OK response
            let response = AutoNATMessage.dialResponse(.ok(address: manyAddresses[0]))
            try await serverStream.writeLengthPrefixedMessage(ByteBuffer(bytes: AutoNATProtobuf.encode(response)))
        }

        _ = try await client.probe(using: opener, servers: [serverKey.peerID])

        try await serverTask.value

        // Verify only 5 addresses were sent (maxAddresses = 5)
        let receivedCount = await capture.get()
        #expect(receivedCount == 5, "Expected 5 addresses but got \(receivedCount)")
    }

    @Test("Client sends all addresses when count equals maxAddresses")
    func testMaxAddressesBoundary() async throws {
        let serverKey = KeyPair.generateEd25519()

        // Create exactly 8 addresses
        var addresses: [Multiaddr] = []
        for i in 1...8 {
            try addresses.append(Multiaddr("/ip4/192.168.1.\(i)/tcp/4001"))
        }
        let addressesCopy = addresses  // Capture as let for Sendable closure

        let serverDialer = AutoNATMockDialer()
        serverDialer.setReachable(addresses)

        let serverConfig = AutoNATConfiguration(
            dialer: { addr in try await serverDialer.dial(addr) }
        )
        let server = AutoNATService(configuration: serverConfig)

        let registry = AutoNATMockRegistry()
        await server.registerHandler(registry: registry)

        // Client with maxAddresses = 8 (exact match)
        let clientConfig = AutoNATConfiguration(
            minProbes: 1,
            maxAddresses: 8,
            getLocalAddresses: { addressesCopy }
        )
        let client = AutoNATService(configuration: clientConfig)

        let (clientStream, serverStream) = AutoNATMockStream.createPair(
            protocolID: AutoNATProtocol.protocolID
        )

        let opener = AutoNATMockOpener()
        opener.setStream(clientStream, for: serverKey.peerID)

        actor RequestCapture {
            var receivedAddressCount: Int = 0
            func set(_ count: Int) { receivedAddressCount = count }
            func get() -> Int { receivedAddressCount }
        }
        let capture = RequestCapture()

        let serverTask = Task {
            let requestData = try await serverStream.readLengthPrefixedMessage()
            let request = try AutoNATProtobuf.decode(Data(buffer: requestData))
            await capture.set(request.dial?.peer.addresses.count ?? 0)

            let response = AutoNATMessage.dialResponse(.ok(address: addresses[0]))
            try await serverStream.writeLengthPrefixedMessage(ByteBuffer(bytes: AutoNATProtobuf.encode(response)))
        }

        _ = try await client.probe(using: opener, servers: [serverKey.peerID])

        try await serverTask.value

        // Verify all 8 addresses were sent
        let receivedCount = await capture.get()
        #expect(receivedCount == 8, "Expected 8 addresses but got \(receivedCount)")
    }

    @Test("Client sends fewer addresses when count is less than maxAddresses")
    func testFewerThanMaxAddresses() async throws {
        let serverKey = KeyPair.generateEd25519()

        // Create only 3 addresses (less than default maxAddresses of 16)
        let addresses = [
            try Multiaddr("/ip4/192.168.1.1/tcp/4001"),
            try Multiaddr("/ip4/192.168.1.2/tcp/4001"),
            try Multiaddr("/ip4/192.168.1.3/tcp/4001")
        ]

        let serverDialer = AutoNATMockDialer()
        serverDialer.setReachable(addresses)

        let serverConfig = AutoNATConfiguration(
            dialer: { addr in try await serverDialer.dial(addr) }
        )
        let server = AutoNATService(configuration: serverConfig)

        let registry = AutoNATMockRegistry()
        await server.registerHandler(registry: registry)

        let clientConfig = AutoNATConfiguration(
            minProbes: 1,
            getLocalAddresses: { addresses }
        )
        let client = AutoNATService(configuration: clientConfig)

        let (clientStream, serverStream) = AutoNATMockStream.createPair(
            protocolID: AutoNATProtocol.protocolID
        )

        let opener = AutoNATMockOpener()
        opener.setStream(clientStream, for: serverKey.peerID)

        actor RequestCapture {
            var receivedAddressCount: Int = 0
            func set(_ count: Int) { receivedAddressCount = count }
            func get() -> Int { receivedAddressCount }
        }
        let capture = RequestCapture()

        let serverTask = Task {
            let requestData = try await serverStream.readLengthPrefixedMessage()
            let request = try AutoNATProtobuf.decode(Data(buffer: requestData))
            await capture.set(request.dial?.peer.addresses.count ?? 0)

            let response = AutoNATMessage.dialResponse(.ok(address: addresses[0]))
            try await serverStream.writeLengthPrefixedMessage(ByteBuffer(bytes: AutoNATProtobuf.encode(response)))
        }

        _ = try await client.probe(using: opener, servers: [serverKey.peerID])

        try await serverTask.value

        // Verify all 3 addresses were sent (no truncation)
        let receivedCount = await capture.get()
        #expect(receivedCount == 3, "Expected 3 addresses but got \(receivedCount)")
    }

    // MARK: - Event Tests

    @Test("Service emits events during probe")
    func testEventEmission() async throws {
        let clientKey = KeyPair.generateEd25519()
        let serverKey = KeyPair.generateEd25519()

        let clientAddresses = [try Multiaddr("/ip4/192.168.1.1/tcp/4001")]

        let serverDialer = AutoNATMockDialer()
        serverDialer.setReachable(clientAddresses)

        let serverConfig = AutoNATConfiguration(
            dialer: { addr in try await serverDialer.dial(addr) }
        )
        let server = AutoNATService(configuration: serverConfig)

        let registry = AutoNATMockRegistry()
        await server.registerHandler(registry: registry)

        let clientConfig = AutoNATConfiguration(
            minProbes: 1,
            getLocalAddresses: { clientAddresses }
        )
        let client = AutoNATService(configuration: clientConfig)

        // Collect events using actor
        actor EventCollector {
            var events: [AutoNATEvent] = []
            func add(_ event: AutoNATEvent) { events.append(event) }
            func getEvents() -> [AutoNATEvent] { events }
        }
        let collector = EventCollector()

        let eventTask = Task {
            for await event in client.events {
                await collector.add(event)
                if case .statusChanged = event { break }
            }
        }

        // Create streams
        let (clientStream, serverStream) = AutoNATMockStream.createPair(
            protocolID: AutoNATProtocol.protocolID
        )

        let opener = AutoNATMockOpener()
        opener.setStream(clientStream, for: serverKey.peerID)

        let serverTask = Task {
            if let handler = registry.getHandler(for: AutoNATProtocol.protocolID) {
                let context = createAutoNATContext(
                    stream: serverStream,
                    remotePeer: clientKey.peerID,
                    localPeer: serverKey.peerID,
                    remoteAddress: clientAddresses[0]
                )
                await handler(context)
            }
        }

        _ = try await client.probe(using: opener, servers: [serverKey.peerID])

        await serverTask.value

        // Give eventTask time to collect events before shutting down
        try await Task.sleep(for: .milliseconds(10))

        // Properly shutdown and await event task
        client.shutdown()
        await eventTask.value

        let receivedEvents = await collector.getEvents()
        #expect(receivedEvents.contains { event in
            if case .probeStarted = event { return true }
            return false
        })
    }
}
