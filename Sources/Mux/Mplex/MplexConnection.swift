/// MplexConnection - MuxedConnection implementation for Mplex
import Foundation
import P2PCore
import P2PMux
import Synchronization

/// Actor for serializing frame writes to the underlying connection.
///
/// This ensures that concurrent writes from multiple streams don't interleave
/// and corrupt the frame boundary on the wire.
private actor MplexFrameWriter {
    private let connection: any SecuredConnection

    init(connection: any SecuredConnection) {
        self.connection = connection
    }

    func write(_ data: Data) async throws {
        try await connection.write(data)
    }
}

/// Internal state for MplexConnection.
private struct MplexConnectionState: Sendable {
    var streams: [UInt64: MplexStream] = [:]
    var nextStreamID: UInt64
    var pendingAccepts: [CheckedContinuation<MuxedStream, Error>] = []
    var isClosed = false
    var isStarted = false
    var readBuffer = Data()
    /// Offset into readBuffer for the next unprocessed byte
    var readBufferOffset = 0
    var inboundContinuation: AsyncStream<MuxedStream>.Continuation?

    init(isInitiator: Bool) {
        // Initiator uses odd IDs, responder uses even IDs
        self.nextStreamID = isInitiator ? 1 : 2
    }

    /// Returns a slice of the unprocessed portion of the read buffer
    var unprocessedBuffer: Data {
        readBuffer[readBufferOffset...]
    }

    /// Advances the read offset and compacts the buffer if needed
    mutating func advanceReadBuffer(by bytesRead: Int) {
        readBufferOffset += bytesRead
        // Compact when consumed portion exceeds threshold
        if readBufferOffset > mplexReadBufferCompactThreshold {
            readBuffer = Data(readBuffer[readBufferOffset...])
            readBufferOffset = 0
        }
    }
}

/// A multiplexed connection using the Mplex protocol.
public final class MplexConnection: MuxedConnection, Sendable {

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
    private let configuration: MplexConfiguration
    private let state: Mutex<MplexConnectionState>
    /// Serializes frame writes to prevent interleaving
    private let frameWriter: MplexFrameWriter

    public let inboundStreams: AsyncStream<MuxedStream>

    private let readTask: Mutex<Task<Void, Never>?>

    init(
        underlying: any SecuredConnection,
        localPeer: PeerID,
        remotePeer: PeerID,
        isInitiator: Bool,
        configuration: MplexConfiguration = .default
    ) {
        self.underlying = underlying
        self.localPeer = localPeer
        self.remotePeer = remotePeer
        self.isInitiator = isInitiator
        self.configuration = configuration
        self.frameWriter = MplexFrameWriter(connection: underlying)

        var initialState = MplexConnectionState(isInitiator: isInitiator)

        // Create bounded AsyncStream for inbound streams
        let (inboundStream, inboundContinuation) = AsyncStream<MuxedStream>.makeStream(
            bufferingPolicy: .bufferingOldest(configuration.maxPendingInboundStreams)
        )
        self.inboundStreams = inboundStream
        initialState.inboundContinuation = inboundContinuation

        self.state = Mutex(initialState)
        self.readTask = Mutex(nil)
    }

    /// Starts the read loop. Must be called after init.
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
    }

    public func newStream() async throws -> MuxedStream {
        // Result type to capture both value and potential error from lock
        enum StreamIDResult {
            case success(UInt64)
            case closed
            case exhausted
        }

        let result: StreamIDResult = state.withLock { state in
            if state.isClosed {
                return .closed
            }

            let id = state.nextStreamID

            // Check for stream ID exhaustion
            let (newID, overflow) = id.addingReportingOverflow(2)
            if overflow {
                return .exhausted
            }

            state.nextStreamID = newID
            return .success(id)
        }

        let streamID: UInt64
        switch result {
        case .success(let id):
            streamID = id
        case .closed:
            throw MplexError.connectionClosed
        case .exhausted:
            throw MplexError.streamIDExhausted
        }

        // We initiate this stream
        let stream = MplexStream(id: streamID, connection: self, isInitiator: true)
        state.withLock { state in
            state.streams[streamID] = stream
        }

        // Send NewStream frame - clean up on failure
        do {
            let frame = MplexFrame.newStream(id: streamID)
            try await sendFrame(frame)
        } catch {
            state.withLock { state in
                _ = state.streams.removeValue(forKey: streamID)
            }
            throw error
        }

        return stream
    }

    public func acceptStream() async throws -> MuxedStream {
        try await withCheckedThrowingContinuation { continuation in
            state.withLock { state in
                if state.isClosed {
                    continuation.resume(throwing: MplexError.connectionClosed)
                    return
                }
                state.pendingAccepts.append(continuation)
            }
        }
    }

    public func close() async throws {
        // Atomically capture state
        guard let capture = captureForShutdown() else {
            return
        }

        // Cancel read task
        readTask.withLock { $0?.cancel() }

        // Notify continuations
        capture.notifyContinuations(error: MplexError.connectionClosed)

        // Close all streams gracefully
        await capture.closeAllStreamsGracefully()

        try await underlying.close()
    }

    // MARK: - Internal

    func sendFrame(_ frame: MplexFrame) async throws {
        let isClosed = state.withLock { state in state.isClosed }
        if isClosed {
            throw MplexError.connectionClosed
        }
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
                let data = try await underlying.read()

                // Empty read indicates connection closed
                if data.isEmpty {
                    throw MplexError.connectionClosed
                }

                // Append data and check buffer size limit
                let bufferOverflow = state.withLock { state -> Bool in
                    state.readBuffer.append(data)
                    return state.readBuffer.count > configuration.maxReadBufferSize
                }

                if bufferOverflow {
                    throw MplexError.readBufferOverflow
                }

                // Process all complete frames
                while true {
                    let frameResult: (frame: MplexFrame, bytesConsumed: Int)? = try state.withLock { state in
                        try MplexFrame.decode(from: state.unprocessedBuffer)
                    }
                    guard let (frame, bytesConsumed) = frameResult else { break }
                    state.withLock { state in
                        state.advanceReadBuffer(by: bytesConsumed)
                    }
                    try await handleFrame(frame)
                }
            }
        } catch {
            // Connection closed or error - abrupt shutdown
            let mplexError = (error as? MplexError) ?? .connectionClosed
            abruptShutdown(error: mplexError)
        }
    }

    private func handleFrame(_ frame: MplexFrame) async throws {
        switch frame.flag {
        case .newStream:
            try await handleNewStream(frame)

        case .messageReceiver, .messageInitiator:
            handleMessage(frame)

        case .closeReceiver, .closeInitiator:
            handleClose(frame)

        case .resetReceiver, .resetInitiator:
            handleReset(frame)
        }
    }

    private func handleNewStream(_ frame: MplexFrame) async throws {
        let streamID = frame.streamID

        // Validate stream ID parity:
        // - We're initiator -> expect even IDs from responder
        // - We're responder -> expect odd IDs from initiator
        let isValidStreamID: Bool
        if streamID == 0 {
            isValidStreamID = false
        } else if isInitiator {
            // We're initiator, remote is responder, expect even IDs
            isValidStreamID = streamID % 2 == 0
        } else {
            // We're responder, remote is initiator, expect odd IDs
            isValidStreamID = streamID % 2 == 1
        }

        if !isValidStreamID {
            // Protocol violation
            let rstFrame = MplexFrame.reset(id: streamID, isInitiator: false)
            try? await sendFrame(rstFrame)
            return
        }

        // Check, create, and insert stream atomically
        enum SynResult {
            case accept(MplexStream)
            case rejectReuse
            case rejectLimit
        }

        let result: SynResult = state.withLock { state -> SynResult in
            // Check if stream ID already exists
            if state.streams[streamID] != nil {
                return .rejectReuse
            }

            // Check stream count limit
            if state.streams.count >= configuration.maxConcurrentStreams {
                return .rejectLimit
            }

            // Remote initiated this stream, so we are not the initiator
            let stream = MplexStream(id: streamID, connection: self, isInitiator: false)
            state.streams[streamID] = stream
            return .accept(stream)
        }

        // Handle rejection cases
        let stream: MplexStream
        switch result {
        case .rejectReuse:
            let rstFrame = MplexFrame.reset(id: streamID, isInitiator: false)
            try? await sendFrame(rstFrame)
            return

        case .rejectLimit:
            let rstFrame = MplexFrame.reset(id: streamID, isInitiator: false)
            try? await sendFrame(rstFrame)
            return

        case .accept(let acceptedStream):
            stream = acceptedStream
        }

        // Deliver to waiting accepter or buffer
        enum DeliveryResult {
            case directDelivery(CheckedContinuation<MuxedStream, Error>, MplexStream)
            case bufferDelivery(AsyncStream<MuxedStream>.Continuation?, MplexStream)
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
            cont.resume(returning: deliveredStream)

        case .bufferDelivery(let continuation, let deliveredStream):
            guard let continuation = continuation else {
                // No consumer - reject stream
                let rstFrame = MplexFrame.reset(id: streamID, isInitiator: false)
                try? await sendFrame(rstFrame)
                state.withLock { _ = $0.streams.removeValue(forKey: streamID) }
                return
            }

            let yieldResult = continuation.yield(deliveredStream)

            switch yieldResult {
            case .enqueued:
                break // Success

            case .dropped:
                // Buffer full - reject
                let rstFrame = MplexFrame.reset(id: streamID, isInitiator: false)
                try? await sendFrame(rstFrame)
                state.withLock { _ = $0.streams.removeValue(forKey: streamID) }

            case .terminated:
                state.withLock { _ = $0.streams.removeValue(forKey: streamID) }

            @unknown default:
                break
            }
        }
    }

    private func handleMessage(_ frame: MplexFrame) {
        let streamID = frame.streamID
        let stream = state.withLock { state in state.streams[streamID] }

        if let stream = stream {
            stream.dataReceived(frame.data)
        }
        // Ignore data for unknown streams (they may have been closed)
    }

    private func handleClose(_ frame: MplexFrame) {
        let streamID = frame.streamID
        let stream = state.withLock { state in state.streams[streamID] }
        stream?.remoteClose()
    }

    private func handleReset(_ frame: MplexFrame) {
        let streamID = frame.streamID
        let stream = state.withLock { state -> MplexStream? in
            let s = state.streams[streamID]
            _ = state.streams.removeValue(forKey: streamID)
            return s
        }
        stream?.remoteReset()
    }

    // MARK: - Shutdown Infrastructure

    /// Captured state during shutdown
    private struct ShutdownCapture {
        let streams: [MplexStream]
        let inboundContinuation: AsyncStream<MuxedStream>.Continuation?
        let pendingAccepts: [CheckedContinuation<MuxedStream, Error>]

        func notifyContinuations(error: Error) {
            inboundContinuation?.finish()
            for continuation in pendingAccepts {
                continuation.resume(throwing: error)
            }
        }

        func resetAllStreams() {
            for stream in streams {
                stream.remoteReset()
            }
        }

        func closeAllStreamsGracefully() async {
            for stream in streams {
                try? await stream.close()
            }
        }
    }

    /// Atomically captures and clears shutdown-related state.
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

            return capture
        }
    }

    /// Abrupt shutdown for error conditions.
    private func abruptShutdown(error: MplexError) {
        guard let capture = captureForShutdown() else { return }

        capture.notifyContinuations(error: error)
        capture.resetAllStreams()
    }
}
