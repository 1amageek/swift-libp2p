/// Tests for WebRTCMuxedStream
///
/// Verifies the continuation double-resume fix, deliver/read pipeline,
/// and close behavior.

import Testing
import Foundation
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
        #expect(String(data: data, encoding: .utf8) == "hello")
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
        #expect(String(data: data, encoding: .utf8) == "delayed")
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

        #expect(d1 == Data([0x01]))
        #expect(d2 == Data([0x02]))
        #expect(d3 == Data([0x03]))
    }

    @Test("write throws when write-closed", .timeLimit(.minutes(1)))
    func writeThrowsWhenWriteClosed() async throws {
        let stream = try createTestStream()

        try await stream.closeWrite()

        await #expect(throws: WebRTCStreamError.self) {
            try await stream.write(Data("test".utf8))
        }
    }
}
