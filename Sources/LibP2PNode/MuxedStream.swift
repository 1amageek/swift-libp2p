// MuxedStream.swift
// The multiplexed-stream surface: `[UInt8]` read/write/close. The seam-based
// analogue of the host `MuxedStream`, with `[UInt8]` currency instead of
// NIO `ByteBuffer`. Embedded-clean: no `any`, no Foundation, typed throws.

import _Concurrency   // REQUIRED under Embedded for async/Task

/// A single multiplexed stream over a muxed connection, with a `[UInt8]` surface.
///
/// This is the currency the node hands to protocol handlers (Ping /
/// Identify in later slices). `read` returns the next inbound chunk; `write` sends
/// bytes; `close` half-closes the send side and tears the stream down.
///
/// `[UInt8]` is the only byte currency on this surface — there is no NIO
/// `ByteBuffer` anywhere in the mux boundary (the Yamux frame state
/// machine wraps its internal buffering at the `[UInt8]` boundary).
public protocol MuxedStream: Sendable {

    /// The stream's identifier on its connection.
    var id: UInt64 { get }

    /// Reads the next chunk of inbound stream bytes.
    ///
    /// Returns at least one byte, blocking until data arrives. An empty return
    /// signals the remote half-closed (FIN) with no more data.
    ///
    /// - Throws: ``NodeError/yamuxStreamClosed`` if the stream is reset/closed.
    func read() async throws(NodeError) -> [UInt8]

    /// Writes `data` to the stream, flushing it through the muxer.
    ///
    /// - Throws: ``NodeError/yamuxStreamClosed`` if the stream is closed,
    ///   ``NodeError/connectionClosed`` if the connection is gone.
    func write(_ data: [UInt8]) async throws(NodeError)

    /// Closes the stream's send side (sends FIN) and stops further writes.
    func close() async
}
