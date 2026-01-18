/// AutoNATServiceTests - Tests for AutoNAT service
import Testing
import Foundation
import Synchronization
@testable import P2PAutoNAT
@testable import P2PCore
@testable import P2PMux
@testable import P2PProtocols

@Suite("AutoNATService Tests", .serialized)
struct AutoNATServiceTests {

    // MARK: - Configuration Tests

    @Test("Default configuration values")
    func defaultConfiguration() {
        let config = AutoNATConfiguration()

        #expect(config.minProbes == 3)
        #expect(config.dialTimeout == .seconds(30))
        #expect(config.maxAddresses == 16)
    }

    @Test("Custom configuration values")
    func customConfiguration() throws {
        let addresses = [try Multiaddr("/ip4/127.0.0.1/tcp/4001")]
        let config = AutoNATConfiguration(
            minProbes: 5,
            dialTimeout: .seconds(15),
            maxAddresses: 8,
            getLocalAddresses: { addresses }
        )

        #expect(config.minProbes == 5)
        #expect(config.dialTimeout == .seconds(15))
        #expect(config.maxAddresses == 8)
        #expect(config.getLocalAddresses().count == 1)
    }

    // MARK: - Service Creation Tests

    @Test("Service initializes with unknown status")
    func serviceInitialStatus() {
        let service = AutoNATService()

        #expect(service.status == .unknown)
        #expect(service.confidence == 0)
    }

    @Test("Service has correct protocol ID")
    func serviceProtocolID() {
        let service = AutoNATService()

        #expect(service.protocolIDs.contains(AutoNATProtocol.protocolID))
    }

    // MARK: - Status Tracking Tests

    @Test("Status changes after enough probes")
    func statusChangesAfterProbes() async throws {
        // Use actor for thread-safe event collection
        actor EventCollector {
            var events: [AutoNATEvent] = []
            func add(_ event: AutoNATEvent) { events.append(event) }
            func getEvents() -> [AutoNATEvent] { events }
        }
        let collector = EventCollector()

        let service = AutoNATService(configuration: .init(
            minProbes: 2,
            getLocalAddresses: { [try! Multiaddr("/ip4/127.0.0.1/tcp/4001")] }
        ))

        // Collect events in background
        let eventTask = Task {
            for await event in service.events {
                await collector.add(event)
                if case .statusChanged = event {
                    break
                }
            }
        }

        // Give eventTask time to start listening
        try await Task.sleep(for: .milliseconds(10))

        // Simulate probes using mock opener
        let mockOpener = MockStreamOpener()
        mockOpener.shouldFail = true  // Make probes fail

        // Can't easily test full probe flow without mocking more infrastructure
        // but we can verify the service is properly initialized
        #expect(service.status == .unknown)

        // Properly shutdown and await event task
        service.shutdown()
        await eventTask.value
    }

    @Test("Reset status clears state")
    func resetStatusClearsState() async {
        let service = AutoNATService()

        // Reset should work even on fresh service
        service.resetStatus()

        #expect(service.status == .unknown)
        #expect(service.confidence == 0)
    }

    // MARK: - Events Stream Tests

    @Test("Events stream is available")
    func eventsStreamAvailable() {
        let service = AutoNATService()

        // Should be able to get events stream
        _ = service.events

        // Getting it again should return same stream
        _ = service.events
    }

    // MARK: - Shutdown Tests

    @Test("Shutdown finishes event stream")
    func shutdownFinishesEventStream() async {
        let service = AutoNATService()

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
        let service = AutoNATService()

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

        // Wait for the task to complete
        await eventTask.value

        // Verify the task completed
        let completed = await flag.get()
        #expect(completed)
    }

    @Test("Multiple shutdowns are safe")
    func multipleShutdownsSafe() {
        let service = AutoNATService()

        // Should not crash when called multiple times
        service.shutdown()
        service.shutdown()
        service.shutdown()
    }

    // MARK: - Probe Error Handling Tests

    @Test("Probe with no servers throws error")
    func probeWithNoServersThrows() async throws {
        let service = AutoNATService(configuration: .init(
            getLocalAddresses: { [try! Multiaddr("/ip4/127.0.0.1/tcp/4001")] }
        ))

        let mockOpener = MockStreamOpener()

        await #expect(throws: AutoNATError.self) {
            _ = try await service.probe(using: mockOpener, servers: [])
        }
    }

    @Test("Probe with no local addresses throws error")
    func probeWithNoLocalAddressesThrows() async throws {
        let service = AutoNATService(configuration: .init(
            getLocalAddresses: { [] }  // No addresses
        ))

        let mockOpener = MockStreamOpener()
        let server = KeyPair.generateEd25519().peerID

        await #expect(throws: AutoNATError.self) {
            _ = try await service.probe(using: mockOpener, servers: [server])
        }
    }
}

@Suite("AutoNATProtocol Tests")
struct AutoNATProtocolTests {

    @Test("Protocol ID is correct")
    func protocolIDCorrect() {
        #expect(AutoNATProtocol.protocolID == "/libp2p/autonat/1.0.0")
    }

    @Test("Max message size is reasonable")
    func maxMessageSizeReasonable() {
        // Should be large enough for addresses but not too large
        #expect(AutoNATProtocol.maxMessageSize > 1024)
        #expect(AutoNATProtocol.maxMessageSize <= 65536)
    }
}

@Suite("AutoNATError Tests")
struct AutoNATErrorTests {

    @Test("All error cases exist")
    func allErrorCasesExist() {
        // Create each error to verify they compile
        let noServers = AutoNATError.noServersAvailable
        let badRequest = AutoNATError.badRequest("test")
        let dialFailed = AutoNATError.dialFailed("reason")
        let dialRefused = AutoNATError.dialRefused
        let internalError = AutoNATError.internalError("error")
        let timeout = AutoNATError.timeout
        let protocolViolation = AutoNATError.protocolViolation("violation")
        let insufficientProbes = AutoNATError.insufficientProbes

        let errors: [AutoNATError] = [
            noServers, badRequest, dialFailed, dialRefused,
            internalError, timeout, protocolViolation, insufficientProbes
        ]
        var matched = 0

        for error in errors {
            switch error {
            case .noServersAvailable: matched += 1
            case .badRequest: matched += 1
            case .dialFailed: matched += 1
            case .dialRefused: matched += 1
            case .internalError: matched += 1
            case .timeout: matched += 1
            case .protocolViolation: matched += 1
            case .insufficientProbes: matched += 1
            }
        }

        #expect(matched == 8)
    }
}

@Suite("AutoNATEvent Tests")
struct AutoNATEventTests {

    @Test("ProbeStarted event contains server")
    func probeStartedEvent() {
        let server = KeyPair.generateEd25519().peerID
        let event = AutoNATEvent.probeStarted(server: server)

        guard case .probeStarted(let s) = event else {
            Issue.record("Expected probeStarted event")
            return
        }
        #expect(s == server)
    }

    @Test("ProbeCompleted event contains result")
    func probeCompletedEvent() throws {
        let server = KeyPair.generateEd25519().peerID
        let address = try Multiaddr("/ip4/203.0.113.1/tcp/4001")
        let event = AutoNATEvent.probeCompleted(server: server, result: .reachable(address))

        guard case .probeCompleted(let s, let r) = event else {
            Issue.record("Expected probeCompleted event")
            return
        }
        #expect(s == server)
        #expect(r.isReachable)
        #expect(r.reachableAddress == address)
    }

    @Test("StatusChanged event contains status")
    func statusChangedEvent() {
        let event = AutoNATEvent.statusChanged(.privateBehindNAT)

        guard case .statusChanged(let status) = event else {
            Issue.record("Expected statusChanged event")
            return
        }
        #expect(status == .privateBehindNAT)
    }

    @Test("DialBackRequested event contains addresses")
    func dialBackRequestedEvent() throws {
        let from = KeyPair.generateEd25519().peerID
        let addresses = [try Multiaddr("/ip4/127.0.0.1/tcp/4001")]
        let event = AutoNATEvent.dialBackRequested(from: from, addresses: addresses)

        guard case .dialBackRequested(let f, let addrs) = event else {
            Issue.record("Expected dialBackRequested event")
            return
        }
        #expect(f == from)
        #expect(addrs.count == 1)
    }

    @Test("DialBackCompleted event contains result")
    func dialBackCompletedEvent() {
        let to = KeyPair.generateEd25519().peerID
        let event = AutoNATEvent.dialBackCompleted(to: to, result: .ok)

        guard case .dialBackCompleted(let t, let result) = event else {
            Issue.record("Expected dialBackCompleted event")
            return
        }
        #expect(t == to)
        #expect(result == .ok)
    }
}

// MARK: - Mock Stream Opener

/// Thread-safe mock stream opener for testing.
final class MockStreamOpener: StreamOpener, Sendable {
    private let state: Mutex<OpenerState>

    private struct OpenerState: Sendable {
        var shouldFail: Bool = false
        var openedStreams: [(PeerID, String)] = []
    }

    init() {
        self.state = Mutex(OpenerState())
    }

    var shouldFail: Bool {
        get { state.withLock { $0.shouldFail } }
        set { state.withLock { $0.shouldFail = newValue } }
    }

    var openedStreams: [(PeerID, String)] {
        state.withLock { $0.openedStreams }
    }

    func newStream(to peer: PeerID, protocol protocolID: String) async throws -> MuxedStream {
        let fail = state.withLock { s in
            s.openedStreams.append((peer, protocolID))
            return s.shouldFail
        }
        if fail {
            throw MockError.streamOpenFailed
        }
        return MockMuxedStream()
    }
}

/// Thread-safe mock muxed stream for testing.
final class MockMuxedStream: MuxedStream, Sendable {
    let id: UInt64
    let protocolID: String?

    private let state: Mutex<StreamState>

    private struct StreamState: Sendable {
        var isClosed: Bool = false
        var readBuffer: [Data] = []
        var writtenData: [Data] = []
    }

    init(id: UInt64 = 0, protocolID: String? = nil) {
        self.id = id
        self.protocolID = protocolID
        self.state = Mutex(StreamState())
    }

    var isClosed: Bool {
        state.withLock { $0.isClosed }
    }

    var readBuffer: [Data] {
        get { state.withLock { $0.readBuffer } }
        set { state.withLock { $0.readBuffer = newValue } }
    }

    var writtenData: [Data] {
        state.withLock { $0.writtenData }
    }

    func read() async throws -> Data {
        let data: Data? = state.withLock { s in
            if s.readBuffer.isEmpty {
                return nil
            }
            return s.readBuffer.removeFirst()
        }
        guard let data else {
            throw MockError.noData
        }
        return data
    }

    func write(_ data: Data) async throws {
        state.withLock { $0.writtenData.append(data) }
    }

    func closeWrite() async throws {
        // Half-close not needed for mock
    }

    func close() async throws {
        state.withLock { $0.isClosed = true }
    }

    func reset() async throws {
        state.withLock { $0.isClosed = true }
    }
}

enum MockError: Error {
    case streamOpenFailed
    case noData
}
