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

        // Inject data before read
        let messageFrame = MplexFrame.message(id: 1, isInitiator: false, data: Data("hello".utf8))
        injectFrame(mock, messageFrame)

        try await Task.sleep(for: .milliseconds(50))

        // Read should return immediately with buffered data
        let data = try await stream.read()
        #expect(String(data: data, encoding: .utf8) == "hello")

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

        // Inject data
        let messageFrame = MplexFrame.message(id: 1, isInitiator: false, data: Data("delayed".utf8))
        injectFrame(mock, messageFrame)

        let data = try await readTask.value
        #expect(String(data: data, encoding: .utf8) == "delayed")

        try await connection.close()
    }

    @Test("Multiple data frames are buffered and returned together", .timeLimit(.minutes(1)))
    func multipleDataFramesBuffered() async throws {
        let (connection, mock) = createTestConnection(isInitiator: true)
        connection.start()

        let stream = try await connection.newStream()

        // Wait for readLoop to start
        try await Task.sleep(for: .milliseconds(100))

        // Inject first data frame
        injectFrame(mock, MplexFrame.message(id: 1, isInitiator: false, data: Data("hello".utf8)))

        // Wait for processing
        try await Task.sleep(for: .milliseconds(100))

        // Inject second data frame
        injectFrame(mock, MplexFrame.message(id: 1, isInitiator: false, data: Data("world".utf8)))

        // Wait for processing
        try await Task.sleep(for: .milliseconds(100))

        // Read returns buffered data
        let data = try await stream.read()
        let str = String(data: data, encoding: .utf8)
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

        // Inject Close from remote
        let closeFrame = MplexFrame.close(id: 1, isInitiator: false)
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

        try await stream.write(Data("test data".utf8))

        try await Task.sleep(for: .milliseconds(50))

        let outbound = mock.captureOutbound()
        let hasMessage = outbound.contains { data in
            guard let (frame, _) = try? MplexFrame.decode(from: data) else { return false }
            return frame.flag == .messageInitiator &&
                   frame.streamID == 1 &&
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
            try await stream.write(Data("test".utf8))
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
            try await stream.write(Data("test".utf8))
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
            return frame.flag == .closeInitiator && frame.streamID == 1
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
            return frame.flag == .closeInitiator && frame.streamID == 1
        }.count
        #expect(closeCount == 1)

        try await connection.close()
    }

    @Test("closeRead discards buffered data", .timeLimit(.minutes(1)))
    func closeReadDiscardsBufferedData() async throws {
        let (connection, mock) = createTestConnection(isInitiator: true)
        connection.start()

        let stream = try await connection.newStream()

        // Buffer some data
        let messageFrame = MplexFrame.message(id: 1, isInitiator: false, data: Data("buffered".utf8))
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

        // Read should still work when data arrives
        let messageFrame = MplexFrame.message(id: 1, isInitiator: false, data: Data("can still read".utf8))
        injectFrame(mock, messageFrame)

        try await Task.sleep(for: .milliseconds(50))

        let data = try await stream.read()
        #expect(String(data: data, encoding: .utf8) == "can still read")

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
            return frame.flag == .resetInitiator && frame.streamID == 1
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

        // Inject Reset from remote
        let resetFrame = MplexFrame.reset(id: 1, isInitiator: false)
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

        #expect(stream1.id == 1)
        #expect(stream2.id == 3)

        try await connection.close()
    }

    @Test("Protocol ID set and get")
    func protocolIDSetAndGet() async throws {
        let (connection, mock) = createTestConnection(isInitiator: true)
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
}
