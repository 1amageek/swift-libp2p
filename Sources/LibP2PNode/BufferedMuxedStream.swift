// BufferedMuxedStream.swift
// A `MuxedStream` that yields a residual byte prefix before delegating to the
// underlying stream. This carries the application bytes a `MultistreamNegotiator`
// over-read during negotiation (the peer coalesced its payload with the protocol
// echo) into the protocol handler — so no application byte is ever dropped.
// Embedded-clean: monomorphic over `S: MuxedStream`, `[UInt8]` currency, no `any`,
// typed throws. The residual is consumed under an actor (single mutable read state).

import _Concurrency   // REQUIRED under Embedded for async/Task

/// Wraps a ``MuxedStream`` so a residual byte prefix is read out first.
///
/// After multistream-select negotiation, the negotiator may have buffered the
/// leading bytes of the application message. This wrapper returns those residual
/// bytes from the first ``read()`` (one chunk), then forwards every subsequent
/// `read`/`write`/`close` to the wrapped stream verbatim. `write`/`close`/`id` are
/// never affected by the residual.
public final actor BufferedMuxedStreamState<S: MuxedStream> {

    private let stream: S
    private var residual: [UInt8]

    init(stream: S, residual: [UInt8]) {
        self.stream = stream
        self.residual = residual
    }

    /// Returns the residual prefix once (as a single chunk), then delegates.
    func read() async throws(NodeError) -> [UInt8] {
        if !residual.isEmpty {
            let chunk = residual
            residual = []
            return chunk
        }
        return try await stream.read()
    }

    func write(_ data: [UInt8]) async throws(NodeError) {
        try await stream.write(data)
    }

    func close() async {
        await stream.close()
    }

    nonisolated var id: UInt64 { stream.id }
}

/// A ``MuxedStream`` facade over ``BufferedMuxedStreamState`` so it satisfies the
/// stream protocol while the residual read-state stays actor-isolated.
public struct BufferedMuxedStream<S: MuxedStream>: MuxedStream {

    private let state: BufferedMuxedStreamState<S>

    /// Wraps `stream`, prepending `residual` to its read sequence. If `residual` is
    /// empty this behaves exactly like the underlying stream.
    public init(stream: S, residual: [UInt8]) {
        self.state = BufferedMuxedStreamState(stream: stream, residual: residual)
    }

    public var id: UInt64 { state.id }

    public func read() async throws(NodeError) -> [UInt8] {
        try await state.read()
    }

    public func write(_ data: [UInt8]) async throws(NodeError) {
        try await state.write(data)
    }

    public func close() async {
        await state.close()
    }
}
