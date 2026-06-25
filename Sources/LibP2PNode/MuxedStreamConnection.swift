// MuxedStreamConnection.swift
// Bridges a `MuxedStream` (`[UInt8]` read/write/close) onto the `RawConnection`
// surface the `MultistreamNegotiator` consumes. The negotiator frames its
// line-protocol over a `RawConnection`; a node-opened mux stream IS that byte pipe.
// Embedded-clean: monomorphic over `S: MuxedStream`, `[UInt8]` currency, no `any`,
// typed throws.

import _Concurrency   // REQUIRED under Embedded for async/Task

/// Presents a ``MuxedStream`` as a ``RawConnection`` so multistream-select can run
/// over it before a protocol handler takes the same stream.
///
/// Monomorphic over `S` (no `any`): the adapter forwards `read`/`write`/`close`
/// verbatim. It holds no buffer of its own — the negotiator owns its read buffer —
/// so a protocol handler resumes reading the very next stream bytes after
/// negotiation completes.
public struct MuxedStreamConnection<S: MuxedStream>: RawConnection {

    /// The wrapped mux stream.
    public let stream: S

    public init(_ stream: S) {
        self.stream = stream
    }

    public func read() async throws(NodeError) -> [UInt8] {
        try await stream.read()
    }

    public func write(_ data: [UInt8]) async throws(NodeError) {
        try await stream.write(data)
    }

    public func close() async {
        await stream.close()
    }
}
