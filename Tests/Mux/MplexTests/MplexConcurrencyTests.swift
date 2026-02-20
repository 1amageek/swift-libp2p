/// MplexConcurrencyTests - Concurrency and thread-safety tests for Mplex
import Foundation
import NIOCore
import Synchronization
import Testing
@testable import P2PCore
@testable import P2PMux
@testable import P2PMuxMplex

@Suite("MplexConcurrency Tests", .serialized)
struct MplexConcurrencyTests {

    // MARK: - Test Helpers

    func createTestConnection(
        isInitiator: Bool = true,
        configuration: MplexConfiguration = MplexConfiguration()
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

    func injectFrame(_ mock: MockSecuredConnection, _ frame: MplexFrame) {
        mock.injectInbound(frame.encode())
    }

    // MARK: - Concurrent Read Tests

    @Test("Concurrent reads from same stream each receive distinct data", .timeLimit(.minutes(1)))
    func concurrentReadsFromSameStream() async throws {
        let (connection, mock) = createTestConnection(isInitiator: true)
        connection.start()

        let stream = try await connection.newStream()

        // Start multiple concurrent reads
        let readTask1 = Task {
            try await stream.read()
        }
        let readTask2 = Task {
            try await stream.read()
        }

        try await Task.sleep(for: .milliseconds(50))

        // Inject two data frames - each pending read should get one
        injectFrame(mock, MplexFrame.message(id: 0, isInitiator: false, data: Data("data1".utf8)))
        injectFrame(mock, MplexFrame.message(id: 0, isInitiator: false, data: Data("data2".utf8)))

        let result1 = try await readTask1.value
        let result2 = try await readTask2.value

        let str1 = String(buffer: result1)
        let str2 = String(buffer: result2)

        // Both reads should complete; each should get one piece of data
        let results = Set([str1, str2])
        #expect(results.contains("data1"))
        #expect(results.contains("data2"))

        try await connection.close()
    }

    // MARK: - Concurrent Write Tests

    @Test("Concurrent writes from same stream all succeed", .timeLimit(.minutes(1)))
    func concurrentWritesFromSameStream() async throws {
        let (connection, mock) = createTestConnection(isInitiator: true)
        connection.start()

        let stream = try await connection.newStream()
        mock.clearOutbound()

        let writeCount = 10

        // Launch concurrent writes
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<writeCount {
                group.addTask {
                    try await stream.write(ByteBuffer(bytes: Data("msg\(i)".utf8)))
                }
            }
            try await group.waitForAll()
        }

        try await Task.sleep(for: .milliseconds(50))

        // All writes should have produced outbound frames
        let outbound = mock.captureOutbound()
        let messageCount = outbound.filter { data in
            guard let (frame, _) = try? MplexFrame.decode(from: data) else { return false }
            return frame.flag == .messageInitiator && frame.streamID == 0
        }.count
        #expect(messageCount == writeCount)

        try await connection.close()
    }

    // MARK: - Concurrent newStream Tests

    @Test("Concurrent newStream from multiple tasks produces sequential IDs", .timeLimit(.minutes(1)))
    func concurrentNewStreamSequentialIDs() async throws {
        let (connection, _) = createTestConnection(isInitiator: true)
        connection.start()

        let streamCount = 30
        let collectedIDs = Mutex<[UInt64]>([])

        try await withThrowingTaskGroup(of: UInt64.self) { group in
            for _ in 0..<streamCount {
                group.addTask {
                    let stream = try await connection.newStream()
                    return stream.id
                }
            }
            for try await id in group {
                collectedIDs.withLock { $0.append(id) }
            }
        }

        let ids = collectedIDs.withLock { $0 }
        #expect(ids.count == streamCount)

        // All IDs should be unique and in the range [0, streamCount)
        let uniqueIDs = Set(ids)
        #expect(uniqueIDs.count == streamCount)

        let sortedIDs = ids.sorted()
        for (index, id) in sortedIDs.enumerated() {
            #expect(id == UInt64(index))
        }

        try await connection.close()
    }

    // MARK: - Stream Independence Tests

    @Test("Read from one stream while another is reset (stream independence)", .timeLimit(.minutes(1)))
    func readFromOneStreamWhileAnotherReset() async throws {
        let (connection, mock) = createTestConnection(isInitiator: true)
        connection.start()

        let stream1 = try await connection.newStream() // ID 0
        let stream2 = try await connection.newStream() // ID 1

        // Start reading on stream1
        let readTask1 = Task {
            try await stream1.read()
        }

        try await Task.sleep(for: .milliseconds(50))

        // Reset stream2 - should not affect stream1
        try await stream2.reset()

        try await Task.sleep(for: .milliseconds(50))

        // Inject data for stream1 - it should still work
        injectFrame(mock, MplexFrame.message(id: 0, isInitiator: false, data: Data("stream1-alive".utf8)))

        let data = try await readTask1.value
        #expect(String(buffer: data) == "stream1-alive")

        // stream2 operations should fail
        await #expect(throws: MplexError.self) {
            _ = try await stream2.read()
        }
        await #expect(throws: MplexError.self) {
            try await stream2.write(ByteBuffer(bytes: Data("fail".utf8)))
        }

        try await connection.close()
    }

    // MARK: - Accept + NewStream Simultaneously

    @Test("Accept and newStream operate independently", .timeLimit(.minutes(1)))
    func acceptAndNewStreamSimultaneously() async throws {
        let (connection, mock) = createTestConnection(isInitiator: true)
        connection.start()

        // Start accepting inbound streams
        let acceptTask = Task {
            try await connection.acceptStream()
        }

        // Simultaneously create an outbound stream
        let outboundStream = try await connection.newStream()
        #expect(outboundStream.id == 0)

        try await Task.sleep(for: .milliseconds(50))

        // Inject an inbound stream from remote
        injectFrame(mock, MplexFrame.newStream(id: 10))

        let inboundStream = try await acceptTask.value
        #expect(inboundStream.id == 10)

        // Both streams should be independently functional
        // Write on outbound
        mock.clearOutbound()
        try await outboundStream.write(ByteBuffer(bytes: Data("outbound".utf8)))

        try await Task.sleep(for: .milliseconds(50))

        let outbound = mock.captureOutbound()
        let hasOutboundMsg = outbound.contains { data in
            guard let (frame, _) = try? MplexFrame.decode(from: data) else { return false }
            return frame.flag == .messageInitiator && frame.streamID == 0
        }
        #expect(hasOutboundMsg)

        // Read on inbound
        injectFrame(mock, MplexFrame.message(id: 10, isInitiator: true, data: Data("inbound".utf8)))

        let inboundData = try await inboundStream.read()
        #expect(String(buffer: inboundData) == "inbound")

        try await connection.close()
    }

    // MARK: - Write During Connection Close

    @Test("Write during connection close returns error", .timeLimit(.minutes(1)))
    func writeDuringConnectionClose() async throws {
        let (connection, mock) = createTestConnection(isInitiator: true)
        connection.start()

        let stream = try await connection.newStream()

        // Close the connection
        try await connection.close()

        // Write should fail because connection is closed
        await #expect(throws: Error.self) {
            try await stream.write(ByteBuffer(bytes: Data("should-fail".utf8)))
        }
    }
}
