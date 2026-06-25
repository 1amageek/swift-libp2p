// StreamNegotiation.swift
// The client-side "negotiate a protocol over a mux stream" helper: the dialer half
// of multistream-select run over a `MuxedStream`, so a caller's flow reads
// open-stream → negotiate → run-protocol. The full node facade (`newStream`) is the
// next slice; this is the minimal, real dialer-side negotiation primitive.
//
// Embedded-clean: monomorphic over `<S: MuxedStream, Timer: AsyncTimer>`, no `any`,
// typed throws, no try?/try!. FAIL-CLOSED: a peer that rejects the protocol
// surfaces ``NodeError/negotiationRejected`` from the negotiator.

import _Concurrency   // REQUIRED under Embedded for async/Task
import P2PCoreCrypto   // AsyncTimer

/// The dialer side of multistream-select over a ``MuxedStream``.
public enum StreamNegotiation {

    /// Negotiates `protocolID` as the dialer over `stream` and returns a stream
    /// ready for the protocol handler.
    ///
    /// Runs the dialer half of multistream-select, then returns a
    /// ``BufferedMuxedStream`` that carries any application bytes the negotiator
    /// over-read (a peer that coalesces its payload with the protocol echo). The
    /// handler MUST read/write the *returned* stream, not the original — the
    /// returned stream replays those residual bytes first so none are dropped.
    ///
    /// - Parameters:
    ///   - protocolID: The protocol id to propose (e.g. ``NodeProtocolID/ping``).
    ///   - stream: A freshly-opened mux stream.
    ///   - timer: The monotonic clock seam used for the negotiation deadline.
    ///   - timeoutNanos: The negotiation budget in nanoseconds.
    /// - Returns: A stream wrapping `stream` with the negotiation residual replayed.
    /// - Throws: ``NodeError/negotiationRejected`` if the peer declines the
    ///   protocol, or the negotiator's other ``NodeError`` cases on a malformed /
    ///   timed-out exchange (fail-closed).
    public static func dial<S: MuxedStream, Timer: AsyncTimer>(
        _ protocolID: String,
        on stream: S,
        timer: Timer,
        timeoutNanos: UInt64 = 10_000_000_000
    ) async throws(NodeError) -> BufferedMuxedStream<S> {
        let connection = MuxedStreamConnection(stream)
        let negotiator = MultistreamNegotiator(
            connection: connection,
            timer: timer,
            timeoutNanos: timeoutNanos
        )
        let residual = try await negotiator.dialReturningResidual(protocolID)
        return BufferedMuxedStream(stream: stream, residual: residual)
    }
}
