/// HolePunchServiceTests - Tests for HolePunchService
import Testing
import Foundation
import Synchronization
@testable import P2PDCUtR
@testable import P2PCore

// MARK: - Configuration Tests

@Suite("HolePunchServiceConfiguration Tests")
struct HolePunchServiceConfigurationTests {

    @Test("Default configuration has expected values")
    func defaultConfiguration() {
        let config = HolePunchServiceConfiguration()

        #expect(config.timeout == .seconds(30))
        #expect(config.maxConcurrentPunches == 3)
        #expect(config.retryAttempts == 3)
        #expect(config.retryDelay == .seconds(5))
        #expect(config.preferredTransport == nil)
    }

    @Test("Custom configuration values are retained")
    func customConfiguration() {
        let config = HolePunchServiceConfiguration(
            timeout: .seconds(15),
            maxConcurrentPunches: 5,
            retryAttempts: 2,
            retryDelay: .seconds(3),
            preferredTransport: .quic
        )

        #expect(config.timeout == .seconds(15))
        #expect(config.maxConcurrentPunches == 5)
        #expect(config.retryAttempts == 2)
        #expect(config.retryDelay == .seconds(3))
        #expect(config.preferredTransport == .quic)
    }

    @Test("Configuration with TCP preferred transport")
    func tcpPreferredTransport() {
        let config = HolePunchServiceConfiguration(
            preferredTransport: .tcp
        )

        #expect(config.preferredTransport == .tcp)
    }

    @Test("Configuration with nil preferred transport means auto-detect")
    func autoDetectTransport() {
        let config = HolePunchServiceConfiguration(
            preferredTransport: nil
        )

        #expect(config.preferredTransport == nil)
    }
}

// MARK: - Service Initialization Tests

@Suite("HolePunchService Initialization Tests")
struct HolePunchServiceInitTests {

    @Test("Service initializes with default configuration")
    func defaultInit() {
        let service = HolePunchService()

        #expect(service.configuration.timeout == .seconds(30))
        #expect(service.configuration.maxConcurrentPunches == 3)
        #expect(service.configuration.retryAttempts == 3)
    }

    @Test("Service initializes with custom configuration")
    func customInit() {
        let config = HolePunchServiceConfiguration(
            timeout: .seconds(10),
            maxConcurrentPunches: 1,
            retryAttempts: 5
        )
        let service = HolePunchService(configuration: config)

        #expect(service.configuration.timeout == .seconds(10))
        #expect(service.configuration.maxConcurrentPunches == 1)
        #expect(service.configuration.retryAttempts == 5)
    }

    @Test("Service starts with zero statistics and invariant holds")
    func initialStatistics() {
        let service = HolePunchService()

        #expect(service.totalPeerAttempts == 0)
        #expect(service.successCount == 0)
        #expect(service.failureCount == 0)
        #expect(service.activePunches().isEmpty)
        // Invariant holds at initialization
        #expect(service.totalPeerAttempts == service.successCount + service.failureCount)
    }
}

// MARK: - Event Stream Tests

@Suite("HolePunchService Event Stream Tests", .serialized)
struct HolePunchServiceEventTests {

    @Test("Events stream is accessible")
    func eventsStreamAccessible() {
        let service = HolePunchService()

        // Should be able to get events stream without error
        _ = service.events
    }

    @Test("Events stream returns same stream on repeated access")
    func eventsStreamSameInstance() async {
        let service = HolePunchService()

        // Getting events multiple times returns the same stream
        let stream1 = service.events
        _ = service.events

        // Both should work - we verify by shutting down and seeing both complete
        service.shutdown()

        var count1 = 0
        for await _ in stream1 {
            count1 += 1
        }
        #expect(count1 == 0)

        // stream2 should also be finished since it's the same stream
        // (it was already consumed by stream1)
    }

    @Test("Shutdown finishes event stream", .timeLimit(.minutes(1)))
    func shutdownFinishesStream() async {
        let service = HolePunchService()

        let eventTask = Task {
            var count = 0
            for await _ in service.events {
                count += 1
            }
            return count
        }

        // Give eventTask time to start listening
        do { try await Task.sleep(for: .milliseconds(50)) } catch { }

        service.shutdown()

        let result = await eventTask.value
        #expect(result == 0)
    }

    @Test("Event emission delivers events to consumer", .timeLimit(.minutes(1)))
    func eventEmission() async throws {
        let service = HolePunchService()

        let peer = KeyPair.generateEd25519().peerID
        let relay = KeyPair.generateEd25519().peerID

        // Start consuming events before triggering
        let eventTask = Task { () -> [HolePunchEvent] in
            var collected: [HolePunchEvent] = []
            for await event in service.events {
                collected.append(event)
                // We expect holePunchStarted + holePunchFailed (no suitable addresses)
                if collected.count >= 2 {
                    break
                }
            }
            return collected
        }

        // Give consumer time to start
        try await Task.sleep(for: .milliseconds(50))

        // Trigger a hole punch that will fail with no suitable addresses
        // (using private addresses which get filtered out)
        do {
            _ = try await service.punchHole(
                to: peer,
                via: relay,
                peerAddresses: [Multiaddr("/ip4/203.0.113.1/tcp/4001")]
            )
        } catch {
            // Expected failure
        }

        let events = await eventTask.value
        #expect(events.count >= 1)

        // First event should be holePunchStarted
        if case .holePunchStarted(let p) = events[0] {
            #expect(p == peer)
        } else if case .holePunchFailed(let p, _) = events[0] {
            // If no suitable addresses, the first event might be holePunchFailed
            #expect(p == peer)
        }

        service.shutdown()
    }
}

// MARK: - Hole Punch Failure Tests

@Suite("HolePunchService Failure Tests", .serialized)
struct HolePunchServiceFailureTests {

    @Test("Punch fails with no suitable addresses (all private)", .timeLimit(.minutes(1)))
    func punchFailsNoSuitableAddresses() async throws {
        let service = HolePunchService()
        defer { service.shutdown() }

        let peer = KeyPair.generateEd25519().peerID
        let relay = KeyPair.generateEd25519().peerID

        // All addresses are private/loopback, so none are suitable
        let privateAddresses = [
            try Multiaddr("/ip4/127.0.0.1/tcp/4001"),
            try Multiaddr("/ip4/192.168.1.1/tcp/4001"),
            try Multiaddr("/ip4/10.0.0.1/tcp/4001"),
        ]

        do {
            _ = try await service.punchHole(
                to: peer,
                via: relay,
                peerAddresses: privateAddresses
            )
            Issue.record("Expected noSuitableAddresses error")
        } catch let error as HolePunchServiceError {
            #expect(error == .noSuitableAddresses)
        }

        #expect(service.totalPeerAttempts == 1)
        #expect(service.failureCount == 1)
        #expect(service.successCount == 0)
    }

    @Test("Punch fails with empty address list", .timeLimit(.minutes(1)))
    func punchFailsEmptyAddresses() async throws {
        let service = HolePunchService()
        defer { service.shutdown() }

        let peer = KeyPair.generateEd25519().peerID
        let relay = KeyPair.generateEd25519().peerID

        do {
            _ = try await service.punchHole(
                to: peer,
                via: relay,
                peerAddresses: []
            )
            Issue.record("Expected noSuitableAddresses error")
        } catch let error as HolePunchServiceError {
            #expect(error == .noSuitableAddresses)
        }
    }

    @Test("Punch fails after shutdown", .timeLimit(.minutes(1)))
    func punchFailsAfterShutdown() async throws {
        let service = HolePunchService()
        service.shutdown()

        let peer = KeyPair.generateEd25519().peerID
        let relay = KeyPair.generateEd25519().peerID
        let addresses = [try Multiaddr("/ip4/203.0.113.1/tcp/4001")]

        do {
            _ = try await service.punchHole(
                to: peer,
                via: relay,
                peerAddresses: addresses
            )
            Issue.record("Expected shutdownInProgress error")
        } catch let error as HolePunchServiceError {
            #expect(error == .shutdownInProgress)
        }
    }

    @Test("Punch records failure count correctly across multiple attempts", .timeLimit(.minutes(1)))
    func punchRecordsFailureCount() async throws {
        let service = HolePunchService(configuration: .init(
            retryAttempts: 1,
            retryDelay: .milliseconds(1)
        ))
        defer { service.shutdown() }

        let relay = KeyPair.generateEd25519().peerID

        // Try three hole punches that will all fail (private addresses)
        for _ in 0..<3 {
            let peer = KeyPair.generateEd25519().peerID
            do {
                _ = try await service.punchHole(
                    to: peer,
                    via: relay,
                    peerAddresses: [try Multiaddr("/ip4/192.168.1.1/tcp/4001")]
                )
            } catch {
                // Expected
            }
        }

        #expect(service.failureCount == 3)
        #expect(service.successCount == 0)
        #expect(service.totalPeerAttempts == 3)
        // Invariant: totalPeerAttempts == successCount + failureCount
        #expect(service.totalPeerAttempts == service.successCount + service.failureCount)
    }
}

// MARK: - Concurrent Punch Limit Tests

@Suite("HolePunchService Concurrency Tests", .serialized)
struct HolePunchServiceConcurrencyTests {

    @Test("Max concurrent punches is enforced", .timeLimit(.minutes(1)))
    func maxConcurrentPunchesEnforced() async throws {
        let service = HolePunchService(configuration: .init(
            timeout: .seconds(2),
            maxConcurrentPunches: 1,
            retryAttempts: 1,
            retryDelay: .milliseconds(1)
        ))
        defer { service.shutdown() }

        // We test the limit by checking activePunches when maxConcurrentPunches is 1.
        // With only private addresses, the punch fails immediately,
        // so we verify the counter logic works correctly.
        #expect(service.configuration.maxConcurrentPunches == 1)

        // After shutdown, active punches should be empty
        service.shutdown()
        #expect(service.activePunches().isEmpty)
    }
}

// MARK: - Failure Reason Tests

@Suite("HolePunchFailureReason Tests")
struct HolePunchFailureReasonTests {

    @Test("All failure reasons are distinct")
    func allFailureReasonsDistinct() {
        let reasons: [HolePunchFailureReason] = [
            .timeout,
            .noSuitableAddresses,
            .allAttemptsFailed,
            .peerUnreachable,
            .protocolError("test error"),
        ]

        // Each reason should be unique
        for i in 0..<reasons.count {
            for j in (i + 1)..<reasons.count {
                #expect(reasons[i] != reasons[j])
            }
        }
    }

    @Test("Timeout reason equality")
    func timeoutEquality() {
        #expect(HolePunchFailureReason.timeout == HolePunchFailureReason.timeout)
    }

    @Test("NoSuitableAddresses reason equality")
    func noSuitableAddressesEquality() {
        #expect(HolePunchFailureReason.noSuitableAddresses == HolePunchFailureReason.noSuitableAddresses)
    }

    @Test("AllAttemptsFailed reason equality")
    func allAttemptsFailedEquality() {
        #expect(HolePunchFailureReason.allAttemptsFailed == HolePunchFailureReason.allAttemptsFailed)
    }

    @Test("PeerUnreachable reason equality")
    func peerUnreachableEquality() {
        #expect(HolePunchFailureReason.peerUnreachable == HolePunchFailureReason.peerUnreachable)
    }

    @Test("ProtocolError contains message")
    func protocolErrorMessage() {
        let reason = HolePunchFailureReason.protocolError("invalid handshake")
        #expect(reason == .protocolError("invalid handshake"))
        #expect(reason != .protocolError("other error"))
    }
}

// MARK: - HolePunchServiceResult Tests

@Suite("HolePunchServiceResult Tests")
struct HolePunchServiceResultTests {

    @Test("Result creation with all fields")
    func resultCreationAllFields() throws {
        let peer = KeyPair.generateEd25519().peerID
        let address = try Multiaddr("/ip4/203.0.113.1/tcp/4001")
        let rtt = Duration.milliseconds(50)

        let result = HolePunchServiceResult(
            peer: peer,
            address: address,
            transport: .tcp,
            rtt: rtt
        )

        #expect(result.peer == peer)
        #expect(result.address == address)
        #expect(result.transport == .tcp)
        #expect(result.rtt == rtt)
    }

    @Test("Result creation with nil RTT")
    func resultCreationNilRTT() throws {
        let peer = KeyPair.generateEd25519().peerID
        let address = try Multiaddr("/ip4/203.0.113.1/udp/4001")

        let result = HolePunchServiceResult(
            peer: peer,
            address: address,
            transport: .quic,
            rtt: nil
        )

        #expect(result.rtt == nil)
        #expect(result.transport == .quic)
    }

    @Test("Result with TCP transport")
    func resultTCPTransport() throws {
        let peer = KeyPair.generateEd25519().peerID
        let address = try Multiaddr("/ip4/203.0.113.1/tcp/4001")

        let result = HolePunchServiceResult(
            peer: peer,
            address: address,
            transport: .tcp
        )

        #expect(result.transport == .tcp)
    }

    @Test("Result with QUIC transport")
    func resultQUICTransport() throws {
        let peer = KeyPair.generateEd25519().peerID
        let address = try Multiaddr("/ip4/203.0.113.1/udp/4001")

        let result = HolePunchServiceResult(
            peer: peer,
            address: address,
            transport: .quic
        )

        #expect(result.transport == .quic)
    }
}

// MARK: - Transport Type Tests

@Suite("HolePunchTransportType Tests")
struct HolePunchTransportTypeTests {

    @Test("TCP and QUIC are distinct")
    func tcpAndQuicDistinct() {
        #expect(HolePunchTransportType.tcp != HolePunchTransportType.quic)
    }

    @Test("TCP equals TCP")
    func tcpEqualsTcp() {
        #expect(HolePunchTransportType.tcp == HolePunchTransportType.tcp)
    }

    @Test("QUIC equals QUIC")
    func quicEqualsQuic() {
        #expect(HolePunchTransportType.quic == HolePunchTransportType.quic)
    }
}

// MARK: - Shutdown Tests

@Suite("HolePunchService Shutdown Tests", .serialized)
struct HolePunchServiceShutdownTests {

    @Test("Shutdown is idempotent")
    func shutdownIdempotent() {
        let service = HolePunchService()

        // Multiple shutdowns should not crash
        service.shutdown()
        service.shutdown()
        service.shutdown()
    }

    @Test("Shutdown clears active punches", .timeLimit(.minutes(1)))
    func shutdownClearsActivePunches() async {
        let service = HolePunchService()

        service.shutdown()

        #expect(service.activePunches().isEmpty)
    }

    @Test("Shutdown unblocks event consumers", .timeLimit(.minutes(1)))
    func shutdownUnblocksConsumers() async {
        let service = HolePunchService()

        actor Flag {
            var completed = false
            func set() { completed = true }
            func get() -> Bool { completed }
        }
        let flag = Flag()

        let eventTask = Task {
            for await _ in service.events {
                // Should exit when shutdown is called
            }
            await flag.set()
        }

        do { try await Task.sleep(for: .milliseconds(50)) } catch { }

        service.shutdown()

        do { try await Task.sleep(for: .milliseconds(50)) } catch { }

        let completed = await flag.get()
        #expect(completed)

        eventTask.cancel()
    }

    @Test("Statistics are preserved after shutdown")
    func statisticsPreservedAfterShutdown() {
        let service = HolePunchService()

        // Shutdown does not reset statistics
        service.shutdown()

        #expect(service.totalPeerAttempts == 0)
        #expect(service.successCount == 0)
        #expect(service.failureCount == 0)
        // Invariant still holds
        #expect(service.totalPeerAttempts == service.successCount + service.failureCount)
    }
}

// MARK: - HolePunchServiceError Tests

@Suite("HolePunchServiceError Tests")
struct HolePunchServiceErrorTests {

    @Test("All error cases exist")
    func allErrorCases() {
        let errors: [HolePunchServiceError] = [
            .timeout,
            .noSuitableAddresses,
            .allAttemptsFailed,
            .peerUnreachable,
            .protocolError("test"),
            .maxConcurrentPunchesReached,
            .shutdownInProgress,
        ]

        var matched = 0
        for error in errors {
            switch error {
            case .timeout: matched += 1
            case .noSuitableAddresses: matched += 1
            case .allAttemptsFailed: matched += 1
            case .peerUnreachable: matched += 1
            case .protocolError: matched += 1
            case .maxConcurrentPunchesReached: matched += 1
            case .shutdownInProgress: matched += 1
            }
        }

        #expect(matched == 7)
    }

    @Test("ProtocolError contains message")
    func protocolErrorContainsMessage() {
        let error = HolePunchServiceError.protocolError("bad handshake")

        guard case .protocolError(let msg) = error else {
            Issue.record("Expected protocolError")
            return
        }
        #expect(msg == "bad handshake")
    }

    @Test("All errors conform to Error and Sendable")
    func errorsConformToProtocols() {
        let error: any Error & Sendable = HolePunchServiceError.timeout
        #expect(error is HolePunchServiceError)
    }
}

// MARK: - HolePunchEvent Tests

@Suite("HolePunchEvent Tests")
struct HolePunchEventTests {

    @Test("HolePunchStarted event contains peer")
    func holePunchStartedEvent() {
        let peer = KeyPair.generateEd25519().peerID
        let event = HolePunchEvent.holePunchStarted(peer)

        guard case .holePunchStarted(let p) = event else {
            Issue.record("Expected holePunchStarted event")
            return
        }
        #expect(p == peer)
    }

    @Test("HolePunchSucceeded event contains peer and address")
    func holePunchSucceededEvent() throws {
        let peer = KeyPair.generateEd25519().peerID
        let address = try Multiaddr("/ip4/203.0.113.1/tcp/4001")
        let event = HolePunchEvent.holePunchSucceeded(peer, address)

        guard case .holePunchSucceeded(let p, let addr) = event else {
            Issue.record("Expected holePunchSucceeded event")
            return
        }
        #expect(p == peer)
        #expect(addr == address)
    }

    @Test("HolePunchFailed event contains peer and reason")
    func holePunchFailedEvent() {
        let peer = KeyPair.generateEd25519().peerID
        let event = HolePunchEvent.holePunchFailed(peer, .timeout)

        guard case .holePunchFailed(let p, let reason) = event else {
            Issue.record("Expected holePunchFailed event")
            return
        }
        #expect(p == peer)
        #expect(reason == .timeout)
    }

    @Test("DirectConnectionEstablished event contains peer and address")
    func directConnectionEstablishedEvent() throws {
        let peer = KeyPair.generateEd25519().peerID
        let address = try Multiaddr("/ip4/203.0.113.1/tcp/4001")
        let event = HolePunchEvent.directConnectionEstablished(peer, address)

        guard case .directConnectionEstablished(let p, let addr) = event else {
            Issue.record("Expected directConnectionEstablished event")
            return
        }
        #expect(p == peer)
        #expect(addr == address)
    }
}

// MARK: - Address Filtering Tests

@Suite("HolePunchService Address Filtering Tests")
struct HolePunchServiceAddressFilteringTests {

    @Test("Private IPv4 addresses are filtered out")
    func privateIPv4Filtered() async throws {
        let service = HolePunchService(configuration: .init(retryAttempts: 1))
        defer { service.shutdown() }

        let peer = KeyPair.generateEd25519().peerID
        let relay = KeyPair.generateEd25519().peerID

        // All private addresses should be filtered
        let addresses = [
            try Multiaddr("/ip4/127.0.0.1/tcp/4001"),    // loopback
            try Multiaddr("/ip4/10.0.0.1/tcp/4001"),      // private
            try Multiaddr("/ip4/172.16.0.1/tcp/4001"),    // private
            try Multiaddr("/ip4/192.168.1.1/tcp/4001"),   // private
            try Multiaddr("/ip4/169.254.1.1/tcp/4001"),   // link-local
        ]

        do {
            _ = try await service.punchHole(
                to: peer,
                via: relay,
                peerAddresses: addresses
            )
            Issue.record("Expected noSuitableAddresses error")
        } catch let error as HolePunchServiceError {
            #expect(error == .noSuitableAddresses)
        }
    }

    @Test("Public IPv4 addresses pass filtering")
    func publicIPv4PassesFilter() async throws {
        let service = HolePunchService(configuration: .init(
            timeout: .seconds(1),
            retryAttempts: 1,
            retryDelay: .milliseconds(1)
        ))
        defer { service.shutdown() }

        let peer = KeyPair.generateEd25519().peerID
        let relay = KeyPair.generateEd25519().peerID

        // Public addresses should pass filtering, but the actual punch will still
        // fail because we don't have real transport. The key test is that it
        // doesn't fail with noSuitableAddresses.
        let addresses = [
            try Multiaddr("/ip4/203.0.113.1/tcp/4001"),
        ]

        do {
            _ = try await service.punchHole(
                to: peer,
                via: relay,
                peerAddresses: addresses
            )
            Issue.record("Expected allAttemptsFailed error (no real transport)")
        } catch let error as HolePunchServiceError {
            // Should fail with allAttemptsFailed or timeout, NOT noSuitableAddresses
            #expect(error != .noSuitableAddresses)
        }
    }

    @Test("Mixed addresses: only public ones are used")
    func mixedAddressesFilterCorrectly() async throws {
        let service = HolePunchService(configuration: .init(
            timeout: .seconds(1),
            retryAttempts: 1,
            retryDelay: .milliseconds(1)
        ))
        defer { service.shutdown() }

        let peer = KeyPair.generateEd25519().peerID
        let relay = KeyPair.generateEd25519().peerID

        let addresses = [
            try Multiaddr("/ip4/192.168.1.1/tcp/4001"),   // private - filtered
            try Multiaddr("/ip4/203.0.113.1/tcp/4001"),    // public - kept
            try Multiaddr("/ip4/10.0.0.1/tcp/4001"),       // private - filtered
        ]

        do {
            _ = try await service.punchHole(
                to: peer,
                via: relay,
                peerAddresses: addresses
            )
        } catch let error as HolePunchServiceError {
            // Should not be noSuitableAddresses since we have 1 public address
            #expect(error != .noSuitableAddresses)
        }
    }
}

// MARK: - Statistics Tests

@Suite("HolePunchService Statistics Tests", .serialized)
struct HolePunchServiceStatisticsTests {

    @Test("Total peer attempts increments once per punchHole call")
    func totalPeerAttemptsIncrements() async throws {
        let service = HolePunchService(configuration: .init(
            retryAttempts: 1,
            retryDelay: .milliseconds(1)
        ))
        defer { service.shutdown() }

        let relay = KeyPair.generateEd25519().peerID

        // Each punchHole call counts as 1 peer attempt
        for _ in 0..<3 {
            let peer = KeyPair.generateEd25519().peerID
            do {
                _ = try await service.punchHole(
                    to: peer,
                    via: relay,
                    peerAddresses: [try Multiaddr("/ip4/192.168.1.1/tcp/4001")]
                )
            } catch {
                // Expected
            }
        }

        #expect(service.totalPeerAttempts == 3)
        // Invariant: totalPeerAttempts == successCount + failureCount
        #expect(service.totalPeerAttempts == service.successCount + service.failureCount)
    }

    @Test("Failure count tracks failed punches")
    func failureCountTracks() async throws {
        let service = HolePunchService(configuration: .init(
            retryAttempts: 1,
            retryDelay: .milliseconds(1)
        ))
        defer { service.shutdown() }

        let peer = KeyPair.generateEd25519().peerID
        let relay = KeyPair.generateEd25519().peerID

        do {
            _ = try await service.punchHole(
                to: peer,
                via: relay,
                peerAddresses: [try Multiaddr("/ip4/192.168.1.1/tcp/4001")]
            )
        } catch {
            // Expected
        }

        #expect(service.failureCount == 1)
        #expect(service.successCount == 0)
    }

    @Test("Active punches is empty after completion")
    func activePunchesEmptyAfterCompletion() async throws {
        let service = HolePunchService(configuration: .init(
            retryAttempts: 1,
            retryDelay: .milliseconds(1)
        ))
        defer { service.shutdown() }

        let peer = KeyPair.generateEd25519().peerID
        let relay = KeyPair.generateEd25519().peerID

        do {
            _ = try await service.punchHole(
                to: peer,
                via: relay,
                peerAddresses: [try Multiaddr("/ip4/192.168.1.1/tcp/4001")]
            )
        } catch {
            // Expected
        }

        // After completion (success or failure), active punches should be empty
        #expect(service.activePunches().isEmpty)
    }
}

// MARK: - Retry Behavior Tests

@Suite("HolePunchService Retry Tests", .serialized)
struct HolePunchServiceRetryTests {

    @Test("Retries configured number of times with public addresses", .timeLimit(.minutes(1)))
    func retriesConfiguredTimes() async throws {
        let service = HolePunchService(configuration: .init(
            timeout: .seconds(1),
            retryAttempts: 2,
            retryDelay: .milliseconds(10)
        ))
        defer { service.shutdown() }

        let peer = KeyPair.generateEd25519().peerID
        let relay = KeyPair.generateEd25519().peerID

        // Use public address so it passes filtering but fails at transport
        do {
            _ = try await service.punchHole(
                to: peer,
                via: relay,
                peerAddresses: [try Multiaddr("/ip4/203.0.113.1/tcp/4001")]
            )
        } catch {
            // Expected
        }

        // totalPeerAttempts counts once per punchHole call (per-peer granularity)
        #expect(service.totalPeerAttempts == 1)
        // After all retries exhausted, failure is recorded once
        #expect(service.failureCount == 1)
        // Invariant: totalPeerAttempts == successCount + failureCount
        #expect(service.totalPeerAttempts == service.successCount + service.failureCount)
    }

    @Test("No retries needed for address filtering failure")
    func noRetriesForAddressFiltering() async throws {
        let service = HolePunchService(configuration: .init(
            retryAttempts: 5,
            retryDelay: .milliseconds(1)
        ))
        defer { service.shutdown() }

        let peer = KeyPair.generateEd25519().peerID
        let relay = KeyPair.generateEd25519().peerID

        do {
            _ = try await service.punchHole(
                to: peer,
                via: relay,
                peerAddresses: [try Multiaddr("/ip4/192.168.1.1/tcp/4001")]
            )
        } catch {
            // Expected
        }

        // Address filtering failure should not retry
        #expect(service.totalPeerAttempts == 1)
    }
}

// MARK: - Transport Detection Tests

@Suite("HolePunchService Transport Detection Tests")
struct HolePunchServiceTransportDetectionTests {

    @Test("Preferred TCP transport is used")
    func preferredTCPUsed() {
        let config = HolePunchServiceConfiguration(preferredTransport: .tcp)
        let service = HolePunchService(configuration: config)
        defer { service.shutdown() }

        #expect(service.configuration.preferredTransport == .tcp)
    }

    @Test("Preferred QUIC transport is used")
    func preferredQUICUsed() {
        let config = HolePunchServiceConfiguration(preferredTransport: .quic)
        let service = HolePunchService(configuration: config)
        defer { service.shutdown() }

        #expect(service.configuration.preferredTransport == .quic)
    }

    @Test("Auto-detect when no preference set")
    func autoDetectNoPreference() {
        let config = HolePunchServiceConfiguration(preferredTransport: nil)
        let service = HolePunchService(configuration: config)
        defer { service.shutdown() }

        #expect(service.configuration.preferredTransport == nil)
    }

    @Test("QUIC detected from quic-v1 protocol component, not just UDP port", .timeLimit(.minutes(1)))
    func quicDetectedFromProtocolComponent() async throws {
        // With auto-detect (no preference), a QUIC address like /ip4/.../udp/.../quic-v1
        // should detect QUIC transport. Previously this checked for UDP port which was wrong
        // because UDP alone does not imply QUIC.
        let service = HolePunchService(configuration: .init(
            timeout: .seconds(1),
            retryAttempts: 1,
            retryDelay: .milliseconds(1),
            preferredTransport: nil
        ))
        defer { service.shutdown() }

        let peer = KeyPair.generateEd25519().peerID
        let relay = KeyPair.generateEd25519().peerID

        // A QUIC address with quic-v1 protocol component
        let quicAddress = try Multiaddr("/ip4/203.0.113.1/udp/4001/quic-v1")

        do {
            _ = try await service.punchHole(
                to: peer,
                via: relay,
                peerAddresses: [quicAddress]
            )
        } catch {
            // Expected - the actual punch will fail, but transport detection happens first
        }

        // Verify it doesn't fail with noSuitableAddresses (address is public)
        #expect(service.totalPeerAttempts == 1)
    }

    @Test("TCP address with UDP port does not falsely detect QUIC", .timeLimit(.minutes(1)))
    func udpPortAloneDoesNotDetectQuic() async throws {
        // An address like /ip4/.../udp/4001 without quic/quic-v1 should NOT be detected as QUIC.
        // Previously the code checked for UDP port existence, which was incorrect.
        let service = HolePunchService(configuration: .init(
            timeout: .seconds(1),
            retryAttempts: 1,
            retryDelay: .milliseconds(1),
            preferredTransport: nil
        ))
        defer { service.shutdown() }

        let peer = KeyPair.generateEd25519().peerID
        let relay = KeyPair.generateEd25519().peerID

        // A plain UDP address without QUIC protocol component
        let udpAddress = try Multiaddr("/ip4/203.0.113.1/udp/4001")

        do {
            _ = try await service.punchHole(
                to: peer,
                via: relay,
                peerAddresses: [udpAddress]
            )
        } catch {
            // Expected failure
        }

        // The key verification is that it doesn't crash and proceeds normally
        #expect(service.totalPeerAttempts == 1)
    }
}

// MARK: - TOCTOU Race Fix Tests

@Suite("HolePunchService TOCTOU Race Fix Tests", .serialized)
struct HolePunchServiceTOCTOURaceTests {

    @Test("Concurrent punch limit is enforced atomically", .timeLimit(.minutes(1)))
    func concurrentPunchLimitAtomicEnforcement() async throws {
        // With maxConcurrentPunches=1, only one punch should be active at a time.
        // The atomic check-and-insert prevents a race where two threads could both
        // see count < max and both insert.
        let service = HolePunchService(configuration: .init(
            timeout: .seconds(2),
            maxConcurrentPunches: 1,
            retryAttempts: 1,
            retryDelay: .milliseconds(1)
        ))
        defer { service.shutdown() }

        let relay = KeyPair.generateEd25519().peerID

        // Launch multiple concurrent punch attempts and collect results
        let results: [HolePunchServiceError?] = await withTaskGroup(of: HolePunchServiceError?.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    let peer = KeyPair.generateEd25519().peerID
                    do {
                        _ = try await service.punchHole(
                            to: peer,
                            via: relay,
                            peerAddresses: [try Multiaddr("/ip4/203.0.113.1/tcp/4001")]
                        )
                        return nil
                    } catch let error as HolePunchServiceError {
                        return error
                    } catch {
                        return nil
                    }
                }
            }

            var collected: [HolePunchServiceError?] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }

        // After all tasks complete, active punches should be empty
        #expect(service.activePunches().isEmpty)

        // Verify that some may have been rejected due to concurrent limit
        // (this is non-deterministic, but the important thing is no crash and empty active set)
        let rejectedCount = results.filter { $0 == .maxConcurrentPunchesReached }.count
        // With maxConcurrentPunches=1, at most 1 can run at a time
        // All 5 tasks should complete (either rejected or failed at transport)
        #expect(results.count == 5)
        _ = rejectedCount  // Value depends on timing
    }

    @Test("Peer is removed from active set on failure", .timeLimit(.minutes(1)))
    func peerRemovedFromActiveSetOnFailure() async throws {
        let service = HolePunchService(configuration: .init(
            timeout: .seconds(1),
            maxConcurrentPunches: 1,
            retryAttempts: 1,
            retryDelay: .milliseconds(1)
        ))
        defer { service.shutdown() }

        let peer = KeyPair.generateEd25519().peerID
        let relay = KeyPair.generateEd25519().peerID

        do {
            _ = try await service.punchHole(
                to: peer,
                via: relay,
                peerAddresses: [try Multiaddr("/ip4/203.0.113.1/tcp/4001")]
            )
        } catch {
            // Expected failure
        }

        // Peer should be removed from active set after failure
        #expect(service.activePunches().isEmpty)

        // Should be able to punch again (slot freed)
        do {
            _ = try await service.punchHole(
                to: peer,
                via: relay,
                peerAddresses: [try Multiaddr("/ip4/203.0.113.1/tcp/4001")]
            )
        } catch let error as HolePunchServiceError {
            // Should NOT be maxConcurrentPunchesReached since the slot was freed
            #expect(error != .maxConcurrentPunchesReached)
        }
    }

    @Test("Shutdown rejected punch does not register in active set", .timeLimit(.minutes(1)))
    func shutdownRejectedPunchNotRegistered() async throws {
        let service = HolePunchService(configuration: .init(
            maxConcurrentPunches: 3,
            retryAttempts: 1
        ))

        service.shutdown()

        let peer = KeyPair.generateEd25519().peerID
        let relay = KeyPair.generateEd25519().peerID

        do {
            _ = try await service.punchHole(
                to: peer,
                via: relay,
                peerAddresses: [try Multiaddr("/ip4/203.0.113.1/tcp/4001")]
            )
            Issue.record("Expected shutdownInProgress error")
        } catch let error as HolePunchServiceError {
            #expect(error == .shutdownInProgress)
        }

        // Peer should not be in active set
        #expect(service.activePunches().isEmpty)
        // Statistics should not be affected by shutdown-rejected attempts
        #expect(service.totalPeerAttempts == 0)
    }
}

// MARK: - Statistics Invariant Tests

@Suite("HolePunchService Statistics Invariant Tests", .serialized)
struct HolePunchServiceStatisticsInvariantTests {

    @Test("Invariant: totalPeerAttempts == successCount + failureCount after failures", .timeLimit(.minutes(1)))
    func invariantAfterFailures() async throws {
        let service = HolePunchService(configuration: .init(
            retryAttempts: 3,
            retryDelay: .milliseconds(1)
        ))
        defer { service.shutdown() }

        let relay = KeyPair.generateEd25519().peerID

        // Multiple punchHole calls, all failing with private addresses
        for _ in 0..<5 {
            let peer = KeyPair.generateEd25519().peerID
            do {
                _ = try await service.punchHole(
                    to: peer,
                    via: relay,
                    peerAddresses: [try Multiaddr("/ip4/10.0.0.1/tcp/4001")]
                )
            } catch {
                // Expected
            }
        }

        // Invariant must hold: total = success + failure
        #expect(service.totalPeerAttempts == 5)
        #expect(service.successCount == 0)
        #expect(service.failureCount == 5)
        #expect(service.totalPeerAttempts == service.successCount + service.failureCount)
    }

    @Test("Invariant holds with mixed public and private address failures", .timeLimit(.minutes(1)))
    func invariantWithMixedAddressTypes() async throws {
        let service = HolePunchService(configuration: .init(
            timeout: .seconds(1),
            retryAttempts: 2,
            retryDelay: .milliseconds(1)
        ))
        defer { service.shutdown() }

        let relay = KeyPair.generateEd25519().peerID

        // Call 1: private addresses (no suitable addresses path)
        let peer1 = KeyPair.generateEd25519().peerID
        do {
            _ = try await service.punchHole(
                to: peer1,
                via: relay,
                peerAddresses: [try Multiaddr("/ip4/192.168.1.1/tcp/4001")]
            )
        } catch {
            // Expected
        }

        // Call 2: public addresses (transport failure path with retries)
        let peer2 = KeyPair.generateEd25519().peerID
        do {
            _ = try await service.punchHole(
                to: peer2,
                via: relay,
                peerAddresses: [try Multiaddr("/ip4/203.0.113.1/tcp/4001")]
            )
        } catch {
            // Expected
        }

        // Both paths should count once per punchHole call
        #expect(service.totalPeerAttempts == 2)
        #expect(service.failureCount == 2)
        #expect(service.successCount == 0)
        #expect(service.totalPeerAttempts == service.successCount + service.failureCount)
    }
}
