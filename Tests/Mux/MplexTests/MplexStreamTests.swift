/// MplexStreamTests - Tests for MplexStream
import Foundation
import Testing
@testable import P2PCore
@testable import P2PMux
@testable import P2PMuxMplex

@Suite("MplexStream Tests", .serialized)
struct MplexStreamTests {

    // MARK: - Test Helpers

    func createTestConnection(
        isInitiator: Bool = true
    ) -> (MplexConnection, MockSecuredConnection) {
        let mock = MockSecuredConnection()
        let connection = MplexConnection(
            underlying: mock,
            localPeer: mock.localPeer,
            remotePeer: mock.remotePeer,
            isInitiator: isInitiator
        )
        return (connection, mock)
    }

    func injectFrame(_ mock: MockSecuredConnection, _ frame: MplexFrame) {
        mock.injectInbound(frame.encode())
    }

    // MARK: - Read Tests

    @Test("Read returns buffered data", .timeLimit(.minutes(1)))
    func readReturnsBufferedData() async throws {
        let (connection, mock) = createTestConnection(isInitiator: true)
        connection.start()

        let stream = try await connection.newStream()

        // Inject data before read (stream ID 0 = first locally-opened stream)
        let messageFrame = MplexFrame.message(id: 0, isInitiator: false, data: Data("hello".utf8))
        injectFrame(mock, messageFrame)

        try await Task.sleep(for: .milliseconds(50))

        // Read should return immediately with buffered data
        let data = try await stream.read()
        #expect(String(buffer: data) == "hello")

        try await connection.close()
    }

    @Test("Read waits for data", .timeLimit(.minutes(1)))
    func readWaitsForData() async throws {
        let (connection, mock) = createTestConnection(isInitiator: true)
        connection.start()

        let stream = try await connection.newStream()

        // Start read before data arrives
        let readTask = Task {
            try await stream.read()
        }

        try await Task.sleep(for: .milliseconds(50))

        // Inject data (stream ID 0 = first locally-opened stream)
        let messageFrame = MplexFrame.message(id: 0, isInitiator: false, data: Data("delayed".utf8))
        injectFrame(mock, messageFrame)

        let data = try await readTask.value
        #expect(String(buffer: data) == "delayed")

        try await connection.close()
    }

    @Test("Multiple data frames are buffered and returned together", .timeLimit(.minutes(1)))
    func multipleDataFramesBuffered() async throws {
        let (connection, mock) = createTestConnection(isInitiator: true)
        connection.start()

        let stream = try await connection.newStream()

        // Wait for readLoop to start
        try await Task.sleep(for: .milliseconds(100))

        // Inject first data frame (stream ID 0 = first locally-opened stream)
        injectFrame(mock, MplexFrame.message(id: 0, isInitiator: false, data: Data("hello".utf8)))

        // Wait for processing
        try await Task.sleep(for: .milliseconds(100))

        // Inject second data frame
        injectFrame(mock, MplexFrame.message(id: 0, isInitiator: false, data: Data("world".utf8)))

        // Wait for processing
        try await Task.sleep(for: .milliseconds(100))

        // Read returns buffered data
        let data = try await stream.read()
        let str = String(buffer: data)
        #expect(str == "helloworld")

        try await connection.close()
    }

    @Test("Read throws when reset", .timeLimit(.minutes(1)))
    func readThrowsWhenReset() async throws {
        let (connection, mock) = createTestConnection(isInitiator: true)
        connection.start()

        let stream = try await connection.newStream()

        // Reset the stream
        try await stream.reset()

        // Read should throw
        await #expect(throws: MplexError.self) {
            _ = try await stream.read()
        }

        try await connection.close()
    }

    @Test("Read throws when local read closed", .timeLimit(.minutes(1)))
    func readThrowsWhenLocalReadClosed() async throws {
        let (connection, mock) = createTestConnection(isInitiator: true)
        connection.start()

        let stream = try await connection.newStream()

        // Close read side
        try await stream.closeRead()

        // Read should throw
        await #expect(throws: MplexError.self) {
            _ = try await stream.read()
        }

        try await connection.close()
    }

    @Test("Read throws when remote write closed and buffer empty", .timeLimit(.minutes(1)))
    func readThrowsWhenRemoteWriteClosed() async throws {
        let (connection, mock) = createTestConnection(isInitiator: true)
        connection.start()

        let stream = try await connection.newStream()

        // Inject Close from remote (stream ID 0 = first locally-opened stream)
        let closeFrame = MplexFrame.close(id: 0, isInitiator: false)
        injectFrame(mock, closeFrame)

        try await Task.sleep(for: .milliseconds(50))

        // Read should throw (no data buffered)
        await #expect(throws: MplexError.self) {
            _ = try await stream.read()
        }

        try await connection.close()
    }

    // MARK: - Write Tests

    @Test("Write sends message frame")
    func writeSendsMessageFrame() async throws {
        let (connection, mock) = createTestConnection(isInitiator: true)
        connection.start()

        let stream = try await connection.newStream()
        mock.clearOutbound()

        try await stream.write(ByteBuffer(bytes: Data("test data".utf8)))

        try await Task.sleep(for: .milliseconds(50))

        let outbound = mock.captureOutbound()
        let hasMessage = outbound.contains { data in
            guard let (frame, _) = try? MplexFrame.decode(from: data) else { return false }
            return frame.flag == .messageInitiator &&
                   frame.streamID == 0 &&
                   String(data: frame.data, encoding: .utf8) == "test data"
        }
        #expect(hasMessage)

        try await connection.close()
    }

    @Test("Write throws when write closed")
    func writeThrowsWhenWriteClosed() async throws {
        let (connection, mock) = createTestConnection(isInitiator: true)
        connection.start()

        let stream = try await connection.newStream()

        // Close write side
        try await stream.closeWrite()

        // Write should throw
        await #expect(throws: MplexError.self) {
            try await stream.write(ByteBuffer(bytes: Data("test".utf8)))
        }

        try await connection.close()
    }

    @Test("Write throws when reset")
    func writeThrowsWhenReset() async throws {
        let (connection, mock) = createTestConnection(isInitiator: true)
        connection.start()

        let stream = try await connection.newStream()

        // Reset the stream
        try await stream.reset()

        // Write should throw
        await #expect(throws: MplexError.self) {
            try await stream.write(ByteBuffer(bytes: Data("test".utf8)))
        }

        try await connection.close()
    }

    // MARK: - Half-Close Tests (Mplex-specific)

    @Test("closeWrite sends Close frame")
    func closeWriteSendsCloseFrame() async throws {
        let (connection, mock) = createTestConnection(isInitiator: true)
        connection.start()

        let stream = try await connection.newStream()
        mock.clearOutbound()

        try await stream.closeWrite()

        try await Task.sleep(for: .milliseconds(50))

        let outbound = mock.captureOutbound()
        let hasClose = outbound.contains { data in
            guard let (frame, _) = try? MplexFrame.decode(from: data) else { return false }
            return frame.flag == .closeInitiator && frame.streamID == 0
        }
        #expect(hasClose)

        try await connection.close()
    }

    @Test("closeWrite is idempotent")
    func closeWriteIsIdempotent() async throws {
        let (connection, mock) = createTestConnection(isInitiator: true)
        connection.start()

        let stream = try await connection.newStream()
        mock.clearOutbound()

        // Multiple closeWrite calls
        try await stream.closeWrite()
        try await stream.closeWrite()
        try await stream.closeWrite()

        try await Task.sleep(for: .milliseconds(50))

        // Should only send one Close frame
        let outbound = mock.captureOutbound()
        let closeCount = outbound.filter { data in
            guard let (frame, _) = try? MplexFrame.decode(from: data) else { return false }
            return frame.flag == .closeInitiator && frame.streamID == 0
        }.count
        #expect(closeCount == 1)

        try await connection.close()
    }

    @Test("closeRead discards buffered data", .timeLimit(.minutes(1)))
    func closeReadDiscardsBufferedData() async throws {
        let (connection, mock) = createTestConnection(isInitiator: true)
        connection.start()

        let stream = try await connection.newStream()

        // Buffer some data (stream ID 0 = first locally-opened stream)
        let messageFrame = MplexFrame.message(id: 0, isInitiator: false, data: Data("buffered".utf8))
        injectFrame(mock, messageFrame)

        try await Task.sleep(for: .milliseconds(50))

        // Close read side (should discard buffer)
        try await stream.closeRead()

        // Read should throw (buffer was cleared)
        await #expect(throws: MplexError.self) {
            _ = try await stream.read()
        }

        try await connection.close()
    }

    @Test("Half-close allows reverse direction", .timeLimit(.minutes(1)))
    func halfCloseAllowsReverseDirection() async throws {
        let (connection, mock) = createTestConnection(isInitiator: true)
        connection.start()

        let stream = try await connection.newStream()

        // Close write side
        try await stream.closeWrite()

        // Read should still work when data arrives (stream ID 0)
        let messageFrame = MplexFrame.message(id: 0, isInitiator: false, data: Data("can still read".utf8))
        injectFrame(mock, messageFrame)

        try await Task.sleep(for: .milliseconds(50))

        let data = try await stream.read()
        #expect(String(buffer: data) == "can still read")

        try await connection.close()
    }

    // MARK: - Reset Tests

    @Test("Reset sends Reset frame")
    func resetSendsResetFrame() async throws {
        let (connection, mock) = createTestConnection(isInitiator: true)
        connection.start()

        let stream = try await connection.newStream()
        mock.clearOutbound()

        try await stream.reset()

        try await Task.sleep(for: .milliseconds(50))

        let outbound = mock.captureOutbound()
        let hasReset = outbound.contains { data in
            guard let (frame, _) = try? MplexFrame.decode(from: data) else { return false }
            return frame.flag == .resetInitiator && frame.streamID == 0
        }
        #expect(hasReset)

        try await connection.close()
    }

    @Test("Reset resumes all waiting readers", .timeLimit(.minutes(1)))
    func resetResumesAllWaitingReaders() async throws {
        let (connection, mock) = createTestConnection(isInitiator: true)
        connection.start()

        let stream = try await connection.newStream()

        // Start multiple reads
        let readTask1 = Task {
            try await stream.read()
        }
        let readTask2 = Task {
            try await stream.read()
        }

        try await Task.sleep(for: .milliseconds(50))

        // Reset stream
        try await stream.reset()

        // Both reads should fail
        await #expect(throws: MplexError.self) {
            _ = try await readTask1.value
        }
        await #expect(throws: MplexError.self) {
            _ = try await readTask2.value
        }

        try await connection.close()
    }

    @Test("Remote reset resumes all waiting readers", .timeLimit(.minutes(1)))
    func remoteResetResumesAllWaitingReaders() async throws {
        let (connection, mock) = createTestConnection(isInitiator: true)
        connection.start()

        let stream = try await connection.newStream()

        // Start multiple reads
        let readTask1 = Task {
            try await stream.read()
        }
        let readTask2 = Task {
            try await stream.read()
        }

        try await Task.sleep(for: .milliseconds(50))

        // Inject Reset from remote (stream ID 0 = first locally-opened stream)
        let resetFrame = MplexFrame.reset(id: 0, isInitiator: false)
        injectFrame(mock, resetFrame)

        // Both reads should fail
        await #expect(throws: MplexError.self) {
            _ = try await readTask1.value
        }
        await #expect(throws: MplexError.self) {
            _ = try await readTask2.value
        }

        try await connection.close()
    }

    // MARK: - State Tests

    @Test("Stream ID preserved")
    func streamIDPreserved() async throws {
        let (connection, mock) = createTestConnection(isInitiator: true)
        connection.start()

        let stream1 = try await connection.newStream()
        let stream2 = try await connection.newStream()

        #expect(stream1.id == 0)
        #expect(stream2.id == 1)

        try await connection.close()
    }

    @Test("Protocol ID set and get")
    func protocolIDSetAndGet() async throws {
        let (connection, _) = createTestConnection(isInitiator: true)
        connection.start()

        let stream = try await connection.newStream()
        guard let mplexStream = stream as? MplexStream else {
            throw TestError.unexpectedStreamType
        }

        #expect(mplexStream.protocolID == nil)

        mplexStream.protocolID = "/test/1.0.0"
        #expect(mplexStream.protocolID == "/test/1.0.0")

        try await connection.close()
    }

    // MARK: - Half-Close Advanced Tests

    @Test("Read after remote closeWrite with buffered data returns data first", .timeLimit(.minutes(1)))
    func readAfterRemoteCloseWriteWithBufferedData() async throws {
        let (connection, mock) = createTestConnection(isInitiator: true)
        connection.start()

        let stream = try await connection.newStream()

        // Buffer data first, then close from remote
        injectFrame(mock, MplexFrame.message(id: 0, isInitiator: false, data: Data("buffered-data".utf8)))

        try await Task.sleep(for: .milliseconds(50))

        // Remote closes write side
        injectFrame(mock, MplexFrame.close(id: 0, isInitiator: false))

        try await Task.sleep(for: .milliseconds(50))

        // First read should return the buffered data
        let data = try await stream.read()
        #expect(String(buffer: data) == "buffered-data")

        // Second read should fail because remote closed and buffer is empty
        await #expect(throws: MplexError.self) {
            _ = try await stream.read()
        }

        try await connection.close()
    }

    @Test("Write after remote closeRead succeeds (independent directions)", .timeLimit(.minutes(1)))
    func writeAfterRemoteCloseReadSucceeds() async throws {
        let (connection, mock) = createTestConnection(isInitiator: true)
        connection.start()

        let stream = try await connection.newStream()

        // Remote closes their write side (our read side sees remote close)
        injectFrame(mock, MplexFrame.close(id: 0, isInitiator: false))

        try await Task.sleep(for: .milliseconds(50))

        // Our write side should still work (directions are independent)
        mock.clearOutbound()
        try await stream.write(ByteBuffer(bytes: Data("still-writable".utf8)))

        try await Task.sleep(for: .milliseconds(50))

        let outbound = mock.captureOutbound()
        let hasMessage = outbound.contains { data in
            guard let (frame, _) = try? MplexFrame.decode(from: data) else { return false }
            return frame.flag == .messageInitiator && frame.streamID == 0
        }
        #expect(hasMessage)

        try await connection.close()
    }

    @Test("closeWrite then closeRead produces complete close", .timeLimit(.minutes(1)))
    func closeWriteThenCloseReadProducesCompleteClose() async throws {
        let (connection, mock) = createTestConnection(isInitiator: true)
        connection.start()

        let stream = try await connection.newStream()
        mock.clearOutbound()

        // Close write side first
        try await stream.closeWrite()

        try await Task.sleep(for: .milliseconds(50))

        // Write should fail
        await #expect(throws: MplexError.self) {
            try await stream.write(ByteBuffer(bytes: Data("fail".utf8)))
        }

        // Close read side
        try await stream.closeRead()

        // Read should fail
        await #expect(throws: MplexError.self) {
            _ = try await stream.read()
        }

        try await connection.close()
    }

    @Test("Both sides closeWrite makes stream half-closed in both directions", .timeLimit(.minutes(1)))
    func bothSidesCloseWrite() async throws {
        let (connection, mock) = createTestConnection(isInitiator: true)
        connection.start()

        let stream = try await connection.newStream()

        // Local closes write
        try await stream.closeWrite()

        // Remote closes write
        injectFrame(mock, MplexFrame.close(id: 0, isInitiator: false))

        try await Task.sleep(for: .milliseconds(50))

        // Write should fail (local write closed)
        await #expect(throws: MplexError.self) {
            try await stream.write(ByteBuffer(bytes: Data("fail".utf8)))
        }

        // Read should fail (remote write closed, no buffered data)
        await #expect(throws: MplexError.self) {
            _ = try await stream.read()
        }

        try await connection.close()
    }

    @Test("closeRead is idempotent", .timeLimit(.minutes(1)))
    func closeReadIsIdempotent() async throws {
        let (connection, _) = createTestConnection(isInitiator: true)
        connection.start()

        let stream = try await connection.newStream()

        // Multiple closeRead calls should not crash
        try await stream.closeRead()
        try await stream.closeRead()
        try await stream.closeRead()

        // Read should fail
        await #expect(throws: MplexError.self) {
            _ = try await stream.read()
        }

        // Write should still work (independent directions)
        try await stream.write(ByteBuffer(bytes: Data("ok".utf8)))

        try await connection.close()
    }

    @Test("Buffered data returned before remote close signal takes effect", .timeLimit(.minutes(1)))
    func bufferedDataReturnedBeforeRemoteCloseSignal() async throws {
        let (connection, mock) = createTestConnection(isInitiator: true)
        connection.start()

        let stream = try await connection.newStream()

        // Inject multiple data frames followed by close
        injectFrame(mock, MplexFrame.message(id: 0, isInitiator: false, data: Data("part1".utf8)))
        injectFrame(mock, MplexFrame.message(id: 0, isInitiator: false, data: Data("part2".utf8)))
        injectFrame(mock, MplexFrame.close(id: 0, isInitiator: false))

        try await Task.sleep(for: .milliseconds(100))

        // First read should return all buffered data (part1 + part2)
        let data = try await stream.read()
        let str = String(buffer: data)
        #expect(str == "part1part2")

        // Next read should fail (remote closed, buffer empty)
        await #expect(throws: MplexError.self) {
            _ = try await stream.read()
        }

        try await connection.close()
    }

    @Test("Double full close on half-closed stream is idempotent", .timeLimit(.minutes(1)))
    func doubleFullCloseOnHalfClosedStream() async throws {
        let (connection, _) = createTestConnection(isInitiator: true)
        connection.start()

        let stream = try await connection.newStream()

        // Half-close write first
        try await stream.closeWrite()

        // Full close (which includes closeWrite again + closeRead)
        try await stream.close()

        // Second full close should not crash
        try await stream.close()

        // Operations should fail gracefully
        await #expect(throws: MplexError.self) {
            _ = try await stream.read()
        }
        await #expect(throws: MplexError.self) {
            try await stream.write(ByteBuffer(bytes: Data("fail".utf8)))
        }

        try await connection.close()
    }

    @Test("Reset cancels pending reads", .timeLimit(.minutes(1)))
    func resetCancelsPendingReads() async throws {
        let (connection, _) = createTestConnection(isInitiator: true)
        connection.start()

        let stream = try await connection.newStream()

        // Start multiple pending reads
        let readTask1 = Task {
            try await stream.read()
        }
        let readTask2 = Task {
            try await stream.read()
        }
        let readTask3 = Task {
            try await stream.read()
        }

        try await Task.sleep(for: .milliseconds(50))

        // Reset should cancel all pending reads
        try await stream.reset()

        // All pending reads should throw
        await #expect(throws: MplexError.self) {
            _ = try await readTask1.value
        }
        await #expect(throws: MplexError.self) {
            _ = try await readTask2.value
        }
        await #expect(throws: MplexError.self) {
            _ = try await readTask3.value
        }

        try await connection.close()
    }
}
