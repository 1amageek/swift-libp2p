/// MplexConnection - MuxedConnection implementation for Mplex
import Foundation
import NIOCore
import P2PCore
import P2PMux
import Synchronization

private let logger = Logger(label: "p2p.mux.mplex.connection")

/// Maximum number of control frames buffered by the control-frame queue.
///
/// Decouples RST sends from the read loop so a back-pressured transport cannot
/// wedge frame draining. Bounded so a peer cannot grow the queue without limit
/// by flooding frames that trigger RST responses.
private let mplexControlFrameQueueCapacity = 1024

/// Actor for serializing frame writes to the underlying connection.
///
/// This ensures that concurrent writes from multiple streams don't interleave
/// and corrupt the frame boundary on the wire.
private actor MplexFrameWriter {
    private let connection: any SecuredConnection

    init(connection: any SecuredConnection) {
        self.connection = connection
    }

    func write(_ data: ByteBuffer) async throws {
        try await connection.write(data)
    }
}

/// Composite key for Mplex stream lookup.
///
/// Mplex spec: both sides use independent counters starting at 0.
/// Direction is distinguished by message flags, not ID parity.
struct MplexStreamKey: Hashable, Sendable {
    let id: UInt64
    let initiatedLocally: Bool
}

/// Internal state for MplexConnection.
private struct MplexConnectionState: Sendable {
    var streams: [MplexStreamKey: MplexStream] = [:]
    var nextStreamID: UInt64 = 0
    /// Parked `acceptStream()` waiters, each keyed by a unique monotonic id so a
    /// specific waiter can be removed on cancellation. FIFO delivery order is
    /// preserved by appending and removing the first element.
    var pendingAccepts: [(id: UInt64, continuation: CheckedContinuation<MuxedStream, Error>)] = []
    /// Next id to assign to a parked accept waiter.
    var nextAcceptID: UInt64 = 0
    var isClosed = false
    var isStarted = false
    var readBuffer = ByteBuffer()
    var inboundContinuation: AsyncStream<MuxedStream>.Continuation?

    /// Compacts the read buffer if the consumed prefix is large enough.
    mutating func compactReadBufferIfNeeded() {
        if readBuffer.readerIndex > mplexReadBufferCompactThreshold {
            readBuffer.discardReadBytes()
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

    public var hasActiveStreams: Bool {
        state.withLock { !$0.streams.isEmpty }
    }

    /// Internal diagnostic used by tests to wait for deterministic accept parking.
    var pendingAcceptCountForTesting: Int {
        state.withLock { $0.pendingAccepts.count }
    }

    private let underlying: any SecuredConnection
    private let isInitiator: Bool
    private let configuration: MplexConfiguration
    private let state: Mutex<MplexConnectionState>
    /// Serializes frame writes to prevent interleaving
    private let frameWriter: MplexFrameWriter
    /// Decouples control-frame (RST) sends from the read loop.
    private let controlQueue: MplexControlFrameQueue

    public let inboundStreams: AsyncStream<MuxedStream>

    private let readTask: Mutex<Task<Void, Never>?>
    private let controlDrainTask: Mutex<Task<Void, Never>?>

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
        self.controlQueue = MplexControlFrameQueue(capacity: mplexControlFrameQueueCapacity)

        var initialState = MplexConnectionState()

        // Create bounded AsyncStream for inbound streams
        let (inboundStream, inboundContinuation) = AsyncStream<MuxedStream>.makeStream(
            bufferingPolicy: .bufferingOldest(configuration.maxPendingInboundStreams)
        )
        self.inboundStreams = inboundStream
        initialState.inboundContinuation = inboundContinuation

        self.state = Mutex(initialState)
        self.readTask = Mutex(nil)
        self.controlDrainTask = Mutex(nil)
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

        // Start control-frame drain loop first so the read loop can enqueue
        // control responses immediately without blocking.
        let drain: Task<Void, Never> = Task { [weak self] in
            await self?.controlDrainLoop()
        }
        controlDrainTask.withLock { $0 = drain }

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
            let (newID, overflow) = id.addingReportingOverflow(1)
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
        let key = MplexStreamKey(id: streamID, initiatedLocally: true)
        let stream = MplexStream(id: streamID, connection: self, isInitiator: true, maxReadBufferSize: configuration.maxReadBufferSizePerStream)
        state.withLock { state in
            state.streams[key] = stream
        }

        // Send NewStream frame - clean up on failure
        do {
            let frame = MplexFrame.newStream(id: streamID)
            try await sendFrame(frame)
        } catch {
            state.withLock { state in
                _ = state.streams.removeValue(forKey: key)
            }
            throw error
        }

        return stream
    }

    /// Waits for the next inbound stream.
    ///
    /// Resolution is exactly one of three mutually distinguishable outcomes:
    /// - returns a `MuxedStream` — an inbound stream was delivered to this waiter
    /// - throws `MplexError.connectionClosed` — the connection closed (clean
    ///   close or abrupt shutdown) while this call was parked
    /// - throws `CancellationError` — the awaiting task was cancelled while
    ///   parked (the connection is still open)
    ///
    /// Cancellation is reported as a distinct `CancellationError`, never as a
    /// fake stream or a spurious clean close, so the caller can tell a cancelled
    /// accept apart from a real stream and from a closed connection.
    public func acceptStream() async throws -> MuxedStream {
        let id = state.withLock { state -> UInt64 in
            let assigned = state.nextAcceptID
            state.nextAcceptID &+= 1
            return assigned
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<MuxedStream, Error>) in
                let immediateError: Error? = state.withLock { state in
                    if state.isClosed {
                        return MplexError.connectionClosed
                    }

                    state.pendingAccepts.append((id: id, continuation: continuation))

                    // Close the race where cancellation fires before or during
                    // registration. The waiter is registered first, then removed
                    // under the same lock if the task is already cancelled.
                    if Task.isCancelled {
                        if let index = state.pendingAccepts.firstIndex(where: { $0.id == id }) {
                            _ = state.pendingAccepts.remove(at: index)
                        }
                        return CancellationError()
                    }

                    return nil
                }

                if let immediateError {
                    continuation.resume(throwing: immediateError)
                }
            }
        } onCancel: {
            // Remove synchronously so `cancel()` cannot return while this waiter
            // is still eligible for inbound-stream delivery.
            self.cancelPendingAccept(id)
        }
    }

    /// Removes and fails the parked accept waiter `id` with `CancellationError`,
    /// exactly once.
    ///
    /// If the id is absent — already resumed by an incoming stream delivery or by
    /// shutdown — this is a no-op. Membership in `pendingAccepts` is the
    /// exactly-once guard: a waiter is resumed by EXACTLY ONE of
    /// {incoming-stream delivery, cancel, shutdown}, whichever first removes it
    /// by id, and the Mutex serializes them.
    private func cancelPendingAccept(_ id: UInt64) {
        let continuation: CheckedContinuation<MuxedStream, Error>? = state.withLock { state in
            guard let index = state.pendingAccepts.firstIndex(where: { $0.id == id }) else {
                return nil
            }
            return state.pendingAccepts.remove(at: index).continuation
        }
        continuation?.resume(throwing: CancellationError())
    }

    public func close() async throws {
        // Atomically capture state
        guard let capture = captureForShutdown() else {
            return
        }

        // Cancel read task
        readTask.withLock { $0?.cancel() }
        // Terminate the control-frame drain loop and cancel its task.
        controlQueue.finish()
        controlDrainTask.withLock { $0?.cancel() }

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
        var buffer = ByteBuffer()
        frame.encode(into: &buffer)
        try await frameWriter.write(buffer)
    }

    func removeStream(id: UInt64, initiatedLocally: Bool) {
        let key = MplexStreamKey(id: id, initiatedLocally: initiatedLocally)
        state.withLock { state in
            _ = state.streams.removeValue(forKey: key)
        }
    }

    // MARK: - Private

    private func readLoop() async {
        do {
            while !Task.isCancelled {
                var data = try await underlying.read()

                // Empty read indicates connection closed
                if data.readableBytes == 0 {
                    throw MplexError.connectionClosed
                }

                // Append data and check buffer size limit
                let bufferOverflow = state.withLock { state -> Bool in
                    state.readBuffer.writeBuffer(&data)
                    return state.readBuffer.readableBytes > configuration.maxReadBufferSize
                }

                if bufferOverflow {
                    throw MplexError.readBufferOverflow
                }

                // Process all complete frames
                let maxFrameSize = UInt64(configuration.maxFrameSize)
                while true {
                    let frame: MplexFrame? = try state.withLock { state in
                        let decoded = try MplexFrame.decode(from: &state.readBuffer, maxFrameSize: maxFrameSize)
                        state.compactReadBufferIfNeeded()
                        return decoded
                    }
                    guard let frame else { break }
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
        let key = MplexStreamKey(id: streamID, initiatedLocally: false)

        // Check, create, and insert stream atomically
        enum SynResult {
            case accept(MplexStream)
            case rejectReuse
            case rejectLimit
        }

        let result: SynResult = state.withLock { state -> SynResult in
            // Check if stream ID already exists (remote-initiated)
            if state.streams[key] != nil {
                return .rejectReuse
            }

            // Check stream count limit
            if state.streams.count >= configuration.maxConcurrentStreams {
                return .rejectLimit
            }

            // Remote initiated this stream, so we are not the initiator
            let stream = MplexStream(id: streamID, connection: self, isInitiator: false, maxReadBufferSize: configuration.maxReadBufferSizePerStream)
            state.streams[key] = stream
            return .accept(stream)
        }

        // Handle rejection cases
        let stream: MplexStream
        switch result {
        case .rejectReuse:
            try enqueueReset(
                streamID: streamID,
                initiatedLocally: false,
                context: "reject reused remote stream ID"
            )
            return

        case .rejectLimit:
            try enqueueReset(
                streamID: streamID,
                initiatedLocally: false,
                context: "reject stream over limit"
            )
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
                // FIFO: the oldest parked waiter receives the stream. Removing
                // it by index is the exactly-once guard against cancel/shutdown.
                let waiter = state.pendingAccepts.removeFirst()
                return .directDelivery(waiter.continuation, stream)
            }
            return .bufferDelivery(state.inboundContinuation, stream)
        }

        switch deliveryResult {
        case .directDelivery(let cont, let deliveredStream):
            cont.resume(returning: deliveredStream)

        case .bufferDelivery(let continuation, let deliveredStream):
            guard let continuation = continuation else {
                // No consumer - reject stream
                try enqueueReset(
                    streamID: streamID,
                    initiatedLocally: false,
                    context: "reject inbound stream with no continuation"
                )
                state.withLock { _ = $0.streams.removeValue(forKey: key) }
                return
            }

            let yieldResult = continuation.yield(deliveredStream)

            switch yieldResult {
            case .enqueued:
                break // Success

            case .dropped:
                // Buffer full - reject
                try enqueueReset(
                    streamID: streamID,
                    initiatedLocally: false,
                    context: "reject dropped inbound stream"
                )
                state.withLock { _ = $0.streams.removeValue(forKey: key) }

            case .terminated:
                state.withLock { _ = $0.streams.removeValue(forKey: key) }

            @unknown default:
                break
            }
        }
    }

    private func handleMessage(_ frame: MplexFrame) {
        let key = streamKeyFromFlag(frame)
        let stream = state.withLock { state in state.streams[key] }

        if let stream = stream {
            stream.dataReceived(frame.data)
        }
        // Ignore data for unknown streams (they may have been closed)
    }

    private func handleClose(_ frame: MplexFrame) {
        let key = streamKeyFromFlag(frame)
        let stream = state.withLock { state in state.streams[key] }
        stream?.remoteClose()
    }

    private func handleReset(_ frame: MplexFrame) {
        let key = streamKeyFromFlag(frame)
        let stream = state.withLock { state -> MplexStream? in
            let s = state.streams[key]
            _ = state.streams.removeValue(forKey: key)
            return s
        }
        stream?.remoteReset()
    }

    /// Derives the stream key from an incoming frame's flag.
    ///
    /// Mplex flags encode the sender's relationship to the stream:
    /// - "Initiator" flags mean the sender opened the stream → `initiatedLocally: false`
    /// - "Receiver" flags mean the receiver opened the stream → `initiatedLocally: true`
    private func streamKeyFromFlag(_ frame: MplexFrame) -> MplexStreamKey {
        let initiatedLocally: Bool
        switch frame.flag {
        case .messageInitiator, .closeInitiator, .resetInitiator:
            // Remote sent with "initiator" flag = remote opened this stream
            initiatedLocally = false
        case .messageReceiver, .closeReceiver, .resetReceiver:
            // Remote sent with "receiver" flag = local opened this stream
            initiatedLocally = true
        case .newStream:
            // New stream from remote = not locally initiated
            initiatedLocally = false
        }
        return MplexStreamKey(id: frame.streamID, initiatedLocally: initiatedLocally)
    }

    private func sendResetBestEffort(
        streamID: UInt64,
        initiatedLocally: Bool,
        context: String
    ) async {
        let rstFrame = MplexFrame.reset(id: streamID, isInitiator: initiatedLocally)
        do {
            try await sendFrame(rstFrame)
        } catch {
            logger.debug("Failed to send Mplex RST (\(context), stream=\(streamID)): \(error)")
        }
    }

    // MARK: - Control-Frame Queue

    /// Enqueues a control RST from the read loop.
    ///
    /// - Throws: `MplexError.readBufferOverflow` if the bounded control queue
    ///   is full — the read loop converts this into an abrupt shutdown rather
    ///   than silently dropping a required RST.
    private func enqueueReset(
        streamID: UInt64,
        initiatedLocally: Bool,
        context: String
    ) throws {
        let rstFrame = MplexFrame.reset(id: streamID, isInitiator: initiatedLocally)
        guard controlQueue.enqueue(rstFrame) else {
            logger.debug("Mplex control-frame queue full, tearing down connection (RST: \(context))")
            throw MplexError.readBufferOverflow
        }
    }

    /// Drains queued control frames, writing each through the FrameWriter.
    ///
    /// Runs on its own task; only this task blocks on transport back-pressure,
    /// leaving the read loop free to keep draining inbound frames.
    private func controlDrainLoop() async {
        while let frame = await controlQueue.next() {
            if Task.isCancelled { return }
            do {
                try await sendFrame(frame)
            } catch {
                logger.debug("Mplex control-frame drain send failed: \(error)")
            }
        }
    }

    // MARK: - Shutdown Infrastructure

    /// Captured state during shutdown
    private struct ShutdownCapture {
        let streams: [MplexStream]
        let inboundContinuation: AsyncStream<MuxedStream>.Continuation?
        let pendingAccepts: [(id: UInt64, continuation: CheckedContinuation<MuxedStream, Error>)]

        /// Finishes the inbound stream and resumes pending accepts with error.
        ///
        /// Each parked accept that is still present at capture time is resumed
        /// here with the connection-closed error. A waiter is captured at most
        /// once (the capture clears `pendingAccepts` under the lock), so this
        /// cannot double-resume one already removed by delivery or cancel.
        func notifyContinuations(error: Error) {
            inboundContinuation?.finish()
            for waiter in pendingAccepts {
                waiter.continuation.resume(throwing: error)
            }
        }

        func resetAllStreams() {
            for stream in streams {
                stream.remoteReset()
            }
        }

        func closeAllStreamsGracefully() async {
            for stream in streams {
                do {
                    try await stream.close()
                } catch {
                    logger.debug("Best-effort Mplex stream close failed during shutdown: \(error)")
                }
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

        // Terminate the control-frame drain loop and cancel its task. The read
        // loop is the caller (or already exiting), so it unwinds on its own.
        controlQueue.finish()
        controlDrainTask.withLock { $0?.cancel() }

        capture.notifyContinuations(error: error)
        capture.resetAllStreams()
    }
}
