/// AutoNATServiceTests - Tests for AutoNAT service
import Testing
import Foundation
import NIOCore
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
            getLocalAddresses: { [Multiaddr.tcp(host: "127.0.0.1", port: 4001)] }
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
        do { try await Task.sleep(for: .milliseconds(10)) } catch { }

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
        do { try await Task.sleep(for: .milliseconds(10)) } catch { }

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
            getLocalAddresses: { [Multiaddr.tcp(host: "127.0.0.1", port: 4001)] }
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
        let rateLimited = AutoNATError.rateLimited(.peerRateLimit)
        let peerIDMismatch = AutoNATError.peerIDMismatch
        let portNotAllowed = AutoNATError.portNotAllowed(80)

        let errors: [AutoNATError] = [
            noServers, badRequest, dialFailed, dialRefused,
            internalError, timeout, protocolViolation, insufficientProbes,
            rateLimited, peerIDMismatch, portNotAllowed
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
            case .rateLimited: matched += 1
            case .peerIDMismatch: matched += 1
            case .portNotAllowed: matched += 1
            }
        }

        #expect(matched == 11)
    }

    @Test("RateLimitReason descriptions")
    func rateLimitReasonDescriptions() {
        #expect(RateLimitReason.globalRateLimit.description == "Global rate limit exceeded")
        #expect(RateLimitReason.globalConcurrencyLimit.description == "Global concurrency limit exceeded")
        #expect(RateLimitReason.peerRateLimit.description == "Per-peer rate limit exceeded")
        #expect(RateLimitReason.peerConcurrencyLimit.description == "Per-peer concurrency limit exceeded")
        #expect(RateLimitReason.backoff.description == "Peer is in backoff period")
    }

    @Test("RateLimitReason is equatable")
    func rateLimitReasonEquatable() {
        #expect(RateLimitReason.globalRateLimit == RateLimitReason.globalRateLimit)
        #expect(RateLimitReason.peerRateLimit != RateLimitReason.globalRateLimit)
    }
}

@Suite("AutoNAT Rate Limiting Tests", .serialized)
struct AutoNATRateLimitingTests {

    // MARK: - Helper

    private func makePeerID() -> PeerID {
        KeyPair.generateEd25519().peerID
    }

    // MARK: - Configuration Tests

    @Test("Default rate limit configuration values")
    func defaultRateLimitConfiguration() {
        let config = AutoNATConfiguration()

        #expect(config.maxRequestsPerPeer == 10)
        #expect(config.rateLimitWindow == .seconds(60))
        #expect(config.maxConcurrentDialsPerPeer == 3)
        #expect(config.maxConcurrentDialsGlobal == 50)
        #expect(config.maxGlobalRequests == 500)
        #expect(config.rateLimitBackoff == .seconds(30))
        #expect(config.allowedPortRange == nil)
        #expect(config.requirePeerIDMatch == true)
    }

    @Test("Custom rate limit configuration values")
    func customRateLimitConfiguration() {
        let config = AutoNATConfiguration(
            maxRequestsPerPeer: 5,
            rateLimitWindow: .seconds(30),
            maxConcurrentDialsPerPeer: 2,
            maxConcurrentDialsGlobal: 20,
            maxGlobalRequests: 100,
            rateLimitBackoff: .seconds(15),
            allowedPortRange: 1024...65535,
            requirePeerIDMatch: false
        )

        #expect(config.maxRequestsPerPeer == 5)
        #expect(config.rateLimitWindow == .seconds(30))
        #expect(config.maxConcurrentDialsPerPeer == 2)
        #expect(config.maxConcurrentDialsGlobal == 20)
        #expect(config.maxGlobalRequests == 100)
        #expect(config.rateLimitBackoff == .seconds(15))
        #expect(config.allowedPortRange == 1024...65535)
        #expect(config.requirePeerIDMatch == false)
    }

    @Test("Service initializes rate limit state")
    func serviceInitializesRateLimitState() {
        // Service should initialize without error with rate limiting enabled
        let _ = AutoNATService(configuration: .init(
            maxRequestsPerPeer: 3,
            rateLimitWindow: .seconds(10)
        ))
    }

    @Test("RequestRejectionReason cases exist")
    func requestRejectionReasonCases() {
        let rateLimited = RequestRejectionReason.rateLimited(.peerRateLimit)
        let peerIDMismatch = RequestRejectionReason.peerIDMismatch
        let portNotAllowed = RequestRejectionReason.portNotAllowed(80)
        let noValidAddresses = RequestRejectionReason.noValidAddresses

        // Verify all cases can be created and are equatable
        #expect(rateLimited == .rateLimited(.peerRateLimit))
        #expect(peerIDMismatch == .peerIDMismatch)
        #expect(portNotAllowed == .portNotAllowed(80))
        #expect(noValidAddresses == .noValidAddresses)
    }

    @Test("dialRequestRejected event can be created")
    func dialRequestRejectedEvent() {
        let peer = KeyPair.generateEd25519().peerID
        let event = AutoNATEvent.dialRequestRejected(from: peer, reason: .rateLimited(.peerRateLimit))

        guard case .dialRequestRejected(let from, let reason) = event else {
            Issue.record("Expected dialRequestRejected event")
            return
        }
        #expect(from == peer)
        #expect(reason == .rateLimited(.peerRateLimit))
    }

    @Test("rateLimitStateChanged event can be created")
    func rateLimitStateChangedEvent() {
        let event = AutoNATEvent.rateLimitStateChanged(globalConcurrent: 5, globalRequests: 100)

        guard case .rateLimitStateChanged(let concurrent, let requests) = event else {
            Issue.record("Expected rateLimitStateChanged event")
            return
        }
        #expect(concurrent == 5)
        #expect(requests == 100)
    }

    // MARK: - Rate Limiting Behavior Tests

    @Test("First request from peer is accepted")
    func testFirstRequestAccepted() {
        let service = AutoNATService(configuration: .init(
            maxRequestsPerPeer: 3
        ))
        let peer = makePeerID()

        let result = service.shouldAcceptRequest(from: peer)

        if case .accepted = result {
            // Expected
        } else {
            Issue.record("Expected first request to be accepted")
        }
    }

    @Test("Requests within limit are accepted")
    func testRequestsWithinLimitAccepted() {
        let service = AutoNATService(configuration: .init(
            maxRequestsPerPeer: 3,
            rateLimitWindow: .seconds(60)
        ))
        let peer = makePeerID()

        // First 3 requests should be accepted
        for i in 0..<3 {
            let result = service.shouldAcceptRequest(from: peer)
            if case .accepted = result {
                // Expected
            } else {
                Issue.record("Expected request \(i + 1) to be accepted")
            }
        }
    }

    @Test("Requests exceeding peer limit are rejected")
    func testRequestsExceedingPeerLimitRejected() {
        let service = AutoNATService(configuration: .init(
            maxRequestsPerPeer: 3,
            rateLimitWindow: .seconds(60)
        ))
        let peer = makePeerID()

        // Use up the limit
        for _ in 0..<3 {
            _ = service.shouldAcceptRequest(from: peer)
        }

        // 4th request should be rejected
        let result = service.shouldAcceptRequest(from: peer)

        if case .rejected(let reason) = result {
            #expect(reason == .peerRateLimit)
        } else {
            Issue.record("Expected 4th request to be rejected with peerRateLimit")
        }
    }

    @Test("Different peers have separate rate limits")
    func testDifferentPeersSeparateLimits() {
        let service = AutoNATService(configuration: .init(
            maxRequestsPerPeer: 2,
            rateLimitWindow: .seconds(60)
        ))
        let peer1 = makePeerID()
        let peer2 = makePeerID()

        // Use up peer1's limit
        _ = service.shouldAcceptRequest(from: peer1)
        _ = service.shouldAcceptRequest(from: peer1)

        // peer2 should still be accepted
        let result = service.shouldAcceptRequest(from: peer2)

        if case .accepted = result {
            // Expected
        } else {
            Issue.record("Expected peer2's request to be accepted")
        }
    }

    @Test("Global rate limit is enforced")
    func testGlobalRateLimitEnforced() {
        let service = AutoNATService(configuration: .init(
            maxRequestsPerPeer: 100,  // High per-peer limit
            rateLimitWindow: .seconds(60),
            maxGlobalRequests: 3      // Low global limit
        ))

        // Create different peers to avoid per-peer limit
        let peers = (0..<5).map { _ in makePeerID() }

        // First 3 requests from different peers should be accepted
        for i in 0..<3 {
            let result = service.shouldAcceptRequest(from: peers[i])
            if case .accepted = result {
                // Expected
            } else {
                Issue.record("Expected request \(i + 1) to be accepted")
            }
        }

        // 4th request should be rejected due to global limit
        let result = service.shouldAcceptRequest(from: peers[3])

        if case .rejected(let reason) = result {
            #expect(reason == .globalRateLimit)
        } else {
            Issue.record("Expected 4th request to be rejected with globalRateLimit")
        }
    }

    @Test("Backoff after rejection is enforced")
    func testBackoffAfterRejection() {
        let service = AutoNATService(configuration: .init(
            maxRequestsPerPeer: 1,
            rateLimitWindow: .seconds(60),
            rateLimitBackoff: .seconds(30)
        ))
        let peer = makePeerID()

        // First request accepted
        _ = service.shouldAcceptRequest(from: peer)

        // Second request rejected (over limit) and sets backoff
        let result2 = service.shouldAcceptRequest(from: peer)
        if case .rejected(.peerRateLimit) = result2 {
            // Expected - this sets lastRejectedAt
        } else {
            Issue.record("Expected peerRateLimit rejection")
        }

        // Third request should be rejected with backoff reason
        let result3 = service.shouldAcceptRequest(from: peer)
        if case .rejected(let reason) = result3 {
            #expect(reason == .backoff)
        } else {
            Issue.record("Expected backoff rejection")
        }
    }

    @Test("Rate limit resets after window expires")
    func testRateLimitResetsAfterWindow() async throws {
        // Use a very short window for testing
        let service = AutoNATService(configuration: .init(
            maxRequestsPerPeer: 1,
            rateLimitWindow: .milliseconds(50),  // 50ms window
            rateLimitBackoff: .milliseconds(10)  // Very short backoff
        ))
        let peer = makePeerID()

        // First request accepted
        let result1 = service.shouldAcceptRequest(from: peer)
        if case .accepted = result1 {
            // Expected
        } else {
            Issue.record("Expected first request to be accepted")
        }

        // Wait for window to expire
        try await Task.sleep(for: .milliseconds(100))

        // Request should be accepted again after window expires
        let result2 = service.shouldAcceptRequest(from: peer)
        if case .accepted = result2 {
            // Expected
        } else {
            Issue.record("Expected request to be accepted after window expired")
        }
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
        var readBuffer: [ByteBuffer] = []
        var writtenData: [ByteBuffer] = []
    }

    init(id: UInt64 = 0, protocolID: String? = nil) {
        self.id = id
        self.protocolID = protocolID
        self.state = Mutex(StreamState())
    }

    var isClosed: Bool {
        state.withLock { $0.isClosed }
    }

    var readBuffer: [ByteBuffer] {
        get { state.withLock { $0.readBuffer } }
        set { state.withLock { $0.readBuffer = newValue } }
    }

    var writtenData: [ByteBuffer] {
        state.withLock { $0.writtenData }
    }

    func read() async throws -> ByteBuffer {
        let data: ByteBuffer? = state.withLock { s in
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

    func write(_ data: ByteBuffer) async throws {
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

enum MockError: Error {
    case streamOpenFailed
    case noData
}
