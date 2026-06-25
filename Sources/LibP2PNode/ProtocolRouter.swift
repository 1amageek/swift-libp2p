// ProtocolRouter.swift
// The minimal server-side inbound-stream dispatch: a listener negotiates
// multistream-select over an inbound `MuxedStream`, then routes the agreed protocol
// id to the registered handler. This is the small, real protocol-router for this
// slice; the full node facade (`handle()` registration + Swarm) is the next slice.
//
// Embedded-clean: monomorphic over `<S: MuxedStream, Timer: AsyncTimer>`, no `any`
// (handlers are concrete `@Sendable` closures over the same `S`), typed throws,
// no try?/try!. FAIL-CLOSED: an inbound stream offering only unsupported protocol
// ids surfaces ``NodeError/negotiationRejected`` from the negotiator — never a
// silent drop.

import _Concurrency   // REQUIRED under Embedded for async/Task
import P2PCoreCrypto   // AsyncTimer

/// Routes an inbound, multistream-negotiated mux stream to a registered handler.
///
/// Monomorphic over the stream type `S` and the clock `Timer` (no `any`): a handler
/// is a concrete `@Sendable` closure `(S) async throws(NodeError) -> Void` paired
/// with the protocol id it serves. `dispatch(inbound:)` runs the listener side of
/// multistream-select (offering every registered id) and invokes the matched
/// handler over the same stream.
public struct ProtocolRouter<S: MuxedStream, Timer: AsyncTimer>: Sendable {

    /// A registered protocol handler: the id it serves and the body that runs over
    /// an inbound stream once that id is negotiated.
    ///
    /// The handler receives a ``BufferedMuxedStream`` so any application bytes the
    /// negotiator over-read (a dialer that coalesced its payload with the protocol
    /// id) are replayed to the handler — no application byte is ever dropped.
    public struct Route: Sendable {
        public let protocolID: String
        public let handler: @Sendable (BufferedMuxedStream<S>) async throws(NodeError) -> Void

        public init(
            protocolID: String,
            handler: @escaping @Sendable (BufferedMuxedStream<S>) async throws(NodeError) -> Void
        ) {
            self.protocolID = protocolID
            self.handler = handler
        }
    }

    private let routes: [Route]
    private let timer: Timer
    /// The negotiation deadline budget in nanoseconds from a `dispatch` call's start.
    private let negotiationTimeoutNanos: UInt64

    /// Builds a router over the registered `routes`.
    ///
    /// - Parameters:
    ///   - routes: The protocol handlers, in offer order. The listener offers every
    ///     registered id during negotiation.
    ///   - timer: The monotonic clock seam used for the negotiation deadline.
    ///   - negotiationTimeoutNanos: The per-dispatch negotiation budget.
    public init(
        routes: [Route],
        timer: Timer,
        negotiationTimeoutNanos: UInt64 = 10_000_000_000
    ) {
        self.routes = routes
        self.timer = timer
        self.negotiationTimeoutNanos = negotiationTimeoutNanos
    }

    /// The protocol ids this router serves, in offer order.
    public var supportedProtocols: [String] {
        var ids = [String]()
        ids.reserveCapacity(routes.count)
        for route in routes {
            ids.append(route.protocolID)
        }
        return ids
    }

    /// Negotiates `inbound` as the listener and runs the matched handler.
    ///
    /// Runs multistream-select over the stream offering every registered protocol
    /// id, then invokes the handler whose id was agreed. The handler reads/writes
    /// the very same stream (its read buffer resumes right after the negotiation
    /// bytes).
    ///
    /// - Parameter inbound: A freshly-accepted inbound mux stream.
    /// - Throws: ``NodeError/negotiationRejected`` if the peer offers no supported
    ///   id, the negotiator's other ``NodeError`` cases on a malformed / timed-out
    ///   exchange, or the handler's propagated ``NodeError`` (fail-closed — a
    ///   handler failure is surfaced, never swallowed).
    public func dispatch(inbound: S) async throws(NodeError) {
        let connection = MuxedStreamConnection(inbound)
        let negotiator = MultistreamNegotiator(
            connection: connection,
            timer: timer,
            timeoutNanos: negotiationTimeoutNanos
        )
        let (agreed, residual) = try await negotiator.listenReturningResidual(
            supported: supportedProtocols
        )

        // Carry any over-read application bytes into the handler so none are dropped.
        let handlerStream = BufferedMuxedStream(stream: inbound, residual: residual)

        // Find the handler for the agreed id. The negotiator only returns an id it
        // was offered, so a miss here is a logic error, not an untrusted input;
        // still fail-closed rather than silently ignore.
        for route in routes where route.protocolID == agreed {
            try await route.handler(handlerStream)
            return
        }
        throw .negotiationRejected
    }
}
