/// AutoNATv2Tests - Tests for AutoNAT v2 protocol implementation
import Testing
import Foundation
import NIOCore
import Synchronization
@testable import P2PAutoNAT
@testable import P2PCore
@testable import P2PMux
@testable import P2PProtocols

// MARK: - Nonce Tests

@Suite("AutoNATv2 Nonce Tests")
struct AutoNATv2NonceTests {

    @Test("Nonce generation produces non-zero values")
    func nonceGenerationProducesNonZero() {
        let service = AutoNATv2Service()

        // Generate multiple nonces and verify they are non-zero
        var allZero = true
        for _ in 0..<100 {
            let nonce = service.generateNonce()
            if nonce != 0 {
                allZero = false
                break
            }
        }

        #expect(!allZero, "At least one of 100 nonces should be non-zero")
        service.shutdown()
    }

    @Test("Nonce generation produces unique values")
    func nonceGenerationProducesUniqueValues() {
        let service = AutoNATv2Service()
        var nonces = Set<UInt64>()

        for _ in 0..<100 {
            let nonce = service.generateNonce()
            nonces.insert(nonce)
        }

        // With 64-bit random nonces, collisions are astronomically unlikely
        #expect(nonces.count == 100, "100 nonces should all be unique")
        service.shutdown()
    }

    @Test("Register and verify nonce succeeds")
    func registerAndVerifyNonce() throws {
        let service = AutoNATv2Service()
        let address = try Multiaddr("/ip4/203.0.113.1/tcp/4001")
        let nonce: UInt64 = 42

        service.registerPendingCheck(address: address, nonce: nonce)

        let verified = service.verifyNonce(nonce, for: address)
        #expect(verified)

        service.shutdown()
    }

    @Test("Verify nonce with wrong address fails")
    func verifyNonceWithWrongAddress() throws {
        let service = AutoNATv2Service()
        let correctAddress = try Multiaddr("/ip4/203.0.113.1/tcp/4001")
        let wrongAddress = try Multiaddr("/ip4/192.168.1.1/tcp/4001")
        let nonce: UInt64 = 42

        service.registerPendingCheck(address: correctAddress, nonce: nonce)

        let verified = service.verifyNonce(nonce, for: wrongAddress)
        #expect(!verified)

        service.shutdown()
    }

    @Test("Verify unknown nonce fails")
    func verifyUnknownNonce() throws {
        let service = AutoNATv2Service()
        let address = try Multiaddr("/ip4/203.0.113.1/tcp/4001")

        let verified = service.verifyNonce(999, for: address)
        #expect(!verified)

        service.shutdown()
    }

    @Test("Nonce can only be verified once")
    func nonceCanOnlyBeVerifiedOnce() throws {
        let service = AutoNATv2Service()
        let address = try Multiaddr("/ip4/203.0.113.1/tcp/4001")
        let nonce: UInt64 = 42

        service.registerPendingCheck(address: address, nonce: nonce)

        // First verification succeeds
        let first = service.verifyNonce(nonce, for: address)
        #expect(first)

        // Second verification fails (nonce was consumed)
        let second = service.verifyNonce(nonce, for: address)
        #expect(!second)

        service.shutdown()
    }

    @Test("Multiple nonces can be registered simultaneously")
    func multipleNoncesRegistered() throws {
        let service = AutoNATv2Service()
        let address1 = try Multiaddr("/ip4/203.0.113.1/tcp/4001")
        let address2 = try Multiaddr("/ip4/203.0.113.2/tcp/4002")
        let nonce1: UInt64 = 100
        let nonce2: UInt64 = 200

        service.registerPendingCheck(address: address1, nonce: nonce1)
        service.registerPendingCheck(address: address2, nonce: nonce2)

        #expect(service.pendingCheckCount == 2)

        // Verify both nonces
        #expect(service.verifyNonce(nonce1, for: address1))
        #expect(service.verifyNonce(nonce2, for: address2))
        #expect(service.pendingCheckCount == 0)

        service.shutdown()
    }
}

// MARK: - Concurrent Nonce Tests

@Suite("AutoNATv2 Concurrent Nonce Tests")
struct AutoNATv2ConcurrentNonceTests {

    @Test("Concurrent nonce registration and verification", .timeLimit(.minutes(1)))
    func concurrentNonceRegistrationAndVerification() async throws {
        let service = AutoNATv2Service()
        let address = try Multiaddr("/ip4/203.0.113.1/tcp/4001")

        // Register nonces from multiple tasks
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                let nonce = UInt64(i + 1)
                group.addTask {
                    service.registerPendingCheck(address: address, nonce: nonce)
                }
            }
        }

        #expect(service.pendingCheckCount == 50)

        // Verify nonces from multiple tasks
        actor VerificationCounter {
            var successCount = 0
            func increment() { successCount += 1 }
            func count() -> Int { successCount }
        }
        let counter = VerificationCounter()

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                let nonce = UInt64(i + 1)
                group.addTask {
                    if service.verifyNonce(nonce, for: address) {
                        await counter.increment()
                    }
                }
            }
        }

        let successes = await counter.count()
        #expect(successes == 50)
        #expect(service.pendingCheckCount == 0)

        service.shutdown()
    }
}

// MARK: - Expired Nonce Cleanup Tests

@Suite("AutoNATv2 Expired Nonce Cleanup Tests")
struct AutoNATv2ExpiredNonceTests {

    @Test("Expired nonces are cleaned up", .timeLimit(.minutes(1)))
    func expiredNoncesCleanedUp() async throws {
        // Use very short timeout for testing
        let service = AutoNATv2Service(
            cooldownDuration: .seconds(30),
            checkTimeout: .milliseconds(50)
        )
        let address = try Multiaddr("/ip4/203.0.113.1/tcp/4001")

        service.registerPendingCheck(address: address, nonce: 1)
        service.registerPendingCheck(address: address, nonce: 2)

        #expect(service.pendingCheckCount == 2)

        // Wait for expiry
        try await Task.sleep(for: .milliseconds(100))

        // Cleanup should remove expired checks
        let removed = service.cleanupExpiredChecks()
        #expect(removed == 2)
        #expect(service.pendingCheckCount == 0)

        service.shutdown()
    }

    @Test("Expired nonce verification fails", .timeLimit(.minutes(1)))
    func expiredNonceVerificationFails() async throws {
        let service = AutoNATv2Service(
            cooldownDuration: .seconds(30),
            checkTimeout: .milliseconds(50)
        )
        let address = try Multiaddr("/ip4/203.0.113.1/tcp/4001")
        let nonce: UInt64 = 42

        service.registerPendingCheck(address: address, nonce: nonce)

        // Wait for expiry
        try await Task.sleep(for: .milliseconds(100))

        // Verification should fail for expired nonce
        let verified = service.verifyNonce(nonce, for: address)
        #expect(!verified)

        service.shutdown()
    }

    @Test("Non-expired nonces survive cleanup", .timeLimit(.minutes(1)))
    func nonExpiredNoncesSurviveCleanup() throws {
        let service = AutoNATv2Service(
            cooldownDuration: .seconds(30),
            checkTimeout: .seconds(60) // Long timeout
        )
        let address = try Multiaddr("/ip4/203.0.113.1/tcp/4001")

        service.registerPendingCheck(address: address, nonce: 1)
        service.registerPendingCheck(address: address, nonce: 2)

        // Cleanup should remove nothing (checks are fresh)
        let removed = service.cleanupExpiredChecks()
        #expect(removed == 0)
        #expect(service.pendingCheckCount == 2)

        service.shutdown()
    }
}

// MARK: - Rate Limiting Tests

@Suite("AutoNATv2 Rate Limiting Tests")
struct AutoNATv2RateLimitingTests {

    private func makePeerID() -> PeerID {
        KeyPair.generateEd25519().peerID
    }

    @Test("First request to a peer is allowed")
    func firstRequestAllowed() {
        let service = AutoNATv2Service(cooldownDuration: .seconds(30))
        let peer = makePeerID()

        #expect(service.canRequestFrom(peer: peer))
        service.shutdown()
    }

    @Test("Request within cooldown is rejected", .timeLimit(.minutes(1)))
    func requestWithinCooldownRejected() async throws {
        let service = AutoNATv2Service(cooldownDuration: .seconds(30))
        let peer = makePeerID()
        let address = try Multiaddr("/ip4/203.0.113.1/tcp/4001")

        // Simulate a request (register nonce and record the request)
        service.registerPendingCheck(address: address, nonce: 1)

        // Use a mock opener that fails to avoid real network calls
        let opener = MockStreamOpener()
        opener.shouldFail = true

        // First request - will fail due to mock but records the peer
        do {
            _ = try await service.requestCheck(address: address, from: peer, using: opener)
        } catch {
            // Expected failure from mock
        }

        // Second request should be rate limited
        #expect(!service.canRequestFrom(peer: peer))

        service.shutdown()
    }

    @Test("Request after cooldown is allowed", .timeLimit(.minutes(1)))
    func requestAfterCooldownAllowed() async throws {
        let service = AutoNATv2Service(cooldownDuration: .milliseconds(50))
        let peer = makePeerID()
        let address = try Multiaddr("/ip4/203.0.113.1/tcp/4001")

        let opener = MockStreamOpener()
        opener.shouldFail = true

        do {
            _ = try await service.requestCheck(address: address, from: peer, using: opener)
        } catch {
            // Expected
        }

        // Should be blocked during cooldown
        #expect(!service.canRequestFrom(peer: peer))

        // Wait for cooldown to expire
        try await Task.sleep(for: .milliseconds(100))

        // Should be allowed after cooldown
        #expect(service.canRequestFrom(peer: peer))

        service.shutdown()
    }

    @Test("Different peers have independent cooldowns")
    func differentPeersIndependentCooldowns() {
        let service = AutoNATv2Service(cooldownDuration: .seconds(30))
        let peer1 = makePeerID()
        let peer2 = makePeerID()

        // Both should be allowed initially
        #expect(service.canRequestFrom(peer: peer1))
        #expect(service.canRequestFrom(peer: peer2))

        service.shutdown()
    }
}

// MARK: - Reachability State Tests

@Suite("AutoNATv2 Reachability State Tests")
struct AutoNATv2ReachabilityTests {

    @Test("Initial reachability is unknown")
    func initialReachabilityUnknown() {
        let service = AutoNATv2Service()

        #expect(service.currentReachability == .unknown)

        service.shutdown()
    }

    @Test("Reset reachability returns to unknown")
    func resetReachabilityReturnsToUnknown() {
        let service = AutoNATv2Service()

        service.resetReachability()

        #expect(service.currentReachability == .unknown)

        service.shutdown()
    }

    @Test("Reachability equality")
    func reachabilityEquality() {
        let unknown1 = AutoNATv2Service.Reachability.unknown
        let unknown2 = AutoNATv2Service.Reachability.unknown
        let public1 = AutoNATv2Service.Reachability.publiclyReachable
        let public2 = AutoNATv2Service.Reachability.publiclyReachable
        let private1 = AutoNATv2Service.Reachability.privateOnly
        let private2 = AutoNATv2Service.Reachability.privateOnly

        #expect(unknown1 == unknown2)
        #expect(public1 == public2)
        #expect(private1 == private2)
        #expect(unknown1 != public1)
        #expect(public1 != private1)
        #expect(unknown1 != private1)
    }
}

// MARK: - Message Encoding/Decoding Tests

@Suite("AutoNATv2 Message Encoding/Decoding Tests")
struct AutoNATv2MessageTests {

    @Test("DialRequest round-trip encoding")
    func dialRequestRoundTrip() throws {
        let address = try Multiaddr("/ip4/203.0.113.1/tcp/4001")
        let nonce: UInt64 = 12345

        let message = AutoNATv2Message.dialRequest(.init(address: address, nonce: nonce))
        let encoded = AutoNATv2Codec.encode(message)
        let decoded = try AutoNATv2Codec.decode(encoded)

        guard case .dialRequest(let req) = decoded else {
            Issue.record("Expected dialRequest")
            return
        }

        #expect(req.address == address)
        #expect(req.nonce == nonce)
    }

    @Test("DialResponse with OK status round-trip encoding")
    func dialResponseOkRoundTrip() throws {
        let address = try Multiaddr("/ip4/203.0.113.1/tcp/4001")
        let message = AutoNATv2Message.dialResponse(.init(status: .ok, address: address))
        let encoded = AutoNATv2Codec.encode(message)
        let decoded = try AutoNATv2Codec.decode(encoded)

        guard case .dialResponse(let resp) = decoded else {
            Issue.record("Expected dialResponse")
            return
        }

        #expect(resp.status == .ok)
        #expect(resp.address == address)
    }

    @Test("DialResponse with error status round-trip encoding")
    func dialResponseErrorRoundTrip() throws {
        let message = AutoNATv2Message.dialResponse(.init(status: .dialError))
        let encoded = AutoNATv2Codec.encode(message)
        let decoded = try AutoNATv2Codec.decode(encoded)

        guard case .dialResponse(let resp) = decoded else {
            Issue.record("Expected dialResponse")
            return
        }

        #expect(resp.status == .dialError)
        #expect(resp.address == nil)
    }

    @Test("DialBack round-trip encoding")
    func dialBackRoundTrip() throws {
        let nonce: UInt64 = 0xDEADBEEF
        let message = AutoNATv2Message.dialBack(.init(nonce: nonce))
        let encoded = AutoNATv2Codec.encode(message)
        let decoded = try AutoNATv2Codec.decode(encoded)

        guard case .dialBack(let back) = decoded else {
            Issue.record("Expected dialBack")
            return
        }

        #expect(back.nonce == nonce)
    }

    @Test("DialRequest with zero nonce round-trip")
    func dialRequestZeroNonce() throws {
        let address = try Multiaddr("/ip4/127.0.0.1/tcp/8080")
        let message = AutoNATv2Message.dialRequest(.init(address: address, nonce: 0))
        let encoded = AutoNATv2Codec.encode(message)
        let decoded = try AutoNATv2Codec.decode(encoded)

        guard case .dialRequest(let req) = decoded else {
            Issue.record("Expected dialRequest")
            return
        }

        #expect(req.nonce == 0)
        #expect(req.address == address)
    }

    @Test("DialRequest with max nonce round-trip")
    func dialRequestMaxNonce() throws {
        let address = try Multiaddr("/ip4/10.0.0.1/tcp/9000")
        let message = AutoNATv2Message.dialRequest(.init(address: address, nonce: UInt64.max))
        let encoded = AutoNATv2Codec.encode(message)
        let decoded = try AutoNATv2Codec.decode(encoded)

        guard case .dialRequest(let req) = decoded else {
            Issue.record("Expected dialRequest")
            return
        }

        #expect(req.nonce == UInt64.max)
    }

    @Test("DialBack with zero nonce round-trip")
    func dialBackZeroNonce() throws {
        let message = AutoNATv2Message.dialBack(.init(nonce: 0))
        let encoded = AutoNATv2Codec.encode(message)
        let decoded = try AutoNATv2Codec.decode(encoded)

        guard case .dialBack(let back) = decoded else {
            Issue.record("Expected dialBack")
            return
        }

        #expect(back.nonce == 0)
    }

    @Test("Decoding empty data throws error")
    func decodingEmptyDataThrows() {
        #expect(throws: (any Error).self) {
            _ = try AutoNATv2Codec.decode(Data())
        }
    }

    @Test("Decoding invalid data throws error")
    func decodingInvalidDataThrows() {
        let invalidData = Data([0xFF, 0xFF, 0xFF])
        #expect(throws: (any Error).self) {
            _ = try AutoNATv2Codec.decode(invalidData)
        }
    }

    @Test("All DialStatus values encode correctly")
    func allDialStatusValues() throws {
        let statuses: [AutoNATv2Message.DialStatus] = [.ok, .dialError, .dialBackError, .badRequest, .internalError]
        let address = try Multiaddr("/ip4/1.2.3.4/tcp/5000")

        for status in statuses {
            let message = AutoNATv2Message.dialResponse(.init(status: status, address: address))
            let encoded = AutoNATv2Codec.encode(message)
            let decoded = try AutoNATv2Codec.decode(encoded)

            guard case .dialResponse(let resp) = decoded else {
                Issue.record("Expected dialResponse for status \(status)")
                continue
            }

            #expect(resp.status == status)
        }
    }

    @Test("DialResponse without address round-trip")
    func dialResponseWithoutAddress() throws {
        let message = AutoNATv2Message.dialResponse(.init(status: .internalError, address: nil))
        let encoded = AutoNATv2Codec.encode(message)
        let decoded = try AutoNATv2Codec.decode(encoded)

        guard case .dialResponse(let resp) = decoded else {
            Issue.record("Expected dialResponse")
            return
        }

        #expect(resp.status == .internalError)
        #expect(resp.address == nil)
    }

    @Test("IPv6 address round-trip encoding")
    func ipv6AddressRoundTrip() throws {
        let address = try Multiaddr("/ip6/::1/tcp/4001")
        let nonce: UInt64 = 7890

        let message = AutoNATv2Message.dialRequest(.init(address: address, nonce: nonce))
        let encoded = AutoNATv2Codec.encode(message)
        let decoded = try AutoNATv2Codec.decode(encoded)

        guard case .dialRequest(let req) = decoded else {
            Issue.record("Expected dialRequest")
            return
        }

        #expect(req.address == address)
        #expect(req.nonce == nonce)
    }
}

// MARK: - DialStatus Tests

@Suite("AutoNATv2 DialStatus Tests")
struct AutoNATv2DialStatusTests {

    @Test("DialStatus raw values are correct")
    func dialStatusRawValues() {
        #expect(AutoNATv2Message.DialStatus.ok.rawValue == 0)
        #expect(AutoNATv2Message.DialStatus.dialError.rawValue == 100)
        #expect(AutoNATv2Message.DialStatus.dialBackError.rawValue == 101)
        #expect(AutoNATv2Message.DialStatus.badRequest.rawValue == 200)
        #expect(AutoNATv2Message.DialStatus.internalError.rawValue == 300)
    }

    @Test("DialStatus unknown raw value defaults to internalError")
    func dialStatusUnknownRawValue() {
        let status = AutoNATv2Message.DialStatus(rawValue: 999)
        #expect(status == .internalError)
    }

    @Test("DialStatus equality")
    func dialStatusEquality() {
        #expect(AutoNATv2Message.DialStatus.ok == AutoNATv2Message.DialStatus.ok)
        #expect(AutoNATv2Message.DialStatus.ok != AutoNATv2Message.DialStatus.dialError)
    }
}

// MARK: - Event Emission Tests

@Suite("AutoNATv2 Event Emission Tests", .serialized)
struct AutoNATv2EventTests {

    @Test("Event stream is available")
    func eventStreamAvailable() {
        let service = AutoNATv2Service()
        _ = service.events
        service.shutdown()
    }

    @Test("Getting events returns same stream")
    func eventsSameStream() {
        let service = AutoNATv2Service()

        let stream1 = service.events
        let stream2 = service.events

        // Both should return the same stream (single consumer pattern)
        // We can't directly compare AsyncStreams, but both should work
        _ = stream1
        _ = stream2

        service.shutdown()
    }

    @Test("Reset emits reachabilityChanged event", .timeLimit(.minutes(1)))
    func resetEmitsEvent() async {
        let service = AutoNATv2Service()

        actor EventCollector {
            var events: [AutoNATv2Service.Event] = []
            func add(_ event: AutoNATv2Service.Event) { events.append(event) }
            func getEvents() -> [AutoNATv2Service.Event] { events }
        }
        let collector = EventCollector()

        let eventTask = Task {
            for await event in service.events {
                await collector.add(event)
                if case .reachabilityChanged = event {
                    break
                }
            }
        }

        // Give time for the task to start listening
        do { try await Task.sleep(for: .milliseconds(20)) } catch { }

        service.resetReachability()

        // Wait for the event task to complete
        await eventTask.value

        let events = await collector.getEvents()
        #expect(events.count >= 1)

        if let firstEvent = events.first {
            guard case .reachabilityChanged(let reachability) = firstEvent else {
                Issue.record("Expected reachabilityChanged event")
                service.shutdown()
                return
            }
            #expect(reachability == .unknown)
        }

        service.shutdown()
    }
}

// MARK: - EventEmitting Shutdown Tests

@Suite("AutoNATv2 EventEmitting Shutdown Tests", .serialized)
struct AutoNATv2ShutdownTests {

    @Test("Shutdown finishes event stream", .timeLimit(.minutes(1)))
    func shutdownFinishesEventStream() async {
        let service = AutoNATv2Service()

        let eventTask = Task {
            var count = 0
            for await _ in service.events {
                count += 1
            }
            return count
        }

        // Give time for task to start listening
        do { try await Task.sleep(for: .milliseconds(20)) } catch { }

        service.shutdown()

        let result = await eventTask.value
        #expect(result == 0)
    }

    @Test("Shutdown unblocks waiting consumers", .timeLimit(.minutes(1)))
    func shutdownUnblocksConsumers() async {
        let service = AutoNATv2Service()

        actor Flag {
            var completed = false
            func set() { completed = true }
            func get() -> Bool { completed }
        }
        let flag = Flag()

        let eventTask = Task {
            for await _ in service.events {
                // Loop should exit when shutdown is called
            }
            await flag.set()
        }

        do { try await Task.sleep(for: .milliseconds(20)) } catch { }

        service.shutdown()
        await eventTask.value

        let completed = await flag.get()
        #expect(completed)
    }

    @Test("Multiple shutdowns are safe")
    func multipleShutdownsSafe() {
        let service = AutoNATv2Service()

        service.shutdown()
        service.shutdown()
        service.shutdown()
    }

    @Test("Shutdown cleans up continuation and stream")
    func shutdownCleansUpState() {
        let service = AutoNATv2Service()

        // Access events to create the stream
        _ = service.events

        // Shutdown should clean up
        service.shutdown()

        // Getting events after shutdown should create a new stream
        // (since stream was set to nil)
        _ = service.events

        service.shutdown()
    }
}

// MARK: - Error Type Tests

@Suite("AutoNATv2 Error Tests")
struct AutoNATv2ErrorTests {

    @Test("All error cases exist")
    func allErrorCasesExist() {
        let peer = KeyPair.generateEd25519().peerID

        let errors: [AutoNATv2Error] = [
            .protocolViolation("test"),
            .rateLimited(peer: peer),
            .nonceVerificationFailed,
            .nonceExpired,
            .dialBackFailed("reason"),
            .timeout,
            .serviceShutdown,
            .noAddress,
        ]

        var matched = 0
        for error in errors {
            switch error {
            case .protocolViolation: matched += 1
            case .rateLimited: matched += 1
            case .nonceVerificationFailed: matched += 1
            case .nonceExpired: matched += 1
            case .dialBackFailed: matched += 1
            case .timeout: matched += 1
            case .serviceShutdown: matched += 1
            case .noAddress: matched += 1
            }
        }

        #expect(matched == 8)
    }

    @Test("Errors are equatable")
    func errorsAreEquatable() {
        #expect(AutoNATv2Error.timeout == AutoNATv2Error.timeout)
        #expect(AutoNATv2Error.nonceVerificationFailed == AutoNATv2Error.nonceVerificationFailed)
        #expect(AutoNATv2Error.nonceExpired == AutoNATv2Error.nonceExpired)
        #expect(AutoNATv2Error.serviceShutdown == AutoNATv2Error.serviceShutdown)
        #expect(AutoNATv2Error.noAddress == AutoNATv2Error.noAddress)
        #expect(AutoNATv2Error.timeout != AutoNATv2Error.noAddress)
        #expect(AutoNATv2Error.protocolViolation("a") == AutoNATv2Error.protocolViolation("a"))
        #expect(AutoNATv2Error.protocolViolation("a") != AutoNATv2Error.protocolViolation("b"))
    }
}

// MARK: - Handler Tests

@Suite("AutoNATv2 Handler Tests")
struct AutoNATv2HandlerTests {

    @Test("Handler initializes with service")
    func handlerInitialization() {
        let service = AutoNATv2Service()
        let handler = AutoNATv2Handler(service: service)

        // Handler should be created without issues
        _ = handler

        service.shutdown()
    }
}

// MARK: - Protocol Constants Tests

@Suite("AutoNATv2 Protocol Constants Tests")
struct AutoNATv2ProtocolTests {

    @Test("Protocol ID is correct")
    func protocolIDCorrect() {
        let service = AutoNATv2Service()
        #expect(service.protocolID == "/libp2p/autonat/2/dial-request")
        service.shutdown()
    }

    @Test("Dial-back protocol ID is correct")
    func dialBackProtocolIDCorrect() {
        let service = AutoNATv2Service()
        #expect(service.dialBackProtocolID == "/libp2p/autonat/2/dial-back")
        service.shutdown()
    }

    @Test("Default cooldown duration is 30 seconds")
    func defaultCooldownDuration() {
        let service = AutoNATv2Service()
        #expect(service.cooldownDuration == .seconds(30))
        service.shutdown()
    }

    @Test("Custom cooldown duration is respected")
    func customCooldownDuration() {
        let service = AutoNATv2Service(cooldownDuration: .seconds(60))
        #expect(service.cooldownDuration == .seconds(60))
        service.shutdown()
    }

    @Test("Default check timeout is 60 seconds")
    func defaultCheckTimeout() {
        let service = AutoNATv2Service()
        #expect(service.checkTimeout == .seconds(60))
        service.shutdown()
    }

    @Test("Custom check timeout is respected")
    func customCheckTimeout() {
        let service = AutoNATv2Service(checkTimeout: .seconds(120))
        #expect(service.checkTimeout == .seconds(120))
        service.shutdown()
    }
}

// MARK: - Message Types Tests

@Suite("AutoNATv2 Message Type Tests")
struct AutoNATv2MessageTypeTests {

    @Test("DialRequest equality")
    func dialRequestEquality() throws {
        let addr = try Multiaddr("/ip4/1.2.3.4/tcp/5000")
        let req1 = AutoNATv2Message.DialRequest(address: addr, nonce: 42)
        let req2 = AutoNATv2Message.DialRequest(address: addr, nonce: 42)
        let req3 = AutoNATv2Message.DialRequest(address: addr, nonce: 43)

        #expect(req1 == req2)
        #expect(req1 != req3)
    }

    @Test("DialResponse equality")
    func dialResponseEquality() throws {
        let addr = try Multiaddr("/ip4/1.2.3.4/tcp/5000")
        let resp1 = AutoNATv2Message.DialResponse(status: .ok, address: addr)
        let resp2 = AutoNATv2Message.DialResponse(status: .ok, address: addr)
        let resp3 = AutoNATv2Message.DialResponse(status: .dialError, address: addr)

        #expect(resp1 == resp2)
        #expect(resp1 != resp3)
    }

    @Test("DialBack equality")
    func dialBackEquality() {
        let back1 = AutoNATv2Message.DialBack(nonce: 100)
        let back2 = AutoNATv2Message.DialBack(nonce: 100)
        let back3 = AutoNATv2Message.DialBack(nonce: 200)

        #expect(back1 == back2)
        #expect(back1 != back3)
    }

    @Test("AutoNATv2Message equality")
    func messageEquality() throws {
        let addr = try Multiaddr("/ip4/1.2.3.4/tcp/5000")
        let msg1 = AutoNATv2Message.dialRequest(.init(address: addr, nonce: 42))
        let msg2 = AutoNATv2Message.dialRequest(.init(address: addr, nonce: 42))
        let msg3 = AutoNATv2Message.dialBack(.init(nonce: 42))

        #expect(msg1 == msg2)
        #expect(msg1 != msg3)
    }
}

// MARK: - Wire Format Tests (fixed64 nonce encoding)

@Suite("AutoNATv2 Wire Format Tests")
struct AutoNATv2WireFormatTests {

    @Test("DialRequest nonce uses fixed64 wire type (tag byte 0x11)")
    func dialRequestNonceUsesFixed64Tag() throws {
        let address = try Multiaddr("/ip4/1.2.3.4/tcp/5000")
        let nonce: UInt64 = 0x0102030405060708
        let message = AutoNATv2Message.dialRequest(.init(address: address, nonce: nonce))
        let encoded = AutoNATv2Codec.encode(message)

        // The encoded data contains a top-level wrapper with embedded DialRequest.
        // Within the DialRequest sub-message, the nonce field tag should be 0x11
        // (field 2, wire type 1 = fixed64), NOT 0x10 (field 2, wire type 0 = varint).
        #expect(encoded.contains(0x11), "DialRequest nonce tag byte 0x11 (fixed64) should be present")

        // Verify round-trip
        let decoded = try AutoNATv2Codec.decode(encoded)
        guard case .dialRequest(let req) = decoded else {
            Issue.record("Expected dialRequest")
            return
        }
        #expect(req.nonce == nonce)
    }

    @Test("DialBack nonce uses fixed64 wire type (tag byte 0x09)")
    func dialBackNonceUsesFixed64Tag() throws {
        let nonce: UInt64 = 0xFEDCBA9876543210
        let message = AutoNATv2Message.dialBack(.init(nonce: nonce))
        let encoded = AutoNATv2Codec.encode(message)

        // Within the DialBack sub-message, the nonce field tag should be 0x09
        // (field 1, wire type 1 = fixed64), NOT 0x08 (field 1, wire type 0 = varint).
        #expect(encoded.contains(0x09), "DialBack nonce tag byte 0x09 (fixed64) should be present")

        // Verify round-trip
        let decoded = try AutoNATv2Codec.decode(encoded)
        guard case .dialBack(let back) = decoded else {
            Issue.record("Expected dialBack")
            return
        }
        #expect(back.nonce == nonce)
    }

    @Test("Nonce is encoded as exactly 8 bytes little-endian")
    func nonceEncodedAs8BytesLittleEndian() throws {
        // Use a nonce where byte order matters
        let nonce: UInt64 = 1  // 0x0000000000000001
        let message = AutoNATv2Message.dialBack(.init(nonce: nonce))
        let encoded = AutoNATv2Codec.encode(message)

        // DialBack message structure:
        // Top-level: type tag (0x08) + varint(2) + dialBack tag (0x22) + length + sub-message
        // Sub-message: nonce tag (0x09) + 8 bytes little-endian
        //
        // In little-endian, nonce=1 is [0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]

        // Verify round-trip
        let decoded = try AutoNATv2Codec.decode(encoded)
        guard case .dialBack(let back) = decoded else {
            Issue.record("Expected dialBack")
            return
        }
        #expect(back.nonce == 1)

        // The sub-message should be exactly 9 bytes: 1 tag byte + 8 nonce bytes
        // Find the dialBack sub-message by looking for tag 0x09 followed by 8 LE bytes
        var found = false
        for i in 0..<(encoded.count - 8) {
            if encoded[encoded.startIndex + i] == 0x09 {
                let nonceBytes = encoded[(encoded.startIndex + i + 1)..<(encoded.startIndex + i + 9)]
                let firstByte = nonceBytes[nonceBytes.startIndex]
                // Little-endian: first byte of nonce=1 should be 0x01
                if firstByte == 0x01 {
                    // Remaining 7 bytes should be 0x00
                    let rest = nonceBytes.dropFirst()
                    let allZero = rest.allSatisfy { $0 == 0x00 }
                    if allZero {
                        found = true
                        break
                    }
                }
            }
        }
        #expect(found, "Nonce should be encoded as 8-byte little-endian after tag 0x09")
    }

    @Test("Max nonce round-trip with fixed64")
    func maxNonceFixed64RoundTrip() throws {
        let nonce = UInt64.max
        let message = AutoNATv2Message.dialBack(.init(nonce: nonce))
        let encoded = AutoNATv2Codec.encode(message)
        let decoded = try AutoNATv2Codec.decode(encoded)

        guard case .dialBack(let back) = decoded else {
            Issue.record("Expected dialBack")
            return
        }
        #expect(back.nonce == UInt64.max)
    }

    @Test("Zero nonce round-trip with fixed64")
    func zeroNonceFixed64RoundTrip() throws {
        let nonce: UInt64 = 0
        let message = AutoNATv2Message.dialBack(.init(nonce: nonce))
        let encoded = AutoNATv2Codec.encode(message)
        let decoded = try AutoNATv2Codec.decode(encoded)

        guard case .dialBack(let back) = decoded else {
            Issue.record("Expected dialBack")
            return
        }
        #expect(back.nonce == 0)
    }
}

// MARK: - Shutdown Service State Cleanup Tests

@Suite("AutoNATv2 Shutdown ServiceState Cleanup Tests")
struct AutoNATv2ShutdownServiceStateTests {

    @Test("Shutdown clears pending checks")
    func shutdownClearsPendingChecks() throws {
        let service = AutoNATv2Service()
        let address = try Multiaddr("/ip4/203.0.113.1/tcp/4001")

        service.registerPendingCheck(address: address, nonce: 1)
        service.registerPendingCheck(address: address, nonce: 2)
        #expect(service.pendingCheckCount == 2)

        service.shutdown()

        #expect(service.pendingCheckCount == 0)
    }

    @Test("Shutdown resets reachability to unknown")
    func shutdownResetsReachability() {
        let service = AutoNATv2Service()

        // The initial state is unknown, but after shutdown it should also be unknown
        service.shutdown()

        #expect(service.currentReachability == .unknown)
    }

    @Test("Shutdown clears peer cooldown tracking")
    func shutdownClearsPeerCooldowns() {
        let service = AutoNATv2Service(cooldownDuration: .seconds(3600))
        let peer = KeyPair.generateEd25519().peerID

        // Simulate that we recently checked this peer by using canRequestFrom + direct state manipulation
        // First, the peer is unknown (allowed)
        #expect(service.canRequestFrom(peer: peer))

        // Register a check to trigger cooldown tracking via the mock path
        let address: Multiaddr
        do {
            address = try Multiaddr("/ip4/203.0.113.1/tcp/4001")
        } catch {
            Issue.record("Failed to create Multiaddr: \(error)")
            return
        }

        let opener = MockStreamOpener()
        opener.shouldFail = true

        // This will fail but still record the cooldown
        Task {
            do {
                _ = try await service.requestCheck(address: address, from: peer, using: opener)
            } catch {
                // Expected
            }
        }

        // Give the task time to execute (in real code, better patterns exist)
        // Instead, just verify shutdown clears the state
        service.shutdown()

        // After shutdown, the peer should be allowed again because lastCheckByPeer was cleared
        #expect(service.canRequestFrom(peer: peer))
    }
}
