/// MplexConnectionTests - Tests for MplexConnection
import Foundation
import NIOCore
import Synchronization
import Testing
@testable import P2PCore
@testable import P2PMux
@testable import P2PMuxMplex

@Suite("MplexConnection Tests", .serialized)
struct MplexConnectionTests {

    // MARK: - Test Helpers

    static let testConfiguration = MplexConfiguration()

    func createTestConnection(
        isInitiator: Bool = true,
        configuration: MplexConfiguration = testConfiguration
    ) -> (MplexConnection, MockSecuredConnection) {
        let mock = MockSecuredConnection()
        let connection = MplexConnection(
            underlying: mock,
            localPeer: mock.localPeer,
            remotePeer: mock.remotePeer,
            isInitiator: isInitiator,
            configuration: configuration
        )
        return (connection, mock)
    }

    func decodeOutboundFrame(_ mock: MockSecuredConnection, at index: Int = 0) throws -> MplexFrame {
        let outbound = mock.captureOutbound()
        guard index < outbound.count else {
            throw TestError.noFrameAtIndex(index)
        }
        // Combine all data (in case frame was split)
        var combined = Data()
        for data in outbound {
            combined.append(data)
        }
        guard let (frame, _) = try MplexFrame.decode(from: combined) else {
            throw TestError.incompleteDecode
        }
        return frame
    }

    func injectFrame(_ mock: MockSecuredConnection, _ frame: MplexFrame) {
        mock.injectInbound(frame.encode())
    }

    // MARK: - Initialization Tests

    @Test("Connection initializes with correct peer IDs")
    func connectionInitializesWithPeerIDs() async throws {
        let (connection, mock) = createTestConnection()
        #expect(connection.localPeer == mock.localPeer)
        #expect(connection.remotePeer == mock.remotePeer)
    }

    @Test("Connection uses remote address from underlying connection")
    func connectionUsesRemoteAddress() async throws {
        let (connection, mock) = createTestConnection()
        #expect(connection.remoteAddress == mock.remoteAddress)
    }

    @Test("Both sides start with stream ID 0")
    func bothSidesStartWithStreamID0() async throws {
        let (initiatorConn, _) = createTestConnection(isInitiator: true)
        initiatorConn.start()
        let stream1 = try await initiatorConn.newStream()
        #expect(stream1.id == 0)
        try await initiatorConn.close()

        let (responderConn, _) = createTestConnection(isInitiator: false)
        responderConn.start()
        let stream2 = try await responderConn.newStream()
        #expect(stream2.id == 0)
        try await responderConn.close()
    }

    // MARK: - Start Tests

    @Test("Start is idempotent")
    func startIsIdempotent() async throws {
        let (connection, mock) = createTestConnection()

        // Multiple starts should not crash
        connection.start()
        connection.start()
        connection.start()

        // Connection should work
        _ = try await connection.newStream()
        try await connection.close()
    }

    // MARK: - Stream ID Management Tests

    @Test("Stream IDs are sequential starting from 0")
    func streamIDsSequentialFrom0() async throws {
        let (connection, _) = createTestConnection(isInitiator: true)
        connection.start()

        let stream1 = try await connection.newStream()
        let stream2 = try await connection.newStream()
        let stream3 = try await connection.newStream()

        #expect(stream1.id == 0)
        #expect(stream2.id == 1)
        #expect(stream3.id == 2)

        try await connection.close()
    }

    @Test("Stream IDs increment by 1")
    func streamIDsIncrementBy1() async throws {
        let (connection, _) = createTestConnection(isInitiator: true)
        connection.start()

        var previousID: UInt64 = 0
        for i in 0..<5 {
            let stream = try await connection.newStream()
            if i > 0 {
                #expect(stream.id == previousID + 1)
            }
            previousID = stream.id
        }

        try await connection.close()
    }

    // MARK: - Outbound Stream Tests

    @Test("newStream sends NewStream frame")
    func newStreamSendsNewStreamFrame() async throws {
        let (connection, mock) = createTestConnection(isInitiator: true)
        connection.start()

        _ = try await connection.newStream()

        try await Task.sleep(for: .milliseconds(50))

        let frame = try decodeOutboundFrame(mock)
        #expect(frame.flag == .newStream)
        #expect(frame.streamID == 0)

        try await connection.close()
    }

    @Test("newStream returns working stream")
    func newStreamReturnsWorkingStream() async throws {
        let (connection, mock) = createTestConnection(isInitiator: true)
        connection.start()

        let stream = try await connection.newStream()

        // Write should work
        try await stream.write(ByteBuffer(bytes: Data("hello".utf8)))

        try await Task.sleep(for: .milliseconds(50))

        // Should have sent NewStream and Message frames
        let outbound = mock.captureOutbound()
        #expect(outbound.count >= 2)

        try await connection.close()
    }

    @Test("newStream throws when connection is closed")
    func newStreamThrowsWhenClosed() async throws {
        let (connection, mock) = createTestConnection()
        connection.start()
        try await connection.close()

        await #expect(throws: MplexError.self) {
            _ = try await connection.newStream()
        }
    }

    @Test("newStream cleans up on send failure")
    func newStreamCleansUpOnSendFailure() async throws {
        let (connection, mock) = createTestConnection()
        connection.start()

        // Configure mock to fail writes
        mock.setWriteFailure(MockConnectionError.writeFailed)

        await #expect(throws: Error.self) {
            _ = try await connection.newStream()
        }

        // Next newStream should work after failure
        mock.clearOutbound()
        let stream = try await connection.newStream()
        #expect(stream.id == 1) // ID 0 was allocated but cleaned up

        try await connection.close()
    }

    // MARK: - Inbound Stream Tests

    @Test("Inbound NewStream creates stream", .timeLimit(.minutes(1)))
    func inboundNewStreamCreatesStream() async throws {
        let (connection, mock) = createTestConnection(isInitiator: true)
        connection.start()

        // Start accepting before frame arrives (waiting accepter)
        let acceptTask = Task {
            try await connection.acceptStream()
        }

        // Wait for readLoop to start and acceptStream to be waiting
        try await Task.sleep(for: .milliseconds(50))

        // Inject NewStream from remote (responder, so even ID)
        let newStreamFrame = MplexFrame.newStream(id: 2)
        injectFrame(mock, newStreamFrame)

        let stream = try await acceptTask.value
        #expect(stream.id == 2)

        try await connection.close()
    }

    @Test("Inbound stream delivered to waiting accept", .timeLimit(.minutes(1)))
    func inboundStreamDeliveredToWaitingAccept() async throws {
        let (connection, mock) = createTestConnection(isInitiator: true)
        connection.start()

        // Start accepting before stream arrives
        let acceptTask = Task {
            try await connection.acceptStream()
        }

        try await Task.sleep(for: .milliseconds(50))

        // Inject NewStream from remote
        let newStreamFrame = MplexFrame.newStream(id: 2)
        injectFrame(mock, newStreamFrame)

        let stream = try await acceptTask.value
        #expect(stream.id == 2)

        try await connection.close()
    }

    @Test("Any stream ID accepted from remote (no parity check)", .timeLimit(.minutes(1)))
    func anyStreamIDAcceptedFromRemote() async throws {
        let (connection, mock) = createTestConnection(isInitiator: true)
        connection.start()

        // Start accepting
        let acceptTask = Task {
            try await connection.acceptStream()
        }

        try await Task.sleep(for: .milliseconds(50))

        // Inject NewStream with any ID - Mplex has no parity rule
        let newStreamFrame = MplexFrame.newStream(id: 3)
        injectFrame(mock, newStreamFrame)

        let stream = try await acceptTask.value
        #expect(stream.id == 3)

        try await connection.close()
    }

    @Test("Duplicate stream ID rejected with Reset", .timeLimit(.minutes(1)))
    func duplicateStreamIDRejectedWithReset() async throws {
        let (connection, mock) = createTestConnection(isInitiator: true)
        connection.start()

        // Wait for readLoop to start
        try await Task.sleep(for: .milliseconds(50))

        // Inject first NewStream
        let firstFrame = MplexFrame.newStream(id: 2)
        injectFrame(mock, firstFrame)

        try await Task.sleep(for: .milliseconds(100))

        mock.clearOutbound()

        // Inject duplicate NewStream with same ID
        let duplicateFrame = MplexFrame.newStream(id: 2)
        injectFrame(mock, duplicateFrame)

        try await Task.sleep(for: .milliseconds(100))

        // Should have sent Reset frame
        let outbound = mock.captureOutbound()
        let hasReset = outbound.contains { data in
            guard let (frame, _) = try? MplexFrame.decode(from: data) else { return false }
            return frame.flag == .resetReceiver && frame.streamID == 2
        }
        #expect(hasReset)

        try await connection.close()
    }

    // MARK: - Stream Limit Tests

    @Test("Max concurrent streams enforced", .timeLimit(.minutes(1)))
    func maxConcurrentStreamsEnforced() async throws {
        let config = MplexConfiguration(maxConcurrentStreams: 2)
        let (connection, mock) = createTestConnection(isInitiator: true, configuration: config)
        connection.start()

        // Wait for readLoop to start
        try await Task.sleep(for: .milliseconds(50))

        // Create max streams from our side
        _ = try await connection.newStream() // ID 0
        _ = try await connection.newStream() // ID 1

        mock.clearOutbound()

        // Inject NewStream that would exceed limit
        let newStreamFrame = MplexFrame.newStream(id: 2)
        injectFrame(mock, newStreamFrame)

        try await Task.sleep(for: .milliseconds(100))

        // Should have sent Reset
        let outbound = mock.captureOutbound()
        let hasReset = outbound.contains { data in
            guard let (frame, _) = try? MplexFrame.decode(from: data) else { return false }
            return frame.flag == .resetReceiver && frame.streamID == 2
        }
        #expect(hasReset)

        try await connection.close()
    }

    // MARK: - Close Tests

    @Test("Close closes underlying connection")
    func closeClosesUnderlyingConnection() async throws {
        let (connection, mock) = createTestConnection()
        connection.start()

        try await connection.close()

        #expect(mock.wasClosed)
    }

    @Test("Close resumes pending accepts", .timeLimit(.minutes(1)))
    func closeResumesPendingAccepts() async throws {
        let (connection, mock) = createTestConnection()
        connection.start()

        let acceptTask = Task {
            try await connection.acceptStream()
        }

        try await Task.sleep(for: .milliseconds(50))

        // Close should resume the waiting accept
        try await connection.close()

        await #expect(throws: MplexError.self) {
            _ = try await acceptTask.value
        }
    }

    @Test("Close is idempotent")
    func closeIsIdempotent() async throws {
        let (connection, mock) = createTestConnection()
        connection.start()

        // Multiple closes should not crash
        try await connection.close()
        try await connection.close()
        try await connection.close()

        #expect(mock.wasClosed)
    }

    // MARK: - Message Handling Tests

    @Test("Message frame delivered to stream", .timeLimit(.minutes(1)))
    func messageFrameDeliveredToStream() async throws {
        let (connection, mock) = createTestConnection(isInitiator: true)
        connection.start()

        // Create outbound stream
        let stream = try await connection.newStream()

        mock.clearOutbound()

        // Inject Message for this stream (from remote, so Receiver flag)
        let messageFrame = MplexFrame.message(id: 0, isInitiator: false, data: Data("hello".utf8))
        injectFrame(mock, messageFrame)

        // Read from stream
        let data = try await stream.read()
        #expect(String(buffer: data) == "hello")

        try await connection.close()
    }

    @Test("Message for unknown stream ignored", .timeLimit(.minutes(1)))
    func messageForUnknownStreamIgnored() async throws {
        let (connection, mock) = createTestConnection(isInitiator: true)
        connection.start()

        // Wait for readLoop to start
        try await Task.sleep(for: .milliseconds(50))

        // Inject Message for non-existent stream
        let messageFrame = MplexFrame.message(id: 99, isInitiator: false, data: Data("hello".utf8))
        injectFrame(mock, messageFrame)

        try await Task.sleep(for: .milliseconds(100))

        // Should not crash, connection should still work
        _ = try await connection.newStream()

        try await connection.close()
    }

    @Test("Close frame triggers remote close", .timeLimit(.minutes(1)))
    func closeFrameTriggersRemoteClose() async throws {
        let (connection, mock) = createTestConnection(isInitiator: true)
        connection.start()

        // Create outbound stream
        let stream = try await connection.newStream()

        // Start read that will wait for data
        let readTask = Task {
            try await stream.read()
        }

        try await Task.sleep(for: .milliseconds(50))

        // Inject Close from remote (Receiver flag = local initiated)
        let closeFrame = MplexFrame.close(id: 0, isInitiator: false)
        injectFrame(mock, closeFrame)

        // Read should fail
        await #expect(throws: MplexError.self) {
            _ = try await readTask.value
        }

        try await connection.close()
    }

    @Test("Reset frame triggers remote reset", .timeLimit(.minutes(1)))
    func resetFrameTriggersRemoteReset() async throws {
        let (connection, mock) = createTestConnection(isInitiator: true)
        connection.start()

        // Create outbound stream
        let stream = try await connection.newStream()

        // Start read that will wait for data
        let readTask = Task {
            try await stream.read()
        }

        try await Task.sleep(for: .milliseconds(50))

        // Inject Reset from remote (Receiver flag = local initiated)
        let resetFrame = MplexFrame.reset(id: 0, isInitiator: false)
        injectFrame(mock, resetFrame)

        // Read should fail
        await #expect(throws: MplexError.self) {
            _ = try await readTask.value
        }

        try await connection.close()
    }

    // MARK: - Perspective Tests (Mplex-specific)

    @Test("Initiator sends MessageInitiator")
    func initiatorSendsMessageInitiator() async throws {
        let (connection, mock) = createTestConnection(isInitiator: true)
        connection.start()

        let stream = try await connection.newStream()
        mock.clearOutbound()

        try await stream.write(ByteBuffer(bytes: Data("test".utf8)))

        try await Task.sleep(for: .milliseconds(50))

        let outbound = mock.captureOutbound()
        let hasMessageInitiator = outbound.contains { data in
            guard let (frame, _) = try? MplexFrame.decode(from: data) else { return false }
            return frame.flag == .messageInitiator && frame.streamID == 0
        }
        #expect(hasMessageInitiator)

        try await connection.close()
    }

    @Test("Initiator sends CloseInitiator")
    func initiatorSendsCloseInitiator() async throws {
        let (connection, mock) = createTestConnection(isInitiator: true)
        connection.start()

        let stream = try await connection.newStream()
        mock.clearOutbound()

        try await stream.closeWrite()

        try await Task.sleep(for: .milliseconds(50))

        let outbound = mock.captureOutbound()
        let hasCloseInitiator = outbound.contains { data in
            guard let (frame, _) = try? MplexFrame.decode(from: data) else { return false }
            return frame.flag == .closeInitiator && frame.streamID == 0
        }
        #expect(hasCloseInitiator)

        try await connection.close()
    }

    // MARK: - Close While Active Streams Tests

    @Test("Close while streams actively reading", .timeLimit(.minutes(1)))
    func closeWhileStreamsActivelyReading() async throws {
        let (connection, mock) = createTestConnection(isInitiator: true)
        connection.start()

        let stream1 = try await connection.newStream()
        let stream2 = try await connection.newStream()

        // Start reads on both streams that will block waiting for data
        let readTask1 = Task {
            try await stream1.read()
        }
        let readTask2 = Task {
            try await stream2.read()
        }

        try await Task.sleep(for: .milliseconds(50))

        // Close the connection while reads are pending
        try await connection.close()

        // Both reads should fail with an error
        await #expect(throws: Error.self) {
            _ = try await readTask1.value
        }
        await #expect(throws: Error.self) {
            _ = try await readTask2.value
        }
    }

    @Test("Close while inbound stream accepted", .timeLimit(.minutes(1)))
    func closeWhileInboundStreamAccepted() async throws {
        let (connection, mock) = createTestConnection(isInitiator: true)
        connection.start()

        // Accept an inbound stream first
        let acceptTask = Task {
            try await connection.acceptStream()
        }

        try await Task.sleep(for: .milliseconds(50))

        // Inject an inbound stream
        injectFrame(mock, MplexFrame.newStream(id: 0))

        let inboundStream = try await acceptTask.value
        #expect(inboundStream.id == 0)

        // Start reading on the accepted stream
        let readTask = Task {
            try await inboundStream.read()
        }

        try await Task.sleep(for: .milliseconds(50))

        // Close connection while inbound stream is active
        try await connection.close()

        // The read on the inbound stream should fail
        await #expect(throws: Error.self) {
            _ = try await readTask.value
        }
    }

    @Test("Concurrent newStream from multiple tasks produces unique IDs", .timeLimit(.minutes(1)))
    func concurrentNewStreamUniqueIDs() async throws {
        let (connection, _) = createTestConnection(isInitiator: true)
        connection.start()

        let streamCount = 20
        let ids = Mutex<Set<UInt64>>(Set())

        // Launch many concurrent newStream calls
        try await withThrowingTaskGroup(of: UInt64.self) { group in
            for _ in 0..<streamCount {
                group.addTask {
                    let stream = try await connection.newStream()
                    return stream.id
                }
            }
            for try await id in group {
                ids.withLock { $0.insert(id) }
            }
        }

        // All IDs should be unique
        let allIDs = ids.withLock { $0 }
        #expect(allIDs.count == streamCount)

        // IDs should be 0..<streamCount
        for i in 0..<UInt64(streamCount) {
            #expect(allIDs.contains(i))
        }

        try await connection.close()
    }

    @Test("inboundStreams terminates on close", .timeLimit(.minutes(1)))
    func inboundStreamsTerminatesOnClose() async throws {
        let (connection, mock) = createTestConnection(isInitiator: true)
        connection.start()

        // Start iterating inboundStreams
        let receivedCount = Mutex<Int>(0)
        let iterationComplete = Mutex<Bool>(false)

        let iterTask = Task {
            for await _ in connection.inboundStreams {
                receivedCount.withLock { $0 += 1 }
            }
            iterationComplete.withLock { $0 = true }
        }

        try await Task.sleep(for: .milliseconds(50))

        // Inject one stream
        injectFrame(mock, MplexFrame.newStream(id: 0))

        try await Task.sleep(for: .milliseconds(100))

        // Close the connection
        try await connection.close()

        // Wait for iteration to complete
        try await Task.sleep(for: .milliseconds(100))

        let completed = iterationComplete.withLock { $0 }
        #expect(completed)

        iterTask.cancel()
    }

    @Test("Large frame near maxFrameSize boundary accepted", .timeLimit(.minutes(1)))
    func largeFrameNearMaxFrameSize() async throws {
        let maxFrame = 4096
        let config = MplexConfiguration(maxFrameSize: maxFrame)
        let (connection, mock) = createTestConnection(isInitiator: true, configuration: config)
        connection.start()

        let stream = try await connection.newStream()

        // Inject a frame with data exactly at the maxFrameSize limit
        let largeData = Data(repeating: 0xAB, count: maxFrame)
        let messageFrame = MplexFrame.message(id: 0, isInitiator: false, data: largeData)
        injectFrame(mock, messageFrame)

        try await Task.sleep(for: .milliseconds(100))

        let data = try await stream.read()
        #expect(data.readableBytes == maxFrame)

        try await connection.close()
    }

    @Test("Stream created then immediately reset completes 0-data lifecycle", .timeLimit(.minutes(1)))
    func streamCreatedThenImmediatelyReset() async throws {
        let (connection, mock) = createTestConnection(isInitiator: true)
        connection.start()

        let stream = try await connection.newStream()
        #expect(stream.id == 0)

        mock.clearOutbound()

        // Immediately reset without sending any data
        try await stream.reset()

        try await Task.sleep(for: .milliseconds(50))

        // Should have sent a Reset frame
        let outbound = mock.captureOutbound()
        let hasReset = outbound.contains { data in
            guard let (frame, _) = try? MplexFrame.decode(from: data) else { return false }
            return frame.flag == .resetInitiator && frame.streamID == 0
        }
        #expect(hasReset)

        // Connection should still work for new streams
        let stream2 = try await connection.newStream()
        #expect(stream2.id == 1)

        try await connection.close()
    }

    @Test("Rapid open/close cycles do not leak resources", .timeLimit(.minutes(1)))
    func rapidOpenCloseCycles() async throws {
        let (connection, _) = createTestConnection(isInitiator: true)
        connection.start()

        // Rapidly open and close streams
        for i in 0..<50 {
            let stream = try await connection.newStream()
            #expect(stream.id == UInt64(i))
            try await stream.close()
        }

        // Connection should still be functional
        let finalStream = try await connection.newStream()
        #expect(finalStream.id == 50)

        try await connection.close()
    }

    @Test("newStream after connection close throws", .timeLimit(.minutes(1)))
    func newStreamAfterConnectionCloseThrows() async throws {
        let (connection, _) = createTestConnection(isInitiator: true)
        connection.start()

        // Create one stream to ensure connection works
        let stream = try await connection.newStream()
        #expect(stream.id == 0)

        // Close the connection
        try await connection.close()

        // Attempting to create new streams should throw
        await #expect(throws: MplexError.self) {
            _ = try await connection.newStream()
        }

        // Multiple attempts should all throw
        await #expect(throws: MplexError.self) {
            _ = try await connection.newStream()
        }
    }
}

// MARK: - Test Errors

enum TestError: Error {
    case noFrameAtIndex(Int)
    case incompleteDecode
    case unexpectedStreamType
}
