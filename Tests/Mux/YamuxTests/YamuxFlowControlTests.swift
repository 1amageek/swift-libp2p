/// YamuxFlowControlTests - Flow-control correctness tests.
///
/// Covers two findings:
///  1. Receive-window leak after `closeRead()`/`localReadClosed`: discarded data
///     must still return its window (via a window update) so a peer writing to a
///     half-closed stream cannot drive the window to zero permanently.
///  2. Connection-level (session) flow control: aggregate in-flight data across
///     all streams must be bounded by a shared budget, returned via stream-0
///     window updates.
import Testing
import Foundation
import NIOCore
@testable import P2PMuxYamux
@testable import P2PCore

/// Decodes all Yamux frames present in a sequence of captured outbound writes.
private func decodeAllFrames(_ data: [Data]) -> [YamuxFrame] {
    var frames: [YamuxFrame] = []
    for chunk in data {
        var buffer = ByteBuffer(bytes: chunk)
        while let frame = ((try? YamuxFrame.decode(from: &buffer)) ?? nil) {
            frames.append(frame)
        }
    }
    return frames
}

/// Sums window-update deltas for a given stream ID.
private func totalWindowReturned(_ frames: [YamuxFrame], streamID: UInt32) -> UInt32 {
    var total: UInt32 = 0
    for frame in frames where frame.type == .windowUpdate && frame.streamID == streamID {
        total &+= frame.length
    }
    return total
}

@Suite("Yamux Flow Control Tests", .serialized)
struct YamuxFlowControlTests {

    static let testConfiguration = YamuxConfiguration(enableKeepAlive: false)

    func makeConnection(
        configuration: YamuxConfiguration = testConfiguration
    ) -> (YamuxConnection, MockSecuredConnection) {
        let mock = MockSecuredConnection()
        let connection = YamuxConnection(
            underlying: mock,
            localPeer: mock.localPeer,
            remotePeer: mock.remotePeer,
            isInitiator: true,
            configuration: configuration
        )
        return (connection, mock)
    }

    // MARK: - Finding 1: Half-close window leak

    @Test("Data discarded after closeRead returns the receive window")
    func discardedDataReturnsWindow() async throws {
        // Small per-stream window so the math is easy to assert.
        let windowSize: UInt32 = 1024
        let config = YamuxConfiguration(
            initialWindowSize: windowSize,
            enableKeepAlive: false,
            enableWindowAutoTuning: false
        )
        let (connection, mock) = makeConnection(configuration: config)
        connection.start()
        let stream = YamuxStream(id: 1, connection: connection, initialWindowSize: windowSize)

        // Close the read side: subsequent inbound data must be discarded BUT the
        // window must be returned, not silently absorbed.
        try await stream.closeRead()
        mock.clearOutbound()

        // Peer keeps writing to the half-closed stream.
        let chunk = ByteBuffer(bytes: Data(repeating: 0xAB, count: 256))
        let accepted = stream.dataReceived(chunk)
        #expect(accepted == true) // accepted (and discarded), not a protocol violation

        // Give the detached window-update task time to send.
        try await Task.sleep(for: .milliseconds(100))

        let frames = decodeAllFrames(mock.captureOutbound())
        let windowUpdate = frames.first {
            $0.type == .windowUpdate && $0.streamID == 1 && $0.length == 256
        }
        #expect(windowUpdate != nil, "Discarded data must return its 256-byte window via a window update")
    }

    @Test("Repeated writes to half-closed stream do not stall the window")
    func halfClosedStreamWindowNeverDrains() async throws {
        let windowSize: UInt32 = 512
        let config = YamuxConfiguration(
            initialWindowSize: windowSize,
            enableKeepAlive: false,
            enableWindowAutoTuning: false
        )
        let (connection, mock) = makeConnection(configuration: config)
        connection.start()
        let stream = YamuxStream(id: 1, connection: connection, initialWindowSize: windowSize)

        try await stream.closeRead()

        // Write more total bytes than a single window across many frames. If the
        // window were leaked, the peer's window would hit zero. Each frame must
        // be accepted (discarded) and its window returned.
        for _ in 0..<10 {
            let chunk = ByteBuffer(bytes: Data(repeating: 0x01, count: 256))
            let accepted = stream.dataReceived(chunk)
            #expect(accepted == true)
        }

        try await Task.sleep(for: .milliseconds(150))

        // Sum of returned window must cover everything discarded (10 * 256).
        let frames = decodeAllFrames(mock.captureOutbound())
        let returned = totalWindowReturned(frames, streamID: 1)
        #expect(returned >= 2560, "All discarded bytes (2560) must be returned via window updates; got \(returned)")
    }

    @Test("closeRead returns buffered-but-unread window")
    func closeReadReturnsBufferedWindow() async throws {
        let windowSize: UInt32 = 4096
        let config = YamuxConfiguration(
            initialWindowSize: windowSize,
            enableKeepAlive: false,
            enableWindowAutoTuning: false
        )
        let (connection, mock) = makeConnection(configuration: config)
        connection.start()
        let stream = YamuxStream(id: 1, connection: connection, initialWindowSize: windowSize)

        // Receive data that sits in the buffer (no reader consumes it).
        let buffered = ByteBuffer(bytes: Data(repeating: 0x02, count: 1000))
        #expect(stream.dataReceived(buffered) == true)
        mock.clearOutbound()

        // closeRead clears the buffer and must return the outstanding window.
        try await stream.closeRead()
        try await Task.sleep(for: .milliseconds(100))

        let frames = decodeAllFrames(mock.captureOutbound())
        let returned = totalWindowReturned(frames, streamID: 1)
        #expect(returned >= 1000, "closeRead must return the 1000 buffered bytes of window; got \(returned)")
    }

    // MARK: - Finding 2: Connection-level flow control

    @Test("Connection window is enforced across many streams")
    func connectionWindowEnforcedAcrossStreams() async throws {
        // Connection budget smaller than (#streams * per-stream window) so the
        // aggregate cap is the binding constraint, not the per-stream window.
        let perStreamWindow: UInt32 = 64 * 1024
        let connectionBudget: UInt32 = 128 * 1024 // only 2 full per-stream windows
        let config = YamuxConfiguration(
            initialWindowSize: perStreamWindow,
            enableKeepAlive: false,
            enableWindowAutoTuning: false,
            connectionReceiveWindow: connectionBudget
        )
        let (connection, mock) = makeConnection(configuration: config)
        connection.start()

        // Open several inbound streams via SYN (responder parity = even, but we
        // are initiator so remote streams are even).
        let streamCount: UInt32 = 4
        for i in 0..<streamCount {
            let sid = (i + 1) * 2 // 2, 4, 6, 8
            let syn = YamuxFrame(type: .data, flags: .syn, streamID: sid, length: 0, data: nil)
            mock.injectInbound(syn.encode())
        }
        try await Task.sleep(for: .milliseconds(100))

        // Each stream sends a full per-stream window of data. The first two
        // exhaust the 128KB connection budget; the remaining frames exceed it
        // and must tear the connection down (no reader is draining the budget).
        for i in 0..<streamCount {
            let sid = (i + 1) * 2
            let payload = ByteBuffer(bytes: Data(repeating: 0xCD, count: Int(perStreamWindow)))
            let dataFrame = YamuxFrame.data(streamID: sid, data: payload)
            mock.injectInbound(dataFrame.encode())
        }
        try await Task.sleep(for: .milliseconds(200))

        // Aggregate exceeded the connection budget → connection torn down.
        // After an abrupt shutdown the connection is marked closed, so opening a
        // new stream must fail with connectionClosed.
        await #expect(throws: YamuxError.self) {
            _ = try await connection.newStream()
        }
    }

    @Test("Connection window is returned as streams consume data")
    func connectionWindowReturnedOnConsume() async throws {
        // Per-stream window == connection budget so one data frame can fill the
        // connection budget without tripping the per-stream window violation.
        let budget: UInt32 = 64 * 1024
        let config = YamuxConfiguration(
            initialWindowSize: budget,
            enableKeepAlive: false,
            enableWindowAutoTuning: false,
            connectionReceiveWindow: budget
        )
        let (connection, mock) = makeConnection(configuration: config)
        connection.start()

        // Register the accepter BEFORE the SYN so the inbound stream is routed
        // directly to it (avoids the inbound buffer / acceptStream split).
        let sid: UInt32 = 2
        let acceptTask = Task { try await connection.acceptStream() }
        try await Task.sleep(for: .milliseconds(50))

        let syn = YamuxFrame(type: .data, flags: .syn, streamID: sid, length: 0, data: nil)
        mock.injectInbound(syn.encode())
        let acceptedStream = try await acceptTask.value

        // Fill the entire connection budget on this stream.
        let payload = ByteBuffer(bytes: Data(repeating: 0xEE, count: Int(budget)))
        let dataFrame = YamuxFrame.data(streamID: sid, data: payload)
        mock.injectInbound(dataFrame.encode())
        try await Task.sleep(for: .milliseconds(100))
        mock.clearOutbound()

        // Draining the stream consumes 100% of the connection budget, which
        // crosses the half-window threshold and must return a stream-0
        // (session) window update.
        _ = try await acceptedStream.read()
        try await Task.sleep(for: .milliseconds(150))

        let frames = decodeAllFrames(mock.captureOutbound())
        var connectionWindowUpdate = false
        for frame in frames where frame.type == .windowUpdate && frame.streamID == 0 && frame.length > 0 {
            connectionWindowUpdate = true
        }
        #expect(connectionWindowUpdate,
                "Consuming data must return the connection budget via a stream-0 window update")
    }
}
