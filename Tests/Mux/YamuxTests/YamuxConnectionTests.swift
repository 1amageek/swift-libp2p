/// YamuxConnectionTests - Tests for YamuxConnection lifecycle and security
import Testing
import Foundation
import NIOCore
@testable import P2PMuxYamux
@testable import P2PCore
@testable import P2PMux

/// Helper to decode a YamuxFrame from Data (used when reading from mock outbound).
private func decodeFrame(from data: Data) throws -> YamuxFrame? {
    var buffer = ByteBuffer(bytes: data)
    return try YamuxFrame.decode(from: &buffer)
}

@Suite("YamuxConnection Tests", .serialized)
struct YamuxConnectionTests {

    // MARK: - Test Fixtures

    /// Test configuration with keep-alive disabled to avoid unexpected ping frames in tests.
    static let testConfiguration = YamuxConfiguration(enableKeepAlive: false)

    func createTestConnection(
        isInitiator: Bool = true,
        configuration: YamuxConfiguration = testConfiguration
    ) -> (YamuxConnection, MockSecuredConnection) {
        let mock = MockSecuredConnection()
        let connection = YamuxConnection(
            underlying: mock,
            localPeer: mock.localPeer,
            remotePeer: mock.remotePeer,
            isInitiator: isInitiator,
            configuration: configuration
        )
        return (connection, mock)
    }

    // MARK: - Initialization Tests

    @Test("Connection initializes with correct peer IDs")
    func connectionInitializesWithPeerIDs() async throws {
        let localPeer = KeyPair.generateEd25519().peerID
        let remotePeer = KeyPair.generateEd25519().peerID
        let mock = MockSecuredConnection(localPeer: localPeer, remotePeer: remotePeer)

        let connection = YamuxConnection(
            underlying: mock,
            localPeer: localPeer,
            remotePeer: remotePeer,
            isInitiator: true
        )

        #expect(connection.localPeer == localPeer)
        #expect(connection.remotePeer == remotePeer)
    }

    @Test("Connection uses remote address from underlying connection")
    func connectionUsesRemoteAddress() async throws {
        let remoteAddr = Multiaddr.tcp(host: "192.168.1.100", port: 9999)
        let mock = MockSecuredConnection(remoteAddress: remoteAddr)

        let connection = YamuxConnection(
            underlying: mock,
            localPeer: mock.localPeer,
            remotePeer: mock.remotePeer,
            isInitiator: true
        )

        #expect(connection.remoteAddress == remoteAddr)
    }

    // MARK: - Start Tests

    @Test("Start is idempotent")
    func startIsIdempotent() async throws {
        let (connection, _) = createTestConnection()

        // Multiple starts should not throw or cause issues
        connection.start()
        connection.start()
        connection.start()

        // Connection should still work
        try await connection.close()
    }

    // MARK: - Stream ID Tests

    @Test("Initiator assigns odd stream IDs")
    func initiatorAssignsOddStreamIDs() async throws {
        let (connection, mock) = createTestConnection(isInitiator: true)
        connection.start()

        // Create first stream
        let stream1 = try await connection.newStream()
        #expect(stream1.id % 2 == 1) // Odd

        // Parse the SYN frame to verify stream ID
        let outbound = mock.captureOutbound()
        #expect(outbound.count >= 1)
        let decoded = try decodeFrame(from: outbound[0])
        #expect(decoded != nil)
        #expect(decoded!.streamID % 2 == 1)
    }

    @Test("Responder assigns even stream IDs")
    func responderAssignsEvenStreamIDs() async throws {
        let (connection, mock) = createTestConnection(isInitiator: false)
        connection.start()

        // Create first stream
        let stream1 = try await connection.newStream()
        #expect(stream1.id % 2 == 0) // Even

        // Parse the SYN frame to verify stream ID
        let outbound = mock.captureOutbound()
        #expect(outbound.count >= 1)
        let decoded = try decodeFrame(from: outbound[0])
        #expect(decoded != nil)
        #expect(decoded!.streamID % 2 == 0)
    }

    @Test("Stream IDs increment by 2")
    func streamIDsIncrementBy2() async throws {
        let (connection, mock) = createTestConnection(isInitiator: true)
        connection.start()

        _ = try await connection.newStream() // ID 1
        mock.clearOutbound()

        _ = try await connection.newStream() // ID 3
        let outbound = mock.captureOutbound()
        let decoded = try decodeFrame(from: outbound[0])
        #expect(decoded != nil)
        #expect(decoded!.streamID == 3)
    }

    // MARK: - newStream Tests

    @Test("newStream sends SYN frame")
    func newStreamSendsSYN() async throws {
        let (connection, mock) = createTestConnection()
        connection.start()

        _ = try await connection.newStream()

        let outbound = mock.captureOutbound()
        #expect(outbound.count == 1)

        let decoded = try decodeFrame(from: outbound[0])
        #expect(decoded != nil)
        #expect(decoded!.type == .data)
        #expect(decoded!.flags.contains(.syn))
    }

    @Test("newStream throws when connection is closed")
    func newStreamThrowsWhenClosed() async throws {
        let (connection, _) = createTestConnection()
        connection.start()

        try await connection.close()

        await #expect(throws: YamuxError.self) {
            _ = try await connection.newStream()
        }
    }

    @Test("newStream cleans up on SYN send failure")
    func newStreamCleansUpOnFailure() async throws {
        let (connection, mock) = createTestConnection()
        connection.start()

        // Configure mock to fail write
        mock.setWriteFailure(MockConnectionError.writeFailed)

        await #expect(throws: MockConnectionError.self) {
            _ = try await connection.newStream()
        }

        // Subsequent newStream should still work if write succeeds
        _ = try await connection.newStream()
    }

    // MARK: - Inbound Stream Tests

    @Test("Inbound SYN creates stream and sends ACK")
    func inboundSYNCreatesStream() async throws {
        let (connection, mock) = createTestConnection(isInitiator: true)
        connection.start()

        // Create SYN frame from responder (even ID)
        let synFrame = YamuxFrame(
            type: .data,
            flags: .syn,
            streamID: 2, // Even = from responder
            length: 0,
            data: nil
        )
        mock.injectInbound(synFrame.encode())

        // Wait for processing
        try await Task.sleep(for: .milliseconds(100))

        // Check ACK was sent
        let outbound = mock.captureOutbound()
        let hasACK = outbound.contains { data in
            guard let frame = try? decodeFrame(from: data) else { return false }
            return frame.flags.contains(.ack) && frame.streamID == 2
        }
        #expect(hasACK)
    }

    @Test("Invalid stream ID parity rejected with RST")
    func invalidStreamIDParityRejected() async throws {
        let (connection, mock) = createTestConnection(isInitiator: true)
        connection.start()

        // Create SYN frame with wrong parity (odd ID from responder)
        let synFrame = YamuxFrame(
            type: .data,
            flags: .syn,
            streamID: 3, // Odd = should be from initiator, not responder
            length: 0,
            data: nil
        )
        mock.injectInbound(synFrame.encode())

        // Wait for processing
        try await Task.sleep(for: .milliseconds(100))

        // Check RST was sent
        let outbound = mock.captureOutbound()
        let hasRST = outbound.contains { data in
            guard let frame = try? decodeFrame(from: data) else { return false }
            return frame.flags.contains(.rst) && frame.streamID == 3
        }
        #expect(hasRST)
    }

    @Test("Stream ID 0 for data rejected with RST")
    func streamIDZeroForDataRejected() async throws {
        let (connection, mock) = createTestConnection(isInitiator: true)
        connection.start()

        // Create SYN frame with stream ID 0
        let synFrame = YamuxFrame(
            type: .data,
            flags: .syn,
            streamID: 0, // Invalid for data
            length: 0,
            data: nil
        )
        mock.injectInbound(synFrame.encode())

        // Wait for processing
        try await Task.sleep(for: .milliseconds(100))

        // Check RST was sent
        let outbound = mock.captureOutbound()
        let hasRST = outbound.contains { data in
            guard let frame = try? decodeFrame(from: data) else { return false }
            return frame.flags.contains(.rst) && frame.streamID == 0
        }
        #expect(hasRST)
    }

    // MARK: - Stream Limit Tests

    @Test("Max concurrent streams limit enforced")
    func maxStreamsLimitEnforced() async throws {
        let config = YamuxConfiguration(maxConcurrentStreams: 2)
        let (connection, mock) = createTestConnection(configuration: config)
        connection.start()

        // Create outbound streams (newStream doesn't enforce limit on client side)
        _ = try await connection.newStream() // ID 1
        _ = try await connection.newStream() // ID 3
        _ = try await connection.newStream() // ID 5

        // Now test that inbound streams are rejected when total count exceeds limit
        mock.clearOutbound()

        for i in 0..<3 {
            let synFrame = YamuxFrame(
                type: .data,
                flags: .syn,
                streamID: UInt32(2 + i * 2), // Even IDs: 2, 4, 6
                length: 0,
                data: nil
            )
            mock.injectInbound(synFrame.encode())
        }

        // Wait for processing
        try await Task.sleep(for: .milliseconds(200))

        // With 3 outbound streams already in map (exceeding limit of 2),
        // all 3 inbound SYN attempts should be rejected with RST
        let outbound = mock.captureOutbound()
        let rstCount = outbound.filter { data in
            guard let frame = try? decodeFrame(from: data) else { return false }
            return frame.flags.contains(.rst)
        }.count

        #expect(rstCount > 0)
    }

    // MARK: - GoAway Tests

    @Test("GoAway received closes connection")
    func goAwayClosesConnection() async throws {
        let (connection, mock) = createTestConnection()
        connection.start()

        // Inject GoAway frame
        let goAwayFrame = YamuxFrame.goAway(reason: .normal)
        mock.injectInbound(goAwayFrame.encode())

        // Wait for processing
        try await Task.sleep(for: .milliseconds(100))

        // newStream should fail
        await #expect(throws: YamuxError.self) {
            _ = try await connection.newStream()
        }
    }

    @Test("GoAway received notifies all streams")
    func goAwayNotifiesAllStreams() async throws {
        let (connection, mock) = createTestConnection()
        connection.start()

        // Create some streams
        let stream1 = try await connection.newStream()
        let stream2 = try await connection.newStream()

        // Start reads on streams
        let readTask1 = Task { try await stream1.read() }
        let readTask2 = Task { try await stream2.read() }

        // Give tasks time to start
        try await Task.sleep(for: .milliseconds(50))

        // Inject GoAway frame
        let goAwayFrame = YamuxFrame.goAway(reason: .normal)
        mock.injectInbound(goAwayFrame.encode())

        // Wait for processing
        try await Task.sleep(for: .milliseconds(100))

        // Reads should throw (streams should be notified)
        await #expect(throws: YamuxError.self) {
            _ = try await readTask1.value
        }
        await #expect(throws: YamuxError.self) {
            _ = try await readTask2.value
        }
    }

    @Test("GoAway received resumes pending accepts")
    func goAwayResumesPendingAccepts() async throws {
        let (connection, mock) = createTestConnection()
        connection.start()

        // Start an accept that will block
        let acceptTask = Task {
            try await connection.acceptStream()
        }

        // Give task time to start
        try await Task.sleep(for: .milliseconds(50))

        // Inject GoAway frame
        let goAwayFrame = YamuxFrame.goAway(reason: .protocolError)
        mock.injectInbound(goAwayFrame.encode())

        // Wait for processing
        try await Task.sleep(for: .milliseconds(100))

        // Accept should throw
        await #expect(throws: YamuxError.self) {
            _ = try await acceptTask.value
        }
    }

    // MARK: - Ping Tests

    @Test("Ping request receives pong response")
    func pingReceivesPong() async throws {
        let (connection, mock) = createTestConnection()
        connection.start()

        // Inject ping request
        let pingFrame = YamuxFrame.ping(opaque: 12345, ack: false)
        mock.injectInbound(pingFrame.encode())

        // Wait for processing
        try await Task.sleep(for: .milliseconds(100))

        // Check pong was sent
        let outbound = mock.captureOutbound()
        let hasPong = outbound.contains { data in
            guard let frame = try? decodeFrame(from: data) else { return false }
            return frame.type == .ping &&
                   frame.flags.contains(.ack) &&
                   frame.length == 12345
        }
        #expect(hasPong)
    }

    // MARK: - Close Tests

    @Test("Close sends GoAway frame")
    func closeSendsGoAway() async throws {
        let (connection, mock) = createTestConnection()
        connection.start()

        try await connection.close()

        let outbound = mock.captureOutbound()
        let hasGoAway = outbound.contains { data in
            guard let frame = try? decodeFrame(from: data) else { return false }
            return frame.type == .goAway
        }
        #expect(hasGoAway)
    }

    @Test("Close notifies all streams")
    func closeNotifiesAllStreams() async throws {
        let (connection, _) = createTestConnection()
        connection.start()

        // Create some streams
        let stream1 = try await connection.newStream()
        let stream2 = try await connection.newStream()

        // Start reads on streams
        let readTask1 = Task { try await stream1.read() }
        let readTask2 = Task { try await stream2.read() }

        // Give tasks time to start
        try await Task.sleep(for: .milliseconds(50))

        // Close connection
        try await connection.close()

        // Reads should throw
        await #expect(throws: Error.self) {
            _ = try await readTask1.value
        }
        await #expect(throws: Error.self) {
            _ = try await readTask2.value
        }
    }

    // MARK: - FIN/RST Frame Tests

    @Test("FIN frame closes remote side of stream")
    func finFrameClosesRemoteSide() async throws {
        let (connection, mock) = createTestConnection()
        connection.start()

        // Create outbound stream
        let stream = try await connection.newStream()

        // Start read
        let readTask = Task { try await stream.read() }
        try await Task.sleep(for: .milliseconds(50))

        // Inject FIN for this stream
        let finFrame = YamuxFrame(
            type: .data,
            flags: .fin,
            streamID: UInt32(stream.id),
            length: 0,
            data: nil
        )
        mock.injectInbound(finFrame.encode())

        // Read should throw (remote closed)
        await #expect(throws: YamuxError.self) {
            _ = try await readTask.value
        }
    }

    @Test("RST frame abruptly terminates stream")
    func rstFrameTerminatesStream() async throws {
        let (connection, mock) = createTestConnection()
        connection.start()

        // Create outbound stream
        let stream = try await connection.newStream()

        // Start read
        let readTask = Task { try await stream.read() }
        try await Task.sleep(for: .milliseconds(50))

        // Inject RST for this stream
        let rstFrame = YamuxFrame(
            type: .data,
            flags: .rst,
            streamID: UInt32(stream.id),
            length: 0,
            data: nil
        )
        mock.injectInbound(rstFrame.encode())

        // Read should throw
        await #expect(throws: YamuxError.self) {
            _ = try await readTask.value
        }
    }

    // MARK: - Window Update Tests

    @Test("Window update is forwarded to stream")
    func windowUpdateForwardedToStream() async throws {
        let (connection, mock) = createTestConnection()
        connection.start()

        // Create outbound stream
        let stream = try await connection.newStream()
        mock.clearOutbound()

        // Inject window update
        let windowFrame = YamuxFrame.windowUpdate(streamID: UInt32(stream.id), delta: 65536)
        mock.injectInbound(windowFrame.encode())

        // Wait for processing
        try await Task.sleep(for: .milliseconds(100))

        // Stream should still be usable
        let testData = ByteBuffer(bytes: [0x01, 0x02])
        try await stream.write(testData)

        let outbound = mock.captureOutbound()
        #expect(!outbound.isEmpty)
    }

    // MARK: - Keep-Alive Tests

    @Test("Keep-alive disabled does not start timer")
    func keepAliveDisabledNoTask() async throws {
        let config = YamuxConfiguration(enableKeepAlive: false)
        let (connection, mock) = createTestConnection(configuration: config)
        connection.start()

        // Wait a bit to ensure no pings are sent
        try await Task.sleep(for: .milliseconds(200))

        // No ping frames should be sent
        let outbound = mock.captureOutbound()
        let hasPing = outbound.contains { data in
            guard let frame = try? decodeFrame(from: data) else { return false }
            return frame.type == .ping && !frame.flags.contains(.ack)
        }
        #expect(!hasPing)

        try await connection.close()
    }

    @Test("Keep-alive sends ping after interval")
    func keepAliveSendsPing() async throws {
        // Use very short interval for testing
        let config = YamuxConfiguration(
            enableKeepAlive: true,
            keepAliveInterval: .milliseconds(100),
            keepAliveTimeout: .milliseconds(500)
        )
        let (connection, mock) = createTestConnection(configuration: config)
        connection.start()

        // Wait for more than one interval
        try await Task.sleep(for: .milliseconds(250))

        // Check that ping was sent
        let outbound = mock.captureOutbound()
        let hasPing = outbound.contains { data in
            guard let frame = try? decodeFrame(from: data) else { return false }
            return frame.type == .ping && !frame.flags.contains(.ack)
        }
        #expect(hasPing)

        try await connection.close()
    }

    @Test("Pong response clears pending ping")
    func pongResponseClearsPending() async throws {
        let config = YamuxConfiguration(
            enableKeepAlive: true,
            keepAliveInterval: .milliseconds(50),
            keepAliveTimeout: .milliseconds(500)
        )
        let (connection, mock) = createTestConnection(configuration: config)
        connection.start()

        // Wait for ping to be sent
        try await Task.sleep(for: .milliseconds(100))

        // Find the ping ID from outbound
        let outbound = mock.captureOutbound()
        var pingID: UInt32?
        for data in outbound {
            if let decoded = try? decodeFrame(from: data),
               decoded.type == .ping && !decoded.flags.contains(.ack) {
                pingID = decoded.length
                break
            }
        }

        guard let id = pingID else {
            Issue.record("No ping frame was sent")
            return
        }

        // Inject pong response
        let pongFrame = YamuxFrame.ping(opaque: id, ack: true)
        mock.injectInbound(pongFrame.encode())

        // Wait for processing
        try await Task.sleep(for: .milliseconds(50))

        // Connection should still be open (no timeout)
        // Create a stream to verify connection is alive
        let stream = try await connection.newStream()
        #expect(stream.id > 0)

        try await connection.close()
    }

    @Test("Keep-alive timeout closes connection")
    func keepAliveTimeoutClosesConnection() async throws {
        let config = YamuxConfiguration(
            enableKeepAlive: true,
            keepAliveInterval: .milliseconds(50),
            keepAliveTimeout: .milliseconds(100)
        )
        let (connection, _) = createTestConnection(configuration: config)
        connection.start()

        // Don't respond to pings - wait for timeout
        // Timeout occurs when: ping sent at 50ms, checked at 100ms with timeout of 100ms
        // So at 150ms the ping is 100ms old, which exceeds timeout
        try await Task.sleep(for: .milliseconds(250))

        // Connection should be closed
        await #expect(throws: YamuxError.self) {
            _ = try await connection.newStream()
        }
    }

    @Test("Keep-alive timeout notifies all streams")
    func keepAliveTimeoutNotifiesAllStreams() async throws {
        let config = YamuxConfiguration(
            enableKeepAlive: true,
            keepAliveInterval: .milliseconds(50),
            keepAliveTimeout: .milliseconds(100)
        )
        let (connection, _) = createTestConnection(configuration: config)
        connection.start()

        // Create a stream
        let stream = try await connection.newStream()

        // Start a read on the stream
        let readTask = Task { try await stream.read() }

        // Wait for timeout
        try await Task.sleep(for: .milliseconds(250))

        // Read should throw
        await #expect(throws: YamuxError.self) {
            _ = try await readTask.value
        }
    }

    @Test("Multiple pings can be in-flight")
    func multipleInFlightPings() async throws {
        let config = YamuxConfiguration(
            enableKeepAlive: true,
            keepAliveInterval: .milliseconds(30),
            keepAliveTimeout: .milliseconds(500)
        )
        let (connection, mock) = createTestConnection(configuration: config)
        connection.start()

        // Wait for multiple pings to be sent
        try await Task.sleep(for: .milliseconds(150))

        // Count ping frames
        let outbound = mock.captureOutbound()
        let pingCount = outbound.filter { data in
            guard let frame = try? decodeFrame(from: data) else { return false }
            return frame.type == .ping && !frame.flags.contains(.ack)
        }.count

        // Should have multiple pings (at least 3 with 30ms interval over 150ms)
        #expect(pingCount >= 3)

        // Respond to all pings
        for data in outbound {
            if let decoded = try? decodeFrame(from: data),
               decoded.type == .ping && !decoded.flags.contains(.ack) {
                let pongFrame = YamuxFrame.ping(opaque: decoded.length, ack: true)
                mock.injectInbound(pongFrame.encode())
            }
        }

        // Wait for processing
        try await Task.sleep(for: .milliseconds(50))

        // Connection should still be alive
        let stream = try await connection.newStream()
        #expect(stream.id > 0)

        try await connection.close()
    }
}
