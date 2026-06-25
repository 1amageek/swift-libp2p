// YamuxByteStream.swift
// A single Yamux stream over `[UInt8]`, conforming to `EmbeddedMuxedStream`. It is
// a thin handle whose I/O delegates to the owning `YamuxByteMuxer` actor (which
// owns the wire and the per-stream inbound buffers). Embedded-clean: no `any`, no
// Foundation, typed throws.

import _Concurrency   // REQUIRED under Embedded for async/Task

/// A multiplexed Yamux stream with a `[UInt8]` surface.
///
/// The handle holds only the stream id and a back-reference to its muxer; the
/// muxer owns the inbound buffer, the read-waiter, and the wire. Reading and
/// writing forward to the muxer actor, which serialises frame I/O.
///
/// Generic only over the connection `R` — the muxer needs no crypto seam; it runs
/// over any reliable `[UInt8]` connection (typically a `NoiseSecuredConnection`).
public final class YamuxByteStream<R: EmbeddedRawConnection>: EmbeddedMuxedStream {

    public let id: UInt64
    private let muxer: YamuxByteMuxer<R>

    init(id: UInt64, muxer: YamuxByteMuxer<R>) {
        self.id = id
        self.muxer = muxer
    }

    public func read() async throws(EmbeddedNodeError) -> [UInt8] {
        try await muxer.readStream(id)
    }

    public func write(_ data: [UInt8]) async throws(EmbeddedNodeError) {
        try await muxer.writeStream(id, data: data)
    }

    public func close() async {
        await muxer.closeStream(id)
    }
}
