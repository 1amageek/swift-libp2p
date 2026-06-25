// RawConnection.swift
// The raw, Foundation-free `[UInt8]` connection seam — the boundary a transport
// provides and over which the security / mux / negotiation layers run.
// Embedded-clean: `[UInt8]` currency (no NIO `ByteBuffer`), no `any`, typed throws.

import _Concurrency   // REQUIRED under Embedded for async/Task

/// A reliable, ordered, bidirectional byte stream with a `[UInt8]` surface.
///
/// This is the seam-based analogue of the host `RawConnection` / `SecuredConnection`
/// I/O surface, stripped to `[UInt8]` currency (no NIO `ByteBuffer`, no Foundation
/// `Data`). The security upgrade (Noise) and the multiplexer (Yamux) run *over* a
/// value conforming to this protocol; the protocol negotiation (multistream-select)
/// frames its line-protocol messages over it.
///
/// Implementations are injected as a concrete generic parameter (`<R: RawConnection>`),
/// never as `any`, so the upper layers specialise monomorphically under Embedded.
public protocol RawConnection: Sendable {

    /// Reads the next chunk of inbound bytes.
    ///
    /// Returns whatever bytes are currently available (at least one byte), blocking
    /// until some arrive. An empty return signals clean end-of-stream; callers that
    /// require more bytes treat that as ``NodeError/unexpectedEndOfStream``.
    ///
    /// - Throws: ``NodeError/connectionClosed`` if the connection is closed,
    ///   ``NodeError/transportFailure`` on an I/O error.
    func read() async throws(NodeError) -> [UInt8]

    /// Writes `data` to the peer (all of it, in order).
    ///
    /// - Throws: ``NodeError/connectionClosed`` if the connection is closed,
    ///   ``NodeError/transportFailure`` on an I/O error.
    func write(_ data: [UInt8]) async throws(NodeError)

    /// Closes the connection, releasing its resources.
    func close() async
}
