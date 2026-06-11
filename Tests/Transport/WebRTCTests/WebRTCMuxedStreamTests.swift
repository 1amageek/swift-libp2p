/// Tests for WebRTCMuxedStream
///
/// Verifies the continuation double-resume fix, deliver/read pipeline,
/// and close behavior.

import Testing
import Foundation
import NIOCore
import Synchronization
@testable import P2PTransportWebRTC
@testable import P2PCore
@testable import WebRTC
@testable import DTLSCore
@testable import DataChannel

@Suite("WebRTC MuxedStream Tests")
struct WebRTCMuxedStreamTests {

    /// Helper to create a test stream.
    ///
    /// Uses a real WebRTCConnection (required by WebRTCMuxedStream init),
    /// but tests focus on `deliver()` / `closeRead()` which don't touch
    /// the connection's DTLS layer.
    private func createTestStream() throws -> WebRTCMuxedStream {
        let cert = try DTLSCertificate.generateSelfSigned()
        let connection = WebRTCConnection.asServer(
            certificate: cert,
            sendHandler: { _ in }
        )
        let channel = DataChannel(
            id: 0,
            label: "test",
            protocol: "",
            ordered: true,
            state: .open
        )
        return WebRTCMuxedStream(
            id: 0,
            channel: channel,
            connection: connection,
            protocolID: nil
        )
    }

    @Test("read returns data that was delivered first", .timeLimit(.minutes(1)))
    func readReturnsBufferedData() async throws {
        let stream = try createTestStream()

        // Deliver data before reading (buffer path)
        stream.deliver(Data("hello".utf8))

        let data = try await stream.read()
        #expect(String(buffer: data) == "hello")
    }

    @Test("read waits for deliver", .timeLimit(.minutes(1)))
    func readWaitsForDeliver() async throws {
        let stream = try createTestStream()

        // Start read before any data arrives (waiter path)
        let readTask = Task {
            try await stream.read()
        }

        try await Task.sleep(for: .milliseconds(50))

        // Now deliver data — should resume the waiting read
        stream.deliver(Data("delayed".utf8))

        let data = try await readTask.value
        #expect(String(buffer: data) == "delayed")
    }

    @Test("read throws when read-closed", .timeLimit(.minutes(1)))
    func readThrowsWhenClosed() async throws {
        let stream = try createTestStream()

        try await stream.closeRead()

        await #expect(throws: WebRTCStreamError.self) {
            _ = try await stream.read()
        }
    }

    @Test("closeRead resumes waiting readers with error", .timeLimit(.minutes(1)))
    func closeReadResumesWaiters() async throws {
        let stream = try createTestStream()

        // Start read that will wait
        let readTask = Task {
            try await stream.read()
        }

        try await Task.sleep(for: .milliseconds(50))

        // Close read — should resume with error
        try await stream.closeRead()

        await #expect(throws: WebRTCStreamError.self) {
            _ = try await readTask.value
        }
    }

    @Test("multiple delivers are read in FIFO order", .timeLimit(.minutes(1)))
    func deliverMultipleDataFIFO() async throws {
        let stream = try createTestStream()

        stream.deliver(Data([0x01]))
        stream.deliver(Data([0x02]))
        stream.deliver(Data([0x03]))

        let d1 = try await stream.read()
        let d2 = try await stream.read()
        let d3 = try await stream.read()

        #expect(Data(buffer: d1) == Data([0x01]))
        #expect(Data(buffer: d2) == Data([0x02]))
        #expect(Data(buffer: d3) == Data([0x03]))
    }

    @Test("write throws when write-closed", .timeLimit(.minutes(1)))
    func writeThrowsWhenWriteClosed() async throws {
        let stream = try createTestStream()

        try await stream.closeWrite()

        await #expect(throws: WebRTCStreamError.self) {
            try await stream.write(ByteBuffer(bytes: Data("test".utf8)))
        }
    }

    @Test("cancelled read throws CancellationError and leaves stream usable", .timeLimit(.minutes(1)))
    func readCancellation() async throws {
        let stream = try createTestStream()

        let readTask = Task {
            try await stream.read()
        }
        try await Task.sleep(for: .milliseconds(50))
        readTask.cancel()

        do {
            _ = try await readTask.value
            Issue.record("Expected CancellationError")
        } catch is CancellationError {
            // Expected
        }

        // The cancelled waiter must not disturb subsequent reads
        stream.deliver(Data("after".utf8))
        let data = try await stream.read()
        #expect(String(buffer: data) == "after")
    }

    @Test("read on already-cancelled task throws instead of hanging", .timeLimit(.minutes(1)))
    func readOnCancelledTask() async throws {
        let stream = try createTestStream()

        let readTask = Task {
            // Ensure the task observes cancellation before read() registers
            // its waiter
            while !Task.isCancelled {
                await Task.yield()
            }
            return try await stream.read()
        }
        readTask.cancel()

        do {
            _ = try await readTask.value
            Issue.record("Expected CancellationError")
        } catch is CancellationError {
            // Expected
        }
    }

    @Test("exceeding the read buffer cap fails the stream", .timeLimit(.minutes(1)))
    func readBufferOverflowFailsStream() async throws {
        let stream = try createTestStream()

        // Two 600 KiB deliveries exceed the 1 MiB cap on the second
        let chunk = Data(repeating: 0xAB, count: 600 * 1024)
        stream.deliver(chunk)
        stream.deliver(chunk)

        await #expect(throws: WebRTCStreamError.self) {
            _ = try await stream.read()
        }
        // Writes fail with the same terminal error
        await #expect(throws: WebRTCStreamError.self) {
            try await stream.write(ByteBuffer(bytes: Data("x".utf8)))
        }
    }

    @Test("fail resumes waiters, fails writes, and terminates exactly once", .timeLimit(.minutes(1)))
    func failTerminatesExactlyOnce() async throws {
        let cert = try DTLSCertificate.generateSelfSigned()
        let connection = WebRTCConnection.asServer(
            certificate: cert,
            sendHandler: { _ in }
        )
        let channel = DataChannel(
            id: 7,
            label: "test",
            protocol: "",
            ordered: true,
            state: .open
        )
        let terminations = Mutex<[(UInt64, UInt16)]>([])
        let stream = WebRTCMuxedStream(
            id: 42,
            channel: channel,
            connection: connection,
            protocolID: nil,
            onTerminate: { id, channelID in
                terminations.withLock { $0.append((id, channelID)) }
            }
        )

        let readTask = Task {
            try await stream.read()
        }
        try await Task.sleep(for: .milliseconds(50))

        struct TestFailure: Error {}
        stream.fail(TestFailure())

        await #expect(throws: TestFailure.self) {
            _ = try await readTask.value
        }
        await #expect(throws: TestFailure.self) {
            try await stream.write(ByteBuffer(bytes: Data("x".utf8)))
        }

        // close() after fail() must not re-notify
        try await stream.close()

        let recorded = terminations.withLock { $0 }
        #expect(recorded.count == 1)
        #expect(recorded.first?.0 == 42)
        #expect(recorded.first?.1 == 7)
    }
}
