/// DCUtRServiceTests - Tests for DCUtR (Direct Connection Upgrade through Relay) service
import Testing
import Foundation
import Synchronization
@testable import P2PDCUtR
@testable import P2PCore
@testable import P2PMux
@testable import P2PProtocols

@Suite("DCUtRService Tests", .serialized)
struct DCUtRServiceTests {

    // MARK: - Configuration Tests

    @Test("Default configuration values")
    func defaultConfiguration() {
        let config = DCUtRConfiguration()

        #expect(config.timeout == .seconds(30))
        #expect(config.maxAttempts == 3)
    }

    @Test("Custom configuration values")
    func customConfiguration() throws {
        let addresses = [try Multiaddr("/ip4/127.0.0.1/tcp/4001")]
        let config = DCUtRConfiguration(
            timeout: .seconds(15),
            maxAttempts: 5,
            getLocalAddresses: { addresses }
        )

        #expect(config.timeout == .seconds(15))
        #expect(config.maxAttempts == 5)
        #expect(config.getLocalAddresses().count == 1)
    }

    // MARK: - Service Creation Tests

    @Test("Service initializes correctly")
    func serviceInitializes() {
        let service = DCUtRService()

        #expect(service.protocolIDs.count == 1)
        #expect(service.protocolIDs.contains(DCUtRProtocol.protocolID))
    }

    @Test("Service has correct protocol ID")
    func serviceProtocolID() {
        let service = DCUtRService()

        #expect(service.protocolIDs.first == "/libp2p/dcutr")
    }

    // MARK: - Events Stream Tests

    @Test("Events stream is available")
    func eventsStreamAvailable() {
        let service = DCUtRService()

        // Should be able to get events stream
        _ = service.events

        // Getting it again should return same stream
        _ = service.events
    }

    // MARK: - Shutdown Tests

    @Test("Shutdown finishes event stream")
    func shutdownFinishesEventStream() async {
        let service = DCUtRService()

        // Start consuming events in background
        let eventTask = Task {
            var count = 0
            for await _ in service.events {
                count += 1
            }
            return count
        }

        // Give eventTask time to start listening
        try? await Task.sleep(for: .milliseconds(10))

        // Shutdown should finish the stream
        service.shutdown()

        // eventTask should complete (not hang)
        let result = await eventTask.value
        #expect(result == 0)  // No events were emitted
    }

    @Test("Shutdown unblocks waiting consumers")
    func shutdownUnblocksConsumers() async {
        let service = DCUtRService()

        actor Flag {
            var completed = false
            func set() { completed = true }
            func get() -> Bool { completed }
        }
        let flag = Flag()

        // Start a task that waits on events
        let eventTask = Task {
            for await _ in service.events {
                // This loop should exit when shutdown is called
            }
            await flag.set()
        }

        // Give eventTask time to start listening
        try? await Task.sleep(for: .milliseconds(10))

        // Shutdown should unblock the consumer
        service.shutdown()

        // Wait a bit for the task to complete
        try? await Task.sleep(for: .milliseconds(10))

        // Verify the task completed
        let completed = await flag.get()
        #expect(completed)

        eventTask.cancel()
    }

    @Test("Multiple shutdowns are safe")
    func multipleShutdownsSafe() {
        let service = DCUtRService()

        // Should not crash when called multiple times
        service.shutdown()
        service.shutdown()
        service.shutdown()
    }

    // MARK: - Upgrade Error Handling Tests

    @Test("Upgrade fails with no addresses from peer")
    func upgradeFailsNoAddresses() async {
        let service = DCUtRService(configuration: .init(
            getLocalAddresses: { [Multiaddr.tcp(host: "127.0.0.1", port: 4001)] }
        ))

        let mockOpener = DCUtRMockStreamOpener()
        let peer = KeyPair.generateEd25519().peerID

        // Configure mock to return empty addresses in CONNECT response
        mockOpener.connectResponseAddresses = []

        do {
            try await service.upgradeToDirectConnection(
                with: peer,
                using: mockOpener,
                dialer: { _ in }
            )
            Issue.record("Expected noAddresses error")
        } catch let error as DCUtRError {
            if case .noAddresses = error {
                // Expected
            } else if case .protocolViolation = error {
                // Also acceptable if stream closed early
            } else {
                Issue.record("Expected noAddresses or protocolViolation, got \(error)")
            }
        } catch {
            // Stream errors are acceptable
        }
    }
}

@Suite("DCUtRConfiguration Tests")
struct DCUtRConfigurationTests {

    @Test("Configuration with dialer")
    func configurationWithDialer() {
        let config = DCUtRConfiguration(
            getLocalAddresses: { [] },
            dialer: { _ in }
        )

        #expect(config.dialer != nil)
    }

    @Test("Configuration without dialer")
    func configurationWithoutDialer() {
        let config = DCUtRConfiguration(
            getLocalAddresses: { [] }
        )

        #expect(config.dialer == nil)
    }
}

@Suite("DCUtRProtocol Tests")
struct DCUtRProtocolTests {

    @Test("Protocol ID is correct")
    func protocolIDCorrect() {
        #expect(DCUtRProtocol.protocolID == "/libp2p/dcutr")
    }

    @Test("Max message size is reasonable")
    func maxMessageSizeReasonable() {
        #expect(DCUtRProtocol.maxMessageSize > 1024)
        #expect(DCUtRProtocol.maxMessageSize <= 65536)
    }
}

@Suite("DCUtRError Tests")
struct DCUtRErrorTests {

    @Test("All error cases exist")
    func allErrorCasesExist() {
        // Create each error to verify they compile
        let noAddresses = DCUtRError.noAddresses
        let allDialsFailed = DCUtRError.allDialsFailed
        let holePunchFailed = DCUtRError.holePunchFailed("reason")
        let protocolViolation = DCUtRError.protocolViolation("violation")
        let timeout = DCUtRError.timeout
        let notRelayedConnection = DCUtRError.notRelayedConnection
        let encodingError = DCUtRError.encodingError("encoding failed")
        let maxAttemptsExceeded = DCUtRError.maxAttemptsExceeded(allDialsFailed)

        let errors: [DCUtRError] = [
            noAddresses, allDialsFailed, holePunchFailed,
            protocolViolation, timeout, notRelayedConnection, encodingError,
            maxAttemptsExceeded
        ]
        var matched = 0

        for error in errors {
            switch error {
            case .noAddresses: matched += 1
            case .allDialsFailed: matched += 1
            case .holePunchFailed: matched += 1
            case .protocolViolation: matched += 1
            case .timeout: matched += 1
            case .notRelayedConnection: matched += 1
            case .encodingError: matched += 1
            case .maxAttemptsExceeded: matched += 1
            }
        }

        #expect(matched == 8)
    }

    @Test("MaxAttemptsExceeded contains underlying error")
    func maxAttemptsExceededContainsError() {
        let underlying = DCUtRError.allDialsFailed
        let error = DCUtRError.maxAttemptsExceeded(underlying)

        guard case .maxAttemptsExceeded(let inner) = error else {
            Issue.record("Expected maxAttemptsExceeded error")
            return
        }
        #expect(inner is DCUtRError)
    }

    @Test("HolePunchFailed contains reason")
    func holePunchFailedReason() {
        let error = DCUtRError.holePunchFailed("connection refused")

        guard case .holePunchFailed(let reason) = error else {
            Issue.record("Expected holePunchFailed error")
            return
        }
        #expect(reason == "connection refused")
    }

    @Test("ProtocolViolation contains message")
    func protocolViolationMessage() {
        let error = DCUtRError.protocolViolation("unexpected message type")

        guard case .protocolViolation(let msg) = error else {
            Issue.record("Expected protocolViolation error")
            return
        }
        #expect(msg == "unexpected message type")
    }
}

@Suite("DCUtREvent Tests")
struct DCUtREventTests {

    @Test("HolePunchAttemptStarted event contains peer and attempt number")
    func holePunchAttemptStartedEvent() {
        let peer = KeyPair.generateEd25519().peerID
        let event = DCUtREvent.holePunchAttemptStarted(peer: peer, attempt: 2)

        guard case .holePunchAttemptStarted(let p, let attempt) = event else {
            Issue.record("Expected holePunchAttemptStarted event")
            return
        }
        #expect(p == peer)
        #expect(attempt == 2)
    }

    @Test("HolePunchAttemptStarted default attempt is 1")
    func holePunchAttemptStartedDefaultAttempt() {
        let peer = KeyPair.generateEd25519().peerID
        let event = DCUtREvent.holePunchAttemptStarted(peer: peer)

        guard case .holePunchAttemptStarted(_, let attempt) = event else {
            Issue.record("Expected holePunchAttemptStarted event")
            return
        }
        #expect(attempt == 1)
    }

    @Test("HolePunchAttemptFailed event contains retry info")
    func holePunchAttemptFailedEvent() {
        let peer = KeyPair.generateEd25519().peerID
        let event = DCUtREvent.holePunchAttemptFailed(
            peer: peer,
            attempt: 2,
            maxAttempts: 3,
            reason: "connection refused"
        )

        guard case .holePunchAttemptFailed(let p, let attempt, let maxAttempts, let reason) = event else {
            Issue.record("Expected holePunchAttemptFailed event")
            return
        }
        #expect(p == peer)
        #expect(attempt == 2)
        #expect(maxAttempts == 3)
        #expect(reason == "connection refused")
    }

    @Test("AddressExchangeCompleted event contains addresses")
    func addressExchangeCompletedEvent() throws {
        let peer = KeyPair.generateEd25519().peerID
        let addresses = [try Multiaddr("/ip4/192.168.1.1/tcp/4001")]
        let event = DCUtREvent.addressExchangeCompleted(peer: peer, theirAddresses: addresses)

        guard case .addressExchangeCompleted(let p, let addrs) = event else {
            Issue.record("Expected addressExchangeCompleted event")
            return
        }
        #expect(p == peer)
        #expect(addrs.count == 1)
    }

    @Test("DirectConnectionEstablished event contains address")
    func directConnectionEstablishedEvent() throws {
        let peer = KeyPair.generateEd25519().peerID
        let address = try Multiaddr("/ip4/192.168.1.1/tcp/4001")
        let event = DCUtREvent.directConnectionEstablished(peer: peer, address: address)

        guard case .directConnectionEstablished(let p, let addr) = event else {
            Issue.record("Expected directConnectionEstablished event")
            return
        }
        #expect(p == peer)
        #expect(addr == address)
    }

    @Test("HolePunchFailed event contains reason")
    func holePunchFailedEvent() {
        let peer = KeyPair.generateEd25519().peerID
        let event = DCUtREvent.holePunchFailed(peer: peer, reason: "all dials failed")

        guard case .holePunchFailed(let p, let reason) = event else {
            Issue.record("Expected holePunchFailed event")
            return
        }
        #expect(p == peer)
        #expect(reason == "all dials failed")
    }
}

@Suite("DCUtRMessage Tests")
struct DCUtRMessageTests {

    @Test("Connect message with addresses")
    func connectMessageWithAddresses() throws {
        let addresses = [
            try Multiaddr("/ip4/127.0.0.1/tcp/4001"),
            try Multiaddr("/ip4/192.168.1.1/tcp/4001"),
        ]

        let message = DCUtRMessage.connect(addresses: addresses)

        #expect(message.type == .connect)
        #expect(message.observedAddresses.count == 2)
    }

    @Test("Connect message without addresses")
    func connectMessageWithoutAddresses() {
        let message = DCUtRMessage.connect(addresses: [])

        #expect(message.type == .connect)
        #expect(message.observedAddresses.isEmpty)
    }

    @Test("Sync message has no addresses")
    func syncMessageNoAddresses() {
        let message = DCUtRMessage.sync()

        #expect(message.type == .sync)
        #expect(message.observedAddresses.isEmpty)
    }
}

// MARK: - DCUtR Mock Stream Opener

/// Thread-safe mock stream opener for DCUtR tests.
final class DCUtRMockStreamOpener: StreamOpener, Sendable {
    private let state: Mutex<OpenerState>

    private struct OpenerState: Sendable {
        var connectResponseAddresses: [Multiaddr] = []
        var openedStreams: [(PeerID, String)] = []
    }

    init() {
        self.state = Mutex(OpenerState())
    }

    var connectResponseAddresses: [Multiaddr] {
        get { state.withLock { $0.connectResponseAddresses } }
        set { state.withLock { $0.connectResponseAddresses = newValue } }
    }

    var openedStreams: [(PeerID, String)] {
        state.withLock { $0.openedStreams }
    }

    func newStream(to peer: PeerID, protocol protocolID: String) async throws -> MuxedStream {
        let addresses = state.withLock { s in
            s.openedStreams.append((peer, protocolID))
            return s.connectResponseAddresses
        }
        return DCUtRMockMuxedStream(connectResponseAddresses: addresses)
    }
}

/// Thread-safe mock muxed stream for DCUtR tests.
final class DCUtRMockMuxedStream: MuxedStream, Sendable {
    let id: UInt64
    let protocolID: String?

    private let state: Mutex<StreamState>

    private struct StreamState: Sendable {
        var isClosed: Bool = false
        var connectResponseAddresses: [Multiaddr]
        var readIndex: Int = 0
        var writtenData: [Data] = []
    }

    init(id: UInt64 = 0, protocolID: String? = nil, connectResponseAddresses: [Multiaddr] = []) {
        self.id = id
        self.protocolID = protocolID
        self.state = Mutex(StreamState(connectResponseAddresses: connectResponseAddresses))
    }

    var isClosed: Bool {
        state.withLock { $0.isClosed }
    }

    var writtenData: [Data] {
        state.withLock { $0.writtenData }
    }

    func read() async throws -> Data {
        // Atomically check and increment readIndex
        let (shouldRespond, addresses) = state.withLock { s -> (Bool, [Multiaddr]) in
            if s.readIndex == 0 {
                s.readIndex += 1
                return (true, s.connectResponseAddresses)
            }
            return (false, [])
        }

        if shouldRespond {
            // Return a CONNECT response with configured addresses
            let response = DCUtRMessage.connect(addresses: addresses)
            let encoded = DCUtRProtobuf.encode(response)
            // Add length prefix
            var data = Data()
            data.append(contentsOf: Varint.encode(UInt64(encoded.count)))
            data.append(encoded)
            return data
        }
        throw DCUtRMockError.noData
    }

    func write(_ data: Data) async throws {
        state.withLock { $0.writtenData.append(data) }
    }

    func closeWrite() async throws {
        // Half-close not needed for mock
    }

    func closeRead() async throws {
        // Half-close not needed for mock
    }

    func close() async throws {
        state.withLock { $0.isClosed = true }
    }

    func reset() async throws {
        state.withLock { $0.isClosed = true }
    }
}

enum DCUtRMockError: Error {
    case noData
}
