// MultistreamNegotiator.swift
// multistream-select protocol negotiation over a `[UInt8]` connection, driving the
// Embedded-clean `MultistreamCodec` (LibP2PCore) with an `AsyncTimer` deadline.
// Embedded-clean: `[UInt8]` currency, no `any`, no Foundation, no ContinuousClock,
// typed throws. FAIL-CLOSED: a peer that does not agree the requested protocol
// surfaces ``NodeError/negotiationRejected`` — never a silent proceed.

import _Concurrency   // REQUIRED under Embedded for async/Task
import LibP2PCore
import P2PCoreCrypto   // AsyncTimer / MonotonicClock seam

/// Drives multistream-select over a raw `[UInt8]` connection.
///
/// Monomorphic over the connection `R` and the clock `Timer` (no `any`): the
/// dialer proposes the multistream header then a single protocol id and confirms
/// the echo; the listener confirms the header then accepts the first offered id
/// that it supports. The wire codec is `LibP2PCore.MultistreamCodec`; the deadline
/// is enforced through the injected `AsyncTimer` (no `Task.sleep`).
public struct MultistreamNegotiator<
    R: RawConnection,
    Timer: AsyncTimer
>: Sendable {

    /// The multistream-select protocol header token.
    static var headerToken: String { MultistreamCodec.protocolID }

    private let connection: R
    private let timer: Timer
    /// The negotiation deadline budget in nanoseconds from the call's start.
    private let timeoutNanos: UInt64

    public init(connection: R, timer: Timer, timeoutNanos: UInt64 = 10_000_000_000) {
        self.connection = connection
        self.timer = timer
        self.timeoutNanos = timeoutNanos
    }

    // MARK: - Dialer

    /// Proposes `proto` as the dialer and confirms the listener echoed it.
    ///
    /// Sends the multistream header and the protocol id, then reads until both the
    /// header echo and the protocol echo are confirmed. Returns on success.
    ///
    /// - Throws: ``NodeError/negotiationRejected`` if the listener answers
    ///   `na` or a different protocol, ``NodeError/negotiationTimedOut`` on
    ///   deadline, ``NodeError/negotiationProtocolError`` on a malformed line.
    public func dial(_ proto: String) async throws(NodeError) {
        _ = try await dialReturningResidual(proto)
    }

    /// Proposes `proto` as the dialer and returns any *residual* application bytes.
    ///
    /// Identical to ``dial(_:)`` but returns the bytes the peer sent *after* the
    /// protocol echo that this negotiator over-read into its buffer. A peer that
    /// writes its application payload coalesced with the negotiation echo (e.g.
    /// Identify, which the server writes immediately after accepting) would
    /// otherwise have those leading bytes silently dropped when the negotiator is
    /// discarded. The caller MUST feed the residual to the protocol handler before
    /// the next stream read (see ``BufferedMuxedStream``) — fail-closed against
    /// losing application bytes.
    ///
    /// - Returns: The residual application bytes (empty if the peer sent none yet).
    public func dialReturningResidual(_ proto: String) async throws(NodeError) -> [UInt8] {
        let deadline = timer.monotonicNanos() &+ timeoutNanos

        // Send header + proposed protocol in one flush.
        var out = MultistreamCodec.encode(Self.headerToken)
        out.append(contentsOf: MultistreamCodec.encode(proto))
        try await connection.write(out)

        var buffer = [UInt8]()
        var headerConfirmed = false
        while true {
            let token = try await readNextToken(into: &buffer, deadline: deadline)
            if !headerConfirmed {
                guard token == Self.headerToken else {
                    throw .negotiationProtocolError
                }
                headerConfirmed = true
                continue
            }
            // Protocol-id echo.
            if token == proto {
                // Anything still buffered is the peer's application payload that
                // arrived coalesced with the echo — hand it back, never drop it.
                return buffer
            }
            // `na` or any other id means the listener did not accept our proposal.
            throw .negotiationRejected
        }
    }

    // MARK: - Listener

    /// Confirms the header as the listener and accepts the first offered protocol
    /// id present in `supported`.
    ///
    /// Reads the dialer's header, echoes it, then for each offered id either echoes
    /// it (accept) and returns it, or answers `na` (reject) and keeps reading.
    ///
    /// - Returns: The agreed protocol id.
    /// - Throws: ``NodeError/negotiationTimedOut`` on deadline,
    ///   ``NodeError/negotiationProtocolError`` on a malformed line,
    ///   ``NodeError/negotiationRejected`` if the stream ends with no match.
    public func listen(supported: [String]) async throws(NodeError) -> String {
        let (proto, _) = try await listenReturningResidual(supported: supported)
        return proto
    }

    /// Confirms the header as the listener, accepts the first offered protocol id in
    /// `supported`, and returns the agreed id plus any *residual* application bytes.
    ///
    /// Identical to ``listen(supported:)`` but also returns the bytes the dialer
    /// sent *after* the accepted protocol id that this negotiator over-read. A
    /// dialer that writes its request payload coalesced with the protocol id would
    /// otherwise have those leading bytes silently dropped. The caller MUST feed the
    /// residual to the protocol handler before the next read — fail-closed against
    /// losing application bytes.
    ///
    /// - Returns: The agreed protocol id and the residual application bytes (empty
    ///   if the dialer sent none yet).
    public func listenReturningResidual(
        supported: [String]
    ) async throws(NodeError) -> (proto: String, residual: [UInt8]) {
        let deadline = timer.monotonicNanos() &+ timeoutNanos

        var buffer = [UInt8]()
        // Confirm the header.
        let header = try await readNextToken(into: &buffer, deadline: deadline)
        guard header == Self.headerToken else {
            throw .negotiationProtocolError
        }
        try await connection.write(MultistreamCodec.encode(Self.headerToken))

        // Accept the first supported offer.
        while true {
            let offered: String
            do {
                offered = try await readNextToken(into: &buffer, deadline: deadline)
            } catch {
                // A clean end-of-stream with no agreement is a rejection.
                switch error {
                case .unexpectedEndOfStream, .connectionClosed:
                    throw .negotiationRejected
                default:
                    throw error
                }
            }
            if Self.contains(supported, offered) {
                try await connection.write(MultistreamCodec.encode(offered))
                // Anything still buffered is the dialer's application payload that
                // arrived coalesced with the id — hand it back, never drop it.
                return (offered, buffer)
            }
            // Decline this offer; the dialer may propose another.
            try await connection.write(MultistreamCodec.encode("na"))
        }
    }

    // MARK: - Private

    /// Reads and decodes the next complete multistream token, accumulating partial
    /// reads in `buffer` and enforcing the deadline. The consumed bytes are dropped
    /// from the front of `buffer`.
    private func readNextToken(
        into buffer: inout [UInt8], deadline: UInt64
    ) async throws(NodeError) -> String {
        while true {
            // Try to decode a full message from what we already have.
            let outcome: MultistreamCodec.DecodeOutcome
            do {
                outcome = try MultistreamCodec.decode(from: buffer, at: 0)
            } catch {
                // `error` binds as `MultistreamCodecError` (typed throws). Use a
                // bare `catch` + `switch` rather than `catch ... as`, which crashes
                // SILGen on the current toolchain (see Embedded notes).
                throw .negotiationProtocolError
            }
            switch outcome {
            case .message(let token, let consumed):
                buffer.removeFirst(consumed)
                return token
            case .needMoreData:
                break
            }

            if timer.monotonicNanos() >= deadline {
                throw .negotiationTimedOut
            }
            let chunk = try await connection.read()
            if chunk.isEmpty {
                throw .unexpectedEndOfStream
            }
            buffer.append(contentsOf: chunk)
        }
    }

    /// Embedded-clean membership test (avoids `Array.contains` overload ambiguity
    /// under Embedded with `String` elements).
    private static func contains(_ list: [String], _ value: String) -> Bool {
        for item in list where item == value {
            return true
        }
        return false
    }
}
