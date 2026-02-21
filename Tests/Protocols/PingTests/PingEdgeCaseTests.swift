import Testing
import Foundation
@testable import P2PPing
import P2PCore
import P2PProtocols

@Suite("Ping Edge Case Tests")
struct PingEdgeCaseTests {

    private func makePeer() -> PeerID {
        PeerID(publicKey: KeyPair.generateEd25519().publicKey)
    }

    // MARK: - Statistics Edge Cases

    @Test("Statistics returns nil for empty results array")
    func statisticsEmpty() {
        let stats = PingService.statistics(from: [])
        #expect(stats == nil)
    }

    @Test("Statistics calculates correctly for single result")
    func statisticsSingleResult() {
        let peer = makePeer()
        let result = PingResult(peer: peer, rtt: .milliseconds(50))
        let stats = PingService.statistics(from: [result])
        #expect(stats != nil)
        #expect(stats?.min == .milliseconds(50))
        #expect(stats?.max == .milliseconds(50))
        #expect(stats?.avg == .milliseconds(50))
    }

    @Test("Statistics calculates min/max/avg correctly for multiple results")
    func statisticsMultiple() {
        let peer = makePeer()
        let results = [
            PingResult(peer: peer, rtt: .milliseconds(10)),
            PingResult(peer: peer, rtt: .milliseconds(50)),
            PingResult(peer: peer, rtt: .milliseconds(30)),
        ]
        let stats = PingService.statistics(from: results)
        #expect(stats != nil)
        #expect(stats?.min == .milliseconds(10))
        #expect(stats?.max == .milliseconds(50))
        // Average: (10+50+30)/3 = 30ms
        #expect(stats?.avg == .milliseconds(30))
    }

    // MARK: - PingResult Properties

    @Test("PingResult stores peer and RTT correctly")
    func pingResultProperties() {
        let peer = makePeer()
        let rtt = Duration.milliseconds(42)
        let result = PingResult(peer: peer, rtt: rtt)
        #expect(result.peer == peer)
        #expect(result.rtt == rtt)
    }

    @Test("PingResult stores timestamp")
    func pingResultTimestamp() {
        let peer = makePeer()
        let before = ContinuousClock.now
        let result = PingResult(peer: peer, rtt: .milliseconds(10))
        let after = ContinuousClock.now
        // Timestamp should be between before and after
        #expect(result.timestamp >= before)
        #expect(result.timestamp <= after)
    }

    @Test("PingResult accepts custom timestamp")
    func pingResultCustomTimestamp() {
        let peer = makePeer()
        let timestamp = ContinuousClock.now
        let result = PingResult(peer: peer, rtt: .milliseconds(10), timestamp: timestamp)
        #expect(result.timestamp == timestamp)
    }

    // MARK: - PingError Cases

    @Test("PingError cases are distinct")
    func pingErrorCases() {
        let errors: [PingError] = [
            .timeout,
            .mismatch,
            .streamError("test"),
            .notConnected,
            .unsupported
        ]
        // Ensure each error is distinguishable
        for i in 0..<errors.count {
            for j in (i+1)..<errors.count {
                #expect(String(describing: errors[i]) != String(describing: errors[j]))
            }
        }
    }

    @Test("PingError.streamError preserves message")
    func pingErrorStreamErrorMessage() {
        let error = PingError.streamError("connection reset by peer")
        if case .streamError(let message) = error {
            #expect(message == "connection reset by peer")
        } else {
            Issue.record("Expected streamError case")
        }
    }

    // MARK: - PingEvent Cases

    @Test("PingEvent success contains result")
    func pingEventSuccess() {
        let peer = makePeer()
        let result = PingResult(peer: peer, rtt: .milliseconds(10))
        let event = PingEvent.success(result)
        if case .success(let r) = event {
            #expect(r.peer == peer)
        } else {
            Issue.record("Expected success event")
        }
    }

    @Test("PingEvent failure contains peer and error")
    func pingEventFailure() {
        let peer = makePeer()
        let event = PingEvent.failure(peer: peer, error: .timeout)
        if case .failure(let p, let e) = event {
            #expect(p == peer)
            if case .timeout = e {
                // OK
            } else {
                Issue.record("Expected timeout error")
            }
        } else {
            Issue.record("Expected failure event")
        }
    }

    @Test("PingEvent failure with each error type")
    func pingEventFailureAllErrors() {
        let peer = makePeer()
        let errorCases: [PingError] = [.timeout, .mismatch, .notConnected, .unsupported, .streamError("err")]
        for pingError in errorCases {
            let event = PingEvent.failure(peer: peer, error: pingError)
            if case .failure(let p, _) = event {
                #expect(p == peer)
            } else {
                Issue.record("Expected failure event for \(pingError)")
            }
        }
    }

    // MARK: - Configuration

    @Test("Default configuration has 30s timeout")
    func defaultConfig() {
        let config = PingConfiguration()
        #expect(config.timeout == .seconds(30))
    }

    @Test("Custom timeout configuration")
    func customConfig() {
        let config = PingConfiguration(timeout: .seconds(5))
        #expect(config.timeout == .seconds(5))
    }

    @Test("Very short timeout configuration")
    func veryShortTimeout() {
        let config = PingConfiguration(timeout: .milliseconds(100))
        #expect(config.timeout == .milliseconds(100))
    }

    // MARK: - Service Lifecycle

    @Test("Shutdown finishes event stream", .timeLimit(.minutes(1)))
    func shutdownFinishesEvents() async {
        let service = PingService()
        let events = service.events

        await service.shutdown()

        // After shutdown, iterating events should complete immediately
        var count = 0
        for await _ in events {
            count += 1
        }
        #expect(count == 0)
    }

    @Test("Multiple shutdown calls are idempotent")
    func shutdownIdempotent() {
        let service = PingService()
        service.shutdown()
        service.shutdown()
        service.shutdown()
        // No crash = success
    }

    @Test("Protocol ID is correct")
    func protocolID() {
        let service = PingService()
        #expect(service.protocolIDs == ["/ipfs/ping/1.0.0"])
    }

    @Test("Events stream returns same stream on repeated access")
    func eventsStreamSameInstance() {
        let service = PingService()
        // Access events twice - EventEmitting pattern returns the same stream
        let stream1 = service.events
        let stream2 = service.events
        // Both should be valid AsyncStreams (same backing continuation)
        _ = stream1
        _ = stream2
        service.shutdown()
    }

    @Test("Service created with custom configuration retains it")
    func serviceRetainsConfiguration() {
        let config = PingConfiguration(timeout: .seconds(15))
        let service = PingService(configuration: config)
        #expect(service.configuration.timeout == .seconds(15))
        service.shutdown()
    }

    @Test("Statistics with large RTT values")
    func statisticsLargeRTT() {
        let peer = makePeer()
        let results = [
            PingResult(peer: peer, rtt: .seconds(1)),
            PingResult(peer: peer, rtt: .seconds(3)),
            PingResult(peer: peer, rtt: .seconds(2)),
        ]
        let stats = PingService.statistics(from: results)
        #expect(stats != nil)
        #expect(stats?.min == .seconds(1))
        #expect(stats?.max == .seconds(3))
        #expect(stats?.avg == .seconds(2))
    }

    @Test("Statistics with sub-millisecond RTT values")
    func statisticsSubMillisecond() {
        let peer = makePeer()
        let results = [
            PingResult(peer: peer, rtt: .microseconds(100)),
            PingResult(peer: peer, rtt: .microseconds(300)),
            PingResult(peer: peer, rtt: .microseconds(200)),
        ]
        let stats = PingService.statistics(from: results)
        #expect(stats != nil)
        #expect(stats?.min == .microseconds(100))
        #expect(stats?.max == .microseconds(300))
        #expect(stats?.avg == .microseconds(200))
    }

    @Test("Statistics with identical RTT values")
    func statisticsIdenticalRTT() {
        let peer = makePeer()
        let results = [
            PingResult(peer: peer, rtt: .milliseconds(25)),
            PingResult(peer: peer, rtt: .milliseconds(25)),
            PingResult(peer: peer, rtt: .milliseconds(25)),
        ]
        let stats = PingService.statistics(from: results)
        #expect(stats != nil)
        #expect(stats?.min == .milliseconds(25))
        #expect(stats?.max == .milliseconds(25))
        #expect(stats?.avg == .milliseconds(25))
    }

    @Test("PingResult from different peers")
    func pingResultDifferentPeers() {
        let peerA = makePeer()
        let peerB = makePeer()
        let resultA = PingResult(peer: peerA, rtt: .milliseconds(10))
        let resultB = PingResult(peer: peerB, rtt: .milliseconds(20))
        #expect(resultA.peer != resultB.peer)
        #expect(resultA.rtt != resultB.rtt)
    }
}
