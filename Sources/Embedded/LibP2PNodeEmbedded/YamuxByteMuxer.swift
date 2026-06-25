// YamuxByteMuxer.swift
// An Embedded-clean Yamux multiplexer over a secured `[UInt8]` connection. It owns
// the wire: a frame read loop decodes inbound `YamuxByteFrame`s and routes them to
// per-stream inbound buffers; stream writes frame outbound data. Produces
// `EmbeddedMuxedStream` handles (`YamuxByteStream`). Embedded-clean: actor-isolated
// state (Embedded-OK), `[UInt8]` currency (no NIO `ByteBuffer`), no `any`, no
// Foundation, no `Mutex`/`ContinuousClock`/`Task.sleep`, typed throws.
//
// Slice-1 scope: stream open/accept, ordered data delivery, FIN/RST, and a simple
// connection/stream credit (a generous static window with window-update returns).
// Keep-alive pings, window auto-tuning, and aggressive flow control are deferred to
// a later slice (they layer on the AsyncTimer seam without changing this surface).

import _Concurrency   // REQUIRED under Embedded for async/Task/withCheckedContinuation
import P2PCoreCrypto   // AsyncTimer / MonotonicClock seam (deferred timers)

/// The default per-stream + connection receive window (256 KiB).
public let yamuxByteDefaultWindow: UInt32 = 256 * 1024

/// A Yamux multiplexer over a reliable `[UInt8]` connection.
///
/// Monomorphic over the connection `R` (no `any`). Call ``run()`` once (typically in
/// a child task) to drive the frame read loop; use ``open()`` to start a stream and
/// ``accept()`` to receive a peer-initiated one.
public final actor YamuxByteMuxer<R: EmbeddedRawConnection> {

    // MARK: - Per-stream state

    private struct StreamState {
        var inbound: [UInt8] = []
        /// FIN received from the peer (no more inbound data after the buffer drains).
        var remoteClosed = false
        /// RST received or sent (the stream is dead).
        var reset = false
        /// A parked `read` waiter for this stream.
        var readWaiter: CheckedContinuation<[UInt8], Never>?
    }

    private let raw: R
    private let isInitiator: Bool

    private var streams: [UInt64: StreamState] = [:]
    private var nextStreamID: UInt32
    private var closed = false

    /// Parked `accept()` waiters (FIFO).
    private var acceptWaiters: [CheckedContinuation<UInt64, Never>] = []
    /// Inbound stream ids ready to be accepted but not yet awaited.
    private var pendingInbound: [UInt64] = []

    public init(raw: R, isInitiator: Bool) {
        self.raw = raw
        self.isInitiator = isInitiator
        // Initiator uses odd ids, responder even (libp2p / Yamux convention).
        self.nextStreamID = isInitiator ? 1 : 2
    }

    // MARK: - Public API

    /// Opens a new outbound stream, sending its SYN.
    ///
    /// - Throws: ``EmbeddedNodeError/connectionClosed`` if the muxer is closed,
    ///   ``EmbeddedNodeError/yamuxProtocolError`` if the id space is exhausted.
    public func open() async throws(EmbeddedNodeError) -> YamuxByteStream<R> {
        if closed { throw .connectionClosed }
        let id = nextStreamID
        let (next, overflow) = id.addingReportingOverflow(2)
        if overflow { throw .yamuxProtocolError }
        nextStreamID = next

        streams[UInt64(id)] = StreamState()
        let syn = YamuxByteFrame.makeData(streamID: id, flags: .syn, payload: [])
        try await writeFrame(syn)
        return YamuxByteStream(id: UInt64(id), muxer: self)
    }

    /// Waits for the next peer-initiated stream.
    ///
    /// - Throws: ``EmbeddedNodeError/connectionClosed`` if the muxer closes while
    ///   waiting.
    public func accept() async throws(EmbeddedNodeError) -> YamuxByteStream<R> {
        if closed { throw .connectionClosed }
        if !pendingInbound.isEmpty {
            let id = pendingInbound.removeFirst()
            return YamuxByteStream(id: id, muxer: self)
        }
        let id = await withCheckedContinuation { (cont: CheckedContinuation<UInt64, Never>) in
            acceptWaiters.append(cont)
        }
        // A sentinel of UInt64.max signals the muxer closed while parked.
        if id == UInt64.max {
            throw .connectionClosed
        }
        return YamuxByteStream(id: id, muxer: self)
    }

    // MARK: - Read loop

    /// Drives the inbound frame loop until the connection ends or the muxer closes.
    /// Call once; typically in a child task alongside the consumer.
    public func run() async {
        var buffer = [UInt8]()
        while !closed {
            let chunk: [UInt8]
            do {
                chunk = try await raw.read()
            } catch {
                break
            }
            if chunk.isEmpty {
                break
            }
            buffer.append(contentsOf: chunk)

            // Drain all complete frames.
            while true {
                let outcome: YamuxByteFrame.DecodeOutcome
                do {
                    outcome = try YamuxByteFrame.decode(from: buffer, at: 0)
                } catch {
                    // Malformed frame — tear the session down.
                    await teardown()
                    return
                }
                switch outcome {
                case .needMoreData:
                    // Compact consumed prefix and read more.
                    if buffer.count > yamuxByteCompactThreshold {
                        buffer = []
                    }
                    break
                case .frame(let frame, let consumed):
                    buffer.removeFirst(consumed)
                    await handle(frame)
                    continue
                }
                break
            }
        }
        await teardown()
    }

    // MARK: - Stream I/O (called by YamuxByteStream handles)

    func readStream(_ id: UInt64) async throws(EmbeddedNodeError) -> [UInt8] {
        // Fast path: buffered data or already-closed.
        if var state = streams[id] {
            if state.reset { throw .yamuxStreamClosed }
            if !state.inbound.isEmpty {
                let out = state.inbound
                state.inbound = []
                streams[id] = state
                return out
            }
            if state.remoteClosed {
                // Drained + FIN → clean EOF (empty).
                return []
            }
        } else {
            throw .yamuxStreamClosed
        }
        if closed { throw .connectionClosed }

        // Park a single reader for this stream.
        let result: [UInt8] = await withCheckedContinuation { (cont: CheckedContinuation<[UInt8], Never>) in
            if var state = streams[id] {
                state.readWaiter = cont
                streams[id] = state
            } else {
                cont.resume(returning: [])
            }
        }
        // An empty result here may mean EOF or reset; re-check the state.
        if let state = streams[id], state.reset {
            throw .yamuxStreamClosed
        }
        return result
    }

    func writeStream(_ id: UInt64, data: [UInt8]) async throws(EmbeddedNodeError) {
        if closed { throw .connectionClosed }
        guard let state = streams[id], !state.reset else {
            throw .yamuxStreamClosed
        }
        // Chunk to the max frame size (well under the 16 MiB bound).
        var offset = 0
        let chunkSize = Int(yamuxByteDefaultWindow)
        guard let sid32 = UInt32(exactly: id) else {
            throw .yamuxProtocolError
        }
        if data.isEmpty {
            return
        }
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            let payload = Array(data[offset..<end])
            offset = end
            let frame = YamuxByteFrame.makeData(streamID: sid32, flags: [], payload: payload)
            try await writeFrame(frame)
        }
    }

    func closeStream(_ id: UInt64) async {
        guard let sid32 = UInt32(exactly: id) else { return }
        // Send FIN (best effort) and forget the stream's send side.
        let fin = YamuxByteFrame.makeData(streamID: sid32, flags: .fin, payload: [])
        await writeFrameBestEffort(fin)
    }

    // MARK: - Frame handling

    private func handle(_ frame: YamuxByteFrame) async {
        switch frame.type {
        case .data:
            await handleData(frame)
        case .windowUpdate:
            // Slice-1: generous static window; window updates are accepted (no-op)
            // rather than enforced. A later slice wires real credit accounting.
            break
        case .ping:
            await handlePing(frame)
        case .goAway:
            await teardown()
        }
    }

    private func handleData(_ frame: YamuxByteFrame) async {
        let id = UInt64(frame.streamID)

        // New inbound stream (SYN).
        if frame.flags.contains(.syn) {
            let valid = isValidInboundStreamID(frame.streamID)
            if !valid {
                await sendResetBestEffort(frame.streamID)
                return
            }
            if streams[id] == nil {
                streams[id] = StreamState()
                // ACK the new stream.
                let ack = YamuxByteFrame.makeData(streamID: frame.streamID, flags: .ack, payload: [])
                await writeFrameBestEffort(ack)
                deliverInbound(id)
            }
        }

        // Payload.
        if frame.type == .data && !frame.data.isEmpty {
            appendInbound(id, frame.data)
        }

        // FIN / RST.
        if frame.flags.contains(.rst) {
            markReset(id)
        } else if frame.flags.contains(.fin) {
            markRemoteClosed(id)
        }
    }

    private func handlePing(_ frame: YamuxByteFrame) async {
        if frame.flags.contains(.ack) {
            // Pong for a ping we sent; slice-1 sends no pings, so ignore.
            return
        }
        let pong = YamuxByteFrame.makePing(opaque: frame.length, ack: true)
        await writeFrameBestEffort(pong)
    }

    // MARK: - Inbound delivery

    private func deliverInbound(_ id: UInt64) {
        if !acceptWaiters.isEmpty {
            let waiter = acceptWaiters.removeFirst()
            waiter.resume(returning: id)
        } else {
            pendingInbound.append(id)
        }
    }

    private func appendInbound(_ id: UInt64, _ bytes: [UInt8]) {
        guard var state = streams[id], !state.reset else { return }
        if let waiter = state.readWaiter {
            state.readWaiter = nil
            streams[id] = state
            waiter.resume(returning: bytes)
        } else {
            state.inbound.append(contentsOf: bytes)
            streams[id] = state
        }
    }

    private func markRemoteClosed(_ id: UInt64) {
        guard var state = streams[id] else { return }
        state.remoteClosed = true
        let waiter = state.readWaiter
        state.readWaiter = nil
        streams[id] = state
        // Wake a parked reader with whatever is buffered (EOF surfaces as empty
        // once the buffer is drained on the next read).
        if let waiter, state.inbound.isEmpty {
            waiter.resume(returning: [])
        }
    }

    private func markReset(_ id: UInt64) {
        guard var state = streams[id] else { return }
        state.reset = true
        let waiter = state.readWaiter
        state.readWaiter = nil
        streams[id] = state
        waiter?.resume(returning: [])
    }

    // MARK: - Wire writes

    private func writeFrame(_ frame: YamuxByteFrame) async throws(EmbeddedNodeError) {
        if closed { throw .connectionClosed }
        try await raw.write(frame.encode())
    }

    /// Writes a control frame (ACK / FIN / RST / Pong) best-effort. A write failure
    /// here means the underlying connection is dying; the read loop observes the
    /// same failure on its next `raw.read()` and tears the session down. This is
    /// NOT a silent fallback on a data path — control delivery on a failing
    /// connection is genuinely best-effort, and the error is handled (the session
    /// closes), not swallowed into a wrong result.
    private func writeFrameBestEffort(_ frame: YamuxByteFrame) async {
        if closed { return }
        do {
            try await raw.write(frame.encode())
        } catch {
            // The connection is failing; teardown happens via the read loop.
        }
    }

    private func sendResetBestEffort(_ streamID: UInt32) async {
        let rst = YamuxByteFrame.makeData(streamID: streamID, flags: .rst, payload: [])
        await writeFrameBestEffort(rst)
    }

    // MARK: - Validation

    private func isValidInboundStreamID(_ streamID: UInt32) -> Bool {
        if streamID == 0 { return false }
        // We receive streams from the peer of opposite parity.
        if isInitiator {
            return streamID % 2 == 0   // we are odd → peer is even
        } else {
            return streamID % 2 == 1   // we are even → peer is odd
        }
    }

    // MARK: - Teardown

    /// Closes the muxer: resumes all parked waiters and closes the connection.
    public func close() async {
        await teardown()
    }

    private func teardown() async {
        if closed { return }
        closed = true

        // Wake accept waiters with the closed sentinel.
        let accepts = acceptWaiters
        acceptWaiters = []
        for waiter in accepts {
            waiter.resume(returning: UInt64.max)
        }

        // Wake all stream readers (empty → they re-check `reset`/closed).
        for (id, var state) in streams {
            state.reset = true
            let waiter = state.readWaiter
            state.readWaiter = nil
            streams[id] = state
            waiter?.resume(returning: [])
        }

        await raw.close()
    }
}

/// Read-buffer compaction threshold (64 KiB) for the frame read loop.
let yamuxByteCompactThreshold = 64 * 1024
