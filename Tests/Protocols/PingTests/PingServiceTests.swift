/// PingServiceTests - Unit tests for Ping protocol
import Testing
import Foundation
@testable import P2PPing
@testable import P2PCore
@testable import P2PProtocols

@Suite("Ping Service Tests")
struct PingServiceTests {

    @Test("PingService has correct protocol ID")
    func testProtocolID() {
        let service = PingService()
        #expect(service.protocolIDs == ["/ipfs/ping/1.0.0"])
    }

    @Test("PingConfiguration has correct defaults")
    func testDefaultConfiguration() {
        let config = PingConfiguration()
        #expect(config.timeout == .seconds(30))
    }

    @Test("PingConfiguration accepts custom timeout")
    func testCustomConfiguration() {
        let config = PingConfiguration(timeout: .seconds(10))
        #expect(config.timeout == .seconds(10))
    }

    @Test("Statistics calculates correctly for single result")
    func testStatisticsSingle() {
        let keyPair = KeyPair.generateEd25519()
        let result = PingResult(
            peer: keyPair.peerID,
            rtt: .milliseconds(50)
        )

        let stats = PingService.statistics(from: [result])

        #expect(stats != nil)
        #expect(stats?.min == .milliseconds(50))
        #expect(stats?.max == .milliseconds(50))
        #expect(stats?.avg == .milliseconds(50))
    }

    @Test("Statistics calculates correctly for multiple results")
    func testStatisticsMultiple() {
        let keyPair = KeyPair.generateEd25519()
        let results = [
            PingResult(peer: keyPair.peerID, rtt: .milliseconds(10)),
            PingResult(peer: keyPair.peerID, rtt: .milliseconds(20)),
            PingResult(peer: keyPair.peerID, rtt: .milliseconds(30)),
        ]

        let stats = PingService.statistics(from: results)

        #expect(stats != nil)
        #expect(stats?.min == .milliseconds(10))
        #expect(stats?.max == .milliseconds(30))
        #expect(stats?.avg == .milliseconds(20))
    }

    @Test("Statistics returns nil for empty results")
    func testStatisticsEmpty() {
        let stats = PingService.statistics(from: [])
        #expect(stats == nil)
    }

    @Test("PingResult stores correct values")
    func testPingResult() {
        let keyPair = KeyPair.generateEd25519()
        let rtt = Duration.milliseconds(42)
        let timestamp = ContinuousClock.now

        let result = PingResult(
            peer: keyPair.peerID,
            rtt: rtt,
            timestamp: timestamp
        )

        #expect(result.peer == keyPair.peerID)
        #expect(result.rtt == rtt)
        #expect(result.timestamp == timestamp)
    }

    @Test("Events stream is available")
    func testEventsStream() {
        let service = PingService()

        // Should be able to get the events stream
        _ = service.events

        // Getting it again should return the same stream
        _ = service.events
    }

    @Test("Shutdown terminates event stream", .timeLimit(.minutes(1)))
    func shutdownTerminatesEventStream() async throws {
        let service = PingService()

        // Get the event stream
        let events = service.events

        // Start consuming events in a task
        let consumeTask = Task {
            var count = 0
            for await _ in events {
                count += 1
            }
            return count
        }

        // Give time for the consumer to start
        do { try await Task.sleep(for: .milliseconds(50)) } catch { }

        // Shutdown should terminate the stream
        try await service.shutdown()

        // Consumer should complete without timing out
        let count = await consumeTask.value
        #expect(count == 0)  // No events were emitted
    }

    @Test("Shutdown is idempotent")
    func shutdownIsIdempotent() async throws {
        let service = PingService()

        // Multiple shutdowns should not crash
        try await service.shutdown()
        try await service.shutdown()
        try await service.shutdown()

        // Service should still report correct protocol IDs
        #expect(service.protocolIDs == ["/ipfs/ping/1.0.0"])
    }
}

@Suite("PingError Tests")
struct PingErrorTests {

    @Test("All PingError cases exist")
    func testErrorCases() {
        // Create each error type to verify they exist
        let timeout = PingError.timeout
        let mismatch = PingError.mismatch
        let streamError = PingError.streamError("test error")
        let notConnected = PingError.notConnected
        let unsupported = PingError.unsupported

        // Verify they are distinct via switch
        let errors: [PingError] = [timeout, mismatch, streamError, notConnected, unsupported]
        var matched = 0

        for error in errors {
            switch error {
            case .timeout:
                matched += 1
            case .mismatch:
                matched += 1
            case .streamError:
                matched += 1
            case .notConnected:
                matched += 1
            case .unsupported:
                matched += 1
            }
        }

        #expect(matched == 5)
    }

    @Test("PingError.streamError contains message")
    func testStreamErrorMessage() {
        let error = PingError.streamError("connection reset")

        if case .streamError(let message) = error {
            #expect(message == "connection reset")
        } else {
            Issue.record("Expected streamError case")
        }
    }
}

@Suite("PingEvent Tests")
struct PingEventTests {

    @Test("PingEvent.success contains result")
    func testSuccessEvent() {
        let keyPair = KeyPair.generateEd25519()
        let result = PingResult(peer: keyPair.peerID, rtt: .milliseconds(50))
        let event = PingEvent.success(result)

        if case .success(let r) = event {
            #expect(r.peer == keyPair.peerID)
            #expect(r.rtt == .milliseconds(50))
        } else {
            Issue.record("Expected success event")
        }
    }

    @Test("PingEvent.failure contains peer and error")
    func testFailureEvent() {
        let keyPair = KeyPair.generateEd25519()
        let event = PingEvent.failure(peer: keyPair.peerID, error: .timeout)

        if case .failure(let peer, let error) = event {
            #expect(peer == keyPair.peerID)
            if case .timeout = error {
                // Expected
            } else {
                Issue.record("Expected timeout error")
            }
        } else {
            Issue.record("Expected failure event")
        }
    }
}

@Suite("ProtocolID Ping Constants Tests")
struct ProtocolIDPingConstantsTests {

    @Test("Ping protocol ID is correct")
    func testPingProtocolID() {
        #expect(ProtocolID.ping == "/ipfs/ping/1.0.0")
    }
}

// MARK: - Inbound Handler Timeout Tests

import NIOCore
import Synchronization
import P2PMux

/// A mock stream whose read() blocks until the stream is closed, then returns
/// EOF. Used to verify the inbound handler does not block forever.
private final class PingHangingStream: MuxedStream, Sendable {
    let id: UInt64 = 1
    let protocolID: String? = ProtocolID.ping

    private let state: Mutex<State>
    private struct State: Sendable {
        var closed = false
        var closeCount = 0
        var continuation: CheckedContinuation<ByteBuffer, any Error>?
    }
    init() { self.state = Mutex(State()) }

    var wasClosed: Bool { state.withLock { $0.closed } }

    func read() async throws -> ByteBuffer {
        // Block until closed; on close return EOF.
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ByteBuffer, any Error>) in
                let alreadyClosed = state.withLock { s -> Bool in
                    if s.closed { return true }
                    s.continuation = cont
                    return false
                }
                if alreadyClosed { cont.resume(returning: ByteBuffer()) }
            }
        } onCancel: {
            let cont = state.withLock { s -> CheckedContinuation<ByteBuffer, any Error>? in
                let c = s.continuation; s.continuation = nil; return c
            }
            cont?.resume(returning: ByteBuffer())
        }
    }
    func write(_ data: ByteBuffer) async throws {}
    func closeWrite() async throws {}
    func closeRead() async throws {}
    func close() async throws {
        let cont = state.withLock { s -> CheckedContinuation<ByteBuffer, any Error>? in
            s.closed = true
            s.closeCount += 1
            let c = s.continuation; s.continuation = nil; return c
        }
        cont?.resume(returning: ByteBuffer())
    }
    func reset() async throws { try await close() }
}

@Suite("Ping Inbound Handler Timeout", .serialized)
struct PingInboundTimeoutTests {

    @Test("Inbound echo handler times out when no payload arrives", .timeLimit(.minutes(1)))
    func inboundHandlerTimesOut() async throws {
        // Short idle timeout so the handler returns quickly.
        let service = PingService(configuration: .init(
            inboundIdleTimeout: .milliseconds(100),
            inboundTotalTimeout: .seconds(5)
        ))
        let stream = PingHangingStream()
        let context = StreamContext(
            stream: stream,
            remotePeer: KeyPair.generateEd25519().peerID,
            remoteAddress: Multiaddr.tcp(host: "127.0.0.1", port: 4001),
            localPeer: KeyPair.generateEd25519().peerID,
            localAddress: nil,
            protocolID: ProtocolID.ping
        )

        let start = ContinuousClock.now
        // The handler must RETURN on its own due to the idle timeout.
        await service.handleInboundStream(context)
        let elapsed = ContinuousClock.now - start

        #expect(elapsed < .seconds(3), "Handler must return promptly via idle timeout, took \(elapsed)")
        #expect(stream.wasClosed, "Handler must close the stream on timeout")

        try await service.shutdown()
    }
}
