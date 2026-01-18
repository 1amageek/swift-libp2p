/// YamuxStreamTests - Tests for YamuxStream flow control and state management
import Testing
import Foundation
@testable import P2PMuxYamux
@testable import P2PCore

@Suite("YamuxStream Tests")
struct YamuxStreamTests {

    // MARK: - Test Fixtures

    /// Test configuration with keep-alive disabled to avoid unexpected ping frames in tests.
    static let testConfiguration = YamuxConfiguration(enableKeepAlive: false)

    /// Creates a YamuxConnection with mock for testing streams.
    func createTestConnection(isInitiator: Bool = true) -> (YamuxConnection, MockSecuredConnection) {
        let mock = MockSecuredConnection()
        let connection = YamuxConnection(
            underlying: mock,
            localPeer: mock.localPeer,
            remotePeer: mock.remotePeer,
            isInitiator: isInitiator,
            configuration: Self.testConfiguration
        )
        return (connection, mock)
    }

    // MARK: - Read Tests

    @Test("Read returns buffered data immediately")
    func readReturnsBufferedData() async throws {
        let (connection, _) = createTestConnection()
        let stream = YamuxStream(id: 1, connection: connection)

        // Simulate data received
        let testData = Data([0x48, 0x65, 0x6C, 0x6C, 0x6F]) // "Hello"
        let accepted = stream.dataReceived(testData)
        #expect(accepted == true)

        // Read should return immediately
        let result = try await stream.read()
        #expect(result == testData)
    }

    @Test("Read waits for data when buffer is empty")
    func readWaitsForData() async throws {
        let (connection, _) = createTestConnection()
        let stream = YamuxStream(id: 1, connection: connection)

        let testData = Data([0x01, 0x02, 0x03])

        // Start read task (will wait)
        let readTask = Task {
            try await stream.read()
        }

        // Give read task time to start waiting
        try await Task.sleep(for: .milliseconds(50))

        // Inject data
        _ = stream.dataReceived(testData)

        // Read should complete
        let result = try await readTask.value
        #expect(result == testData)
    }

    @Test("Concurrent reads are queued FIFO")
    func concurrentReadsQueuedFIFO() async throws {
        let (connection, _) = createTestConnection()
        let stream = YamuxStream(id: 1, connection: connection)

        let data1 = Data([0x01])
        let data2 = Data([0x02])
        let data3 = Data([0x03])

        // Start three concurrent reads
        let readTask1 = Task { try await stream.read() }
        try await Task.sleep(for: .milliseconds(10))
        let readTask2 = Task { try await stream.read() }
        try await Task.sleep(for: .milliseconds(10))
        let readTask3 = Task { try await stream.read() }

        // Give tasks time to register
        try await Task.sleep(for: .milliseconds(50))

        // Inject data in order
        _ = stream.dataReceived(data1)
        _ = stream.dataReceived(data2)
        _ = stream.dataReceived(data3)

        // Verify FIFO order
        let result1 = try await readTask1.value
        let result2 = try await readTask2.value
        let result3 = try await readTask3.value

        #expect(result1 == data1)
        #expect(result2 == data2)
        #expect(result3 == data3)
    }

    @Test("Read throws when stream is reset")
    func readThrowsWhenReset() async throws {
        let (connection, _) = createTestConnection()
        let stream = YamuxStream(id: 1, connection: connection)

        stream.remoteReset()

        await #expect(throws: YamuxError.self) {
            _ = try await stream.read()
        }
    }

    @Test("Read throws when remote closes")
    func readThrowsWhenRemoteClosed() async throws {
        let (connection, _) = createTestConnection()
        let stream = YamuxStream(id: 1, connection: connection)

        stream.remoteClose()

        await #expect(throws: YamuxError.self) {
            _ = try await stream.read()
        }
    }

    // MARK: - Write Tests

    @Test("Write sends data when window available")
    func writeWithAvailableWindow() async throws {
        let (connection, mock) = createTestConnection()
        connection.start()
        let stream = YamuxStream(id: 1, connection: connection)

        let testData = Data([0x48, 0x65, 0x6C, 0x6C, 0x6F]) // "Hello"
        try await stream.write(testData)

        // Verify frame was sent
        let outbound = mock.captureOutbound()
        #expect(outbound.count == 1)

        // Decode the frame
        let frame = try YamuxFrame.decode(from: outbound[0])
        #expect(frame?.frame.type == .data)
        #expect(frame?.frame.streamID == 1)
        #expect(frame?.frame.data == testData)
    }

    @Test("Write throws when stream is closed")
    func writeThrowsWhenClosed() async throws {
        let (connection, _) = createTestConnection()
        let stream = YamuxStream(id: 1, connection: connection)

        try await stream.closeWrite()

        await #expect(throws: YamuxError.self) {
            try await stream.write(Data([0x01]))
        }
    }

    // MARK: - Window Management Tests

    @Test("Window update resumes all waiting writers")
    func windowUpdateResumesWaiters() async throws {
        let (connection, mock) = createTestConnection()
        connection.start()

        // Create stream with small window (100 bytes)
        let smallWindow: UInt32 = 100
        let stream = YamuxStream(id: 1, connection: connection, initialWindowSize: smallWindow)

        // Exhaust the window
        try await stream.write(Data(repeating: 0x42, count: Int(smallWindow)))
        mock.clearOutbound()

        // Start another write (will block due to no window)
        let writeTask = Task {
            try await stream.write(Data([0x01]))
        }

        // Wait for write to block
        try await Task.sleep(for: .milliseconds(100))

        // Send window update
        stream.windowUpdate(delta: 1024)

        // Write should complete
        try await writeTask.value

        // Verify data frame was sent
        let outbound = mock.captureOutbound()
        #expect(outbound.count >= 1)

        let decoded = try YamuxFrame.decode(from: outbound[0])
        #expect(decoded?.frame.data == Data([0x01]))
    }

    @Test("Window overflow protection caps at max")
    func windowOverflowProtection() async throws {
        let (connection, _) = createTestConnection()
        let stream = YamuxStream(id: 1, connection: connection)

        // Send massive delta that would overflow UInt32
        let hugeDeltas: [UInt32] = [UInt32.max / 2, UInt32.max / 2, UInt32.max / 2]

        for delta in hugeDeltas {
            stream.windowUpdate(delta: delta)
        }

        // Stream should still be functional (no crash from overflow)
        let testData = Data([0x01])
        _ = stream.dataReceived(testData)
        let result = try await stream.read()
        #expect(result == testData)
    }

    // MARK: - Data Received Tests

    @Test("Data exceeding receive window is rejected")
    func dataExceedingWindowRejected() async throws {
        let (connection, _) = createTestConnection()
        let stream = YamuxStream(id: 1, connection: connection)

        // Default window is 256KB, try to send more
        let oversizedData = Data(repeating: 0xFF, count: Int(yamuxDefaultWindowSize) + 1)
        let accepted = stream.dataReceived(oversizedData)

        #expect(accepted == false)
    }

    @Test("Data within receive window is accepted")
    func dataWithinWindowAccepted() async throws {
        let (connection, _) = createTestConnection()
        let stream = YamuxStream(id: 1, connection: connection)

        let normalData = Data(repeating: 0x42, count: 1000)
        let accepted = stream.dataReceived(normalData)

        #expect(accepted == true)
    }

    // MARK: - Close Tests

    @Test("CloseWrite sends FIN frame")
    func closeWriteSendsFIN() async throws {
        let (connection, mock) = createTestConnection()
        connection.start()
        let stream = YamuxStream(id: 1, connection: connection)

        try await stream.closeWrite()

        let outbound = mock.captureOutbound()
        #expect(outbound.count == 1)

        let decoded = try YamuxFrame.decode(from: outbound[0])
        #expect(decoded != nil)
        let frame = decoded!.frame
        #expect(frame.type == .data)
        #expect(frame.flags.contains(.fin))
        #expect(frame.streamID == 1)
    }

    @Test("Remote close resumes waiting readers with error")
    func remoteCloseResumesReaders() async throws {
        let (connection, _) = createTestConnection()
        let stream = YamuxStream(id: 1, connection: connection)

        // Start read task
        let readTask = Task {
            try await stream.read()
        }

        // Give read task time to start waiting
        try await Task.sleep(for: .milliseconds(50))

        // Remote close
        stream.remoteClose()

        // Read should throw
        await #expect(throws: YamuxError.self) {
            _ = try await readTask.value
        }
    }

    @Test("Reset cleans up all waiting continuations")
    func resetCleansUpAllWaiters() async throws {
        let (connection, _) = createTestConnection()
        let stream = YamuxStream(id: 1, connection: connection)

        // Start multiple read tasks
        let readTask1 = Task { try await stream.read() }
        let readTask2 = Task { try await stream.read() }

        // Give tasks time to start waiting
        try await Task.sleep(for: .milliseconds(50))

        // Reset stream
        stream.remoteReset()

        // Both should throw
        await #expect(throws: YamuxError.self) {
            _ = try await readTask1.value
        }
        await #expect(throws: YamuxError.self) {
            _ = try await readTask2.value
        }
    }

    // MARK: - Protocol ID Tests

    @Test("Protocol ID can be set and retrieved")
    func protocolIDSetAndGet() async throws {
        let (connection, _) = createTestConnection()
        let stream = YamuxStream(id: 1, connection: connection)

        #expect(stream.protocolID == nil)

        stream.protocolID = "/ipfs/id/1.0.0"
        #expect(stream.protocolID == "/ipfs/id/1.0.0")

        stream.protocolID = "/chat/1.0.0"
        #expect(stream.protocolID == "/chat/1.0.0")
    }

    // MARK: - Stream ID Tests

    @Test("Stream ID is preserved")
    func streamIDPreserved() async throws {
        let (connection, _) = createTestConnection()

        let stream1 = YamuxStream(id: 1, connection: connection)
        let stream2 = YamuxStream(id: 42, connection: connection)
        let stream3 = YamuxStream(id: UInt64(UInt32.max), connection: connection)

        #expect(stream1.id == 1)
        #expect(stream2.id == 42)
        #expect(stream3.id == UInt64(UInt32.max))
    }
}
