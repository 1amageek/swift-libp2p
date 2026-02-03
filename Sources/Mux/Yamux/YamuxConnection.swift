/// YamuxConnection - MuxedConnection implementation for Yamux
import Foundation
import NIOCore
import P2PCore
import P2PMux
import Synchronization

/// Threshold for compacting the read buffer (64KB)
private let readBufferCompactThreshold = 64 * 1024

/// Actor for serializing frame writes to the underlying connection.
///
/// This ensures that concurrent writes from multiple streams don't interleave
/// and corrupt the frame boundary on the wire.
private actor FrameWriter {
    private let connection: any SecuredConnection

    init(connection: any SecuredConnection) {
        self.connection = connection
    }

    func write(_ data: ByteBuffer) async throws {
        try await connection.write(data)
    }
}

/// Internal state for YamuxConnection.
private struct YamuxConnectionState: Sendable {
    var streams: [UInt64: YamuxStream] = [:]
    var nextStreamID: UInt32
    var pendingAccepts: [CheckedContinuation<MuxedStream, Error>] = []
    var isClosed = false
    var isStarted = false
    /// GoAway received - reject new streams but allow existing to continue
    var isGoAwayReceived = false
    var readBuffer = ByteBuffer()
    var inboundContinuation: AsyncStream<MuxedStream>.Continuation?
    /// Pending keep-alive pings awaiting pong response. Maps ping ID to send time.
    var pendingPings: [UInt32: ContinuousClock.Instant] = [:]
    /// Next ping ID to use for keep-alive.
    var nextPingID: UInt32 = 1

    init(isInitiator: Bool) {
        // Initiator uses odd IDs, responder uses even IDs
        self.nextStreamID = isInitiator ? 1 : 2
    }

    /// Compacts the read buffer if consumed portion exceeds threshold.
    mutating func compactReadBufferIfNeeded() {
        if readBuffer.readerIndex > readBufferCompactThreshold {
            readBuffer.discardReadBytes()
        }
    }
}

/// A multiplexed connection using the Yamux protocol.
public final class YamuxConnection: MuxedConnection, Sendable {

    public let localPeer: PeerID
    public let remotePeer: PeerID

    public var localAddress: Multiaddr? {
        underlying.localAddress
    }

    public var remoteAddress: Multiaddr {
        underlying.remoteAddress
    }

    private let underlying: any SecuredConnection
    private let isInitiator: Bool
    private let configuration: YamuxConfiguration
    private let state: Mutex<YamuxConnectionState>
    /// Serializes frame writes to prevent interleaving
    private let frameWriter: FrameWriter

    public let inboundStreams: AsyncStream<MuxedStream>

    private let readTask: Mutex<Task<Void, Never>?>
    private let keepAliveTask: Mutex<Task<Void, Never>?>

    init(
        underlying: any SecuredConnection,
        localPeer: PeerID,
        remotePeer: PeerID,
        isInitiator: Bool,
        configuration: YamuxConfiguration = .default
    ) {
        self.underlying = underlying
        self.localPeer = localPeer
        self.remotePeer = remotePeer
        self.isInitiator = isInitiator
        self.configuration = configuration
        self.frameWriter = FrameWriter(connection: underlying)

        var initialState = YamuxConnectionState(isInitiator: isInitiator)

        // Create bounded AsyncStream for inbound streams with backpressure support
        let (inboundStream, inboundContinuation) = AsyncStream<MuxedStream>.makeStream(
            bufferingPolicy: .bufferingOldest(configuration.maxPendingInboundStreams)
        )
        self.inboundStreams = inboundStream
        initialState.inboundContinuation = inboundContinuation

        self.state = Mutex(initialState)
        self.readTask = Mutex(nil)
        self.keepAliveTask = Mutex(nil)
    }

    /// Starts the read loop and keep-alive timer. Must be called after init.
    /// This method is idempotent - multiple calls have no effect.
    func start() {
        let shouldStart = state.withLock { state -> Bool in
            if state.isStarted || state.isClosed {
                return false
            }
            state.isStarted = true
            return true
        }

        guard shouldStart else { return }

        // Start read loop
        let task: Task<Void, Never> = Task { [weak self] in
            await self?.readLoop()
        }
        readTask.withLock { $0 = task }

        // Start keep-alive loop if enabled
        if configuration.enableKeepAlive {
            let keepAlive: Task<Void, Never> = Task { [weak self] in
                await self?.keepAliveLoop()
            }
            keepAliveTask.withLock { $0 = keepAlive }
        }
    }

    public func newStream() async throws -> MuxedStream {
        // Result type to capture both value and potential error from lock
        enum StreamIDResult {
            case success(UInt32)
            case closed
            case goAwayReceived
            case exhausted
        }

        let result: StreamIDResult = state.withLock { state in
            if state.isClosed {
                return .closed
            }
            if state.isGoAwayReceived {
                return .goAwayReceived
            }

            let id = state.nextStreamID

            // Check for stream ID exhaustion with overflow detection
            let (newID, overflow) = id.addingReportingOverflow(2)
            if overflow {
                return .exhausted
            }

            state.nextStreamID = newID
            return .success(id)
        }

        let streamID: UInt32
        switch result {
        case .success(let id):
            streamID = id
        case .closed, .goAwayReceived:
            throw YamuxError.connectionClosed
        case .exhausted:
            throw YamuxError.streamIDExhausted
        }

        let stream = YamuxStream(id: UInt64(streamID), connection: self, initialWindowSize: configuration.initialWindowSize)
        state.withLock { state in
            state.streams[UInt64(streamID)] = stream
        }

        // Send SYN frame - clean up on failure to prevent leak
        do {
            let frame = YamuxFrame(
                type: .data,
                flags: .syn,
                streamID: streamID,
                length: 0,
                data: nil
            )
            try await sendFrame(frame)
        } catch {
            // Remove stream from map if SYN send failed
            state.withLock { state in
                _ = state.streams.removeValue(forKey: UInt64(streamID))
            }
            throw error
        }

        return stream
    }

    public func acceptStream() async throws -> MuxedStream {
        try await withCheckedThrowingContinuation { continuation in
            state.withLock { state in
                if state.isClosed {
                    continuation.resume(throwing: YamuxError.connectionClosed)
                    return
                }
                state.pendingAccepts.append(continuation)
            }
        }
    }

    public func close() async throws {
        // Atomically capture state - returns nil if already closed
        guard let capture = captureForShutdown() else {
            return
        }

        // Cancel background tasks
        readTask.withLock { $0?.cancel() }
        keepAliveTask.withLock { $0?.cancel() }

        // Notify continuations
        capture.notifyContinuations(error: YamuxError.connectionClosed)

        // Send GoAway (best effort)
        let frame = YamuxFrame.goAway(reason: .normal)
        try? await sendFrame(frame)

        // Close all streams gracefully (sends FIN frames)
        await capture.closeAllStreamsGracefully()

        try await underlying.close()
    }

    // MARK: - Internal

    func sendFrame(_ frame: YamuxFrame) async throws {
        let isClosed = state.withLock { state in state.isClosed }
        if isClosed && frame.type != .goAway {
            throw YamuxError.connectionClosed
        }
        // Use frameWriter actor to serialize all writes and prevent interleaving
        try await frameWriter.write(frame.encode())
    }

    func removeStream(_ id: UInt64) {
        state.withLock { state in
            _ = state.streams.removeValue(forKey: id)
        }
    }

    // MARK: - Private

    private func readLoop() async {
        do {
            while !Task.isCancelled {
                var data = try await underlying.read()

                // Empty read indicates connection closed/EOF
                if data.readableBytes == 0 {
                    throw YamuxError.connectionClosed
                }

                // Append data and check buffer size limit (DoS protection)
                let bufferOverflow = state.withLock { state -> Bool in
                    state.readBuffer.writeBuffer(&data)
                    return state.readBuffer.readableBytes > yamuxMaxReadBufferSize
                }

                if bufferOverflow {
                    throw YamuxError.readBufferOverflow
                }

                // Process all complete frames (decode directly from ByteBuffer - zero-copy)
                while true {
                    let frame: YamuxFrame? = try state.withLock { state in
                        let frame = try YamuxFrame.decode(from: &state.readBuffer)
                        if frame != nil {
                            state.compactReadBufferIfNeeded()
                        }
                        return frame
                    }
                    guard let frame else { break }
                    try await handleFrame(frame)
                }
            }
        } catch {
            // Connection closed or error - abrupt shutdown
            let yamuxError = (error as? YamuxError) ?? .connectionClosed
            abruptShutdown(error: yamuxError)
        }
    }

    private func handleFrame(_ frame: YamuxFrame) async throws {
        switch frame.type {
        case .data:
            try await handleDataFrame(frame)
        case .windowUpdate:
            handleWindowUpdate(frame)
        case .ping:
            try await handlePing(frame)
        case .goAway:
            try handleGoAway(frame)
        }
    }

    private func handleDataFrame(_ frame: YamuxFrame) async throws {
        let streamID = UInt64(frame.streamID)

        if frame.flags.contains(.syn) {
            // Validate stream ID per Yamux spec:
            // - Stream ID 0 is invalid
            // - Initiator uses odd IDs, responder uses even IDs
            // - We receive streams from the remote, so expect opposite parity
            let isValidStreamID: Bool
            if frame.streamID == 0 {
                isValidStreamID = false
            } else if isInitiator {
                // We're initiator, remote is responder, expect even IDs
                isValidStreamID = frame.streamID % 2 == 0
            } else {
                // We're responder, remote is initiator, expect odd IDs
                isValidStreamID = frame.streamID % 2 == 1
            }

            if !isValidStreamID {
                // Protocol violation: invalid stream ID
                let rstFrame = YamuxFrame(
                    type: .data,
                    flags: .rst,
                    streamID: frame.streamID,
                    length: 0,
                    data: nil
                )
                try? await sendFrame(rstFrame)
                return
            }

            // Check, create, and insert stream atomically to prevent TOCTOU race
            enum SynResult {
                case accept(YamuxStream)
                case rejectReuse
                case rejectLimit
                case rejectGoAway
            }

            let result: SynResult = state.withLock { state -> SynResult in
                // Reject new streams after GoAway received
                if state.isGoAwayReceived {
                    return .rejectGoAway
                }

                // Check if stream ID already exists (reuse attack)
                if state.streams[streamID] != nil {
                    return .rejectReuse
                }

                // Check stream count limit
                if state.streams.count >= configuration.maxConcurrentStreams {
                    return .rejectLimit
                }

                // Create and insert stream atomically
                let stream = YamuxStream(id: streamID, connection: self, initialWindowSize: configuration.initialWindowSize)
                state.streams[streamID] = stream
                return .accept(stream)
            }

            // Handle rejection cases
            let stream: YamuxStream
            switch result {
            case .rejectGoAway:
                // GoAway received - reject new streams
                let rstFrame = YamuxFrame(
                    type: .data,
                    flags: .rst,
                    streamID: frame.streamID,
                    length: 0,
                    data: nil
                )
                try? await sendFrame(rstFrame)
                return

            case .rejectReuse:
                // Protocol violation: stream ID reuse
                let rstFrame = YamuxFrame(
                    type: .data,
                    flags: .rst,
                    streamID: frame.streamID,
                    length: 0,
                    data: nil
                )
                try? await sendFrame(rstFrame)
                return

            case .rejectLimit:
                // Stream limit exceeded - reject with RST
                let rstFrame = YamuxFrame(
                    type: .data,
                    flags: .rst,
                    streamID: frame.streamID,
                    length: 0,
                    data: nil
                )
                try? await sendFrame(rstFrame)
                return

            case .accept(let acceptedStream):
                stream = acceptedStream
            }

            // Determine delivery mechanism and deliver with proper backpressure
            // ACK is sent AFTER successful delivery to ensure protocol consistency
            enum DeliveryResult {
                case directDelivery(CheckedContinuation<MuxedStream, Error>, YamuxStream)
                case bufferDelivery(AsyncStream<MuxedStream>.Continuation?, YamuxStream)
            }

            let deliveryResult = state.withLock { state -> DeliveryResult in
                if !state.pendingAccepts.isEmpty {
                    let cont = state.pendingAccepts.removeFirst()
                    return .directDelivery(cont, stream)
                }
                return .bufferDelivery(state.inboundContinuation, stream)
            }

            switch deliveryResult {
            case .directDelivery(let cont, let deliveredStream):
                // Direct delivery to waiting accepter
                // ACK must be sent first - if it fails, resume continuation with error
                let ackFrame = YamuxFrame(
                    type: .data,
                    flags: .ack,
                    streamID: frame.streamID,
                    length: 0,
                    data: nil
                )
                do {
                    try await sendFrame(ackFrame)
                    // ACK succeeded - deliver stream to waiting accepter
                    cont.resume(returning: deliveredStream)
                } catch {
                    // ACK failed - clean up stream and resume with error
                    state.withLock { _ = $0.streams.removeValue(forKey: streamID) }
                    cont.resume(throwing: error)
                }

            case .bufferDelivery(let continuation, let deliveredStream):
                guard let continuation = continuation else {
                    // No consumer available - reject stream
                    let rstFrame = YamuxFrame(
                        type: .data,
                        flags: .rst,
                        streamID: frame.streamID,
                        length: 0,
                        data: nil
                    )
                    try? await sendFrame(rstFrame)
                    state.withLock { _ = $0.streams.removeValue(forKey: streamID) }
                    return
                }

                // Try to buffer - check result for backpressure
                let yieldResult = continuation.yield(deliveredStream)

                switch yieldResult {
                case .enqueued:
                    // Success - send ACK
                    let ackFrame = YamuxFrame(
                        type: .data,
                        flags: .ack,
                        streamID: frame.streamID,
                        length: 0,
                        data: nil
                    )
                    try await sendFrame(ackFrame)

                case .dropped:
                    // Buffer full - reject with RST (proper backpressure)
                    let rstFrame = YamuxFrame(
                        type: .data,
                        flags: .rst,
                        streamID: frame.streamID,
                        length: 0,
                        data: nil
                    )
                    try? await sendFrame(rstFrame)
                    state.withLock { _ = $0.streams.removeValue(forKey: streamID) }

                case .terminated:
                    // Connection closing - clean up
                    state.withLock { _ = $0.streams.removeValue(forKey: streamID) }

                @unknown default:
                    break
                }
            }
        }

        // Handle data
        if let data = frame.data, data.readableBytes > 0 {
            let stream = state.withLock { state in state.streams[streamID] }
            if let stream = stream {
                let accepted = stream.dataReceived(data)
                if !accepted {
                    // Protocol violation: data exceeded receive window
                    // Send RST frame and remove stream
                    let rstFrame = YamuxFrame(
                        type: .data,
                        flags: .rst,
                        streamID: frame.streamID,
                        length: 0,
                        data: nil
                    )
                    try? await sendFrame(rstFrame)
                    state.withLock { state in
                        _ = state.streams.removeValue(forKey: streamID)
                    }
                }
            } else if !frame.flags.contains(.syn) {
                // Data for unknown stream (not a new stream) - send RST
                let rstFrame = YamuxFrame(
                    type: .data,
                    flags: .rst,
                    streamID: frame.streamID,
                    length: 0,
                    data: nil
                )
                try? await sendFrame(rstFrame)
            }
        }

        // Handle flags atomically to prevent race conditions
        let hasFin = frame.flags.contains(.fin)
        let hasRst = frame.flags.contains(.rst)

        if hasFin || hasRst {
            // Get stream and optionally remove in single lock
            let stream = state.withLock { state -> YamuxStream? in
                let s = state.streams[streamID]
                // RST removes the stream from the map
                if hasRst {
                    _ = state.streams.removeValue(forKey: streamID)
                }
                return s
            }

            // Apply state changes outside lock (stream handles its own synchronization)
            if let stream = stream {
                if hasRst {
                    // RST takes precedence - abrupt termination
                    stream.remoteReset()
                } else if hasFin {
                    // Graceful close
                    stream.remoteClose()
                }
            }
        }
    }

    private func handleWindowUpdate(_ frame: YamuxFrame) {
        let streamID = UInt64(frame.streamID)
        let stream = state.withLock { state in state.streams[streamID] }
        stream?.windowUpdate(delta: frame.length)
    }

    private func handlePing(_ frame: YamuxFrame) async throws {
        if frame.flags.contains(.ack) {
            // Pong response - remove from pending pings
            state.withLock { state in
                _ = state.pendingPings.removeValue(forKey: frame.length)
            }
            return
        }

        // Send pong
        let pong = YamuxFrame.ping(opaque: frame.length, ack: true)
        try await sendFrame(pong)
    }

    private func handleGoAway(_ frame: YamuxFrame) throws {
        // GoAway signals session termination.
        // Reset all existing streams and reject new ones.
        abruptShutdown(error: .connectionClosed)
        // Throw to exit the readLoop (prevents blocking on underlying.read())
        throw YamuxError.connectionClosed
    }

    // MARK: - Shutdown Infrastructure

    /// Captured state during shutdown, processed outside the lock.
    private struct ShutdownCapture {
        let streams: [YamuxStream]
        let inboundContinuation: AsyncStream<MuxedStream>.Continuation?
        let pendingAccepts: [CheckedContinuation<MuxedStream, Error>]

        /// Finishes the inbound stream and resumes pending accepts with error.
        func notifyContinuations(error: Error) {
            inboundContinuation?.finish()
            for continuation in pendingAccepts {
                continuation.resume(throwing: error)
            }
        }

        /// Resets all streams (for abrupt/error shutdown).
        func resetAllStreams() {
            for stream in streams {
                stream.remoteReset()
            }
        }

        /// Closes all streams gracefully (for user-initiated close).
        func closeAllStreamsGracefully() async {
            for stream in streams {
                try? await stream.close()
            }
        }
    }

    /// Atomically captures and clears shutdown-related state.
    ///
    /// Returns `nil` if already closed (idempotent).
    /// Call this once, then process the captured state outside the lock.
    private func captureForShutdown() -> ShutdownCapture? {
        state.withLock { state in
            guard !state.isClosed else { return nil }

            state.isClosed = true

            let capture = ShutdownCapture(
                streams: Array(state.streams.values),
                inboundContinuation: state.inboundContinuation,
                pendingAccepts: state.pendingAccepts
            )

            state.streams.removeAll()
            state.inboundContinuation = nil
            state.pendingAccepts.removeAll()
            state.pendingPings.removeAll()

            return capture
        }
    }

    /// Abrupt shutdown for error conditions (GoAway, read error, timeout).
    ///
    /// Resets all streams immediately without sending FIN.
    private func abruptShutdown(error: YamuxError) {
        guard let capture = captureForShutdown() else { return }

        capture.notifyContinuations(error: error)
        capture.resetAllStreams()
    }

    // MARK: - Keep-Alive

    private func keepAliveLoop() async {
        let interval = configuration.keepAliveInterval
        let timeout = configuration.keepAliveTimeout

        while !Task.isCancelled {
            // Wait for the interval
            do {
                try await Task.sleep(for: interval)
            } catch {
                // Task cancelled
                return
            }

            // Check if connection is closed
            let isClosed = state.withLock { $0.isClosed }
            if isClosed { return }

            // Check for timed out pings
            if checkPingTimeout(timeout: timeout) {
                await handleKeepAliveTimeout()
                return
            }

            // Send a new ping
            await sendKeepAlivePing()
        }
    }

    private func checkPingTimeout(timeout: Duration) -> Bool {
        let now = ContinuousClock.now
        return state.withLock { state in
            for (_, sentTime) in state.pendingPings {
                if now - sentTime > timeout {
                    return true
                }
            }
            return false
        }
    }

    private func sendKeepAlivePing() async {
        let pingID = state.withLock { state -> UInt32 in
            let id = state.nextPingID
            state.nextPingID &+= 1  // Overflow wraps around
            state.pendingPings[id] = ContinuousClock.now
            return id
        }

        let frame = YamuxFrame.ping(opaque: pingID, ack: false)
        try? await sendFrame(frame)
    }

    private func handleKeepAliveTimeout() async {
        // Abrupt shutdown with timeout error
        abruptShutdown(error: .keepAliveTimeout)

        // Close underlying connection
        try? await underlying.close()
    }
}
