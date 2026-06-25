// PingService.swift
// The libp2p ping protocol (`/ipfs/ping/1.0.0`, RFC libp2p ping) over a
// `MuxedStream`. The client writes 32 random bytes, reads the 32-byte echo,
// verifies byte-equality, and measures the round-trip time; the server echoes each
// inbound 32-byte frame. Embedded-clean: monomorphic over `<C: CryptoProvider,
// Timer: AsyncTimer>`, `[UInt8]` currency, no `any`, typed throws, no try?/try!.
//
// FAIL-CLOSED: a mismatched or truncated echo throws a typed ``NodeError`` — the
// ping is never reported as successful on a partial / wrong echo.

import _Concurrency   // REQUIRED under Embedded for async/Task
import P2PCoreCrypto   // CryptoProvider (entropy) / AsyncTimer

/// Drives `/ipfs/ping/1.0.0` over an already-negotiated ``MuxedStream``.
///
/// Monomorphic over the crypto seam `C` (its CSPRNG produces the ping payload) and
/// the clock `Timer` (it measures the RTT). The protocol id is *not* negotiated
/// here — the caller negotiates `/ipfs/ping/1.0.0` via ``MultistreamNegotiator``
/// first, then runs this over the same stream.
public enum PingService<C: CryptoProvider, Timer: AsyncTimer> {

    /// The libp2p ping frame size: exactly 32 bytes per RFC libp2p ping.
    public static var frameSize: Int { 32 }

    // MARK: - Client

    /// Sends one ping over `stream` and returns the measured round-trip.
    ///
    /// Draws 32 random bytes from the entropy seam, records the monotonic clock,
    /// writes the frame, reads exactly 32 bytes of echo, verifies byte-equality,
    /// and records the clock again. The RTT spans write-start to echo-complete.
    ///
    /// - Parameters:
    ///   - stream: An open mux stream over which `/ipfs/ping/1.0.0` is already
    ///     negotiated.
    ///   - timer: The monotonic clock seam used to measure the RTT.
    /// - Returns: A ``PingResult`` with the round-trip nanoseconds.
    /// - Throws: ``NodeError/pingEntropyFailed`` if the CSPRNG returns a short
    ///   payload, ``NodeError/pingTruncated`` if the echo ends before 32 bytes,
    ///   ``NodeError/pingMismatch`` if the echo does not byte-match the payload,
    ///   or a propagated stream ``NodeError`` on I/O failure (fail-closed).
    public static func ping<S: MuxedStream>(
        on stream: S,
        timer: Timer
    ) async throws(NodeError) -> PingResult {
        // 32 random bytes from the entropy seam (never a fixed / predictable frame).
        let payload = C.random.randomBytes(Self.frameSize)
        guard payload.count == Self.frameSize else {
            throw .pingEntropyFailed
        }

        let start = timer.monotonicNanos()
        try await stream.write(payload)

        // Read exactly 32 bytes of echo (accumulate across chunk boundaries). An
        // empty read (FIN) before 32 bytes is a truncated echo — fail-closed.
        var echo = [UInt8]()
        echo.reserveCapacity(Self.frameSize)
        while echo.count < Self.frameSize {
            let chunk = try await stream.read()
            if chunk.isEmpty {
                throw .pingTruncated
            }
            echo.append(contentsOf: chunk)
        }
        let end = timer.monotonicNanos()

        guard Self.bytesEqual(Array(echo[0..<Self.frameSize]), payload) else {
            throw .pingMismatch
        }

        // Monotonic clock is non-decreasing; clamp defensively without masking a bug.
        let rtt = end >= start ? end &- start : 0
        return PingResult(roundTripNanos: rtt)
    }

    // MARK: - Server

    /// Serves inbound pings on `stream`: reads each 32-byte frame and echoes it back
    /// verbatim, until the peer half-closes (clean FIN) or the stream errors.
    ///
    /// The server makes no equality assertion — it is a pure echo. It returns
    /// normally on a clean end-of-stream; an I/O error propagates as a typed
    /// ``NodeError`` (fail-closed — the handler does not swallow transport faults).
    ///
    /// - Parameter stream: An inbound mux stream over which `/ipfs/ping/1.0.0` is
    ///   already negotiated by the listener.
    public static func serve<S: MuxedStream>(
        on stream: S
    ) async throws(NodeError) {
        var pending = [UInt8]()
        while true {
            // Accumulate until a full 32-byte frame is buffered. A clean FIN with
            // an empty buffer ends serving; a FIN mid-frame is a truncation.
            while pending.count < Self.frameSize {
                let chunk = try await stream.read()
                if chunk.isEmpty {
                    if pending.isEmpty {
                        // Clean end-of-stream at a frame boundary: peer stopped.
                        return
                    }
                    // The peer half-closed mid-frame. FAIL-CLOSED.
                    throw .pingTruncated
                }
                pending.append(contentsOf: chunk)
            }
            // Echo exactly one frame; keep any surplus for the next iteration.
            let frame = Array(pending[0..<Self.frameSize])
            pending.removeFirst(Self.frameSize)
            try await stream.write(frame)
        }
    }

    // MARK: - Private

    /// Constant-shape byte equality (avoids `Array.==` overload ambiguity under
    /// Embedded). The frames are fixed-length, so the lengths always match here.
    private static func bytesEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        for i in 0..<a.count where a[i] != b[i] {
            return false
        }
        return true
    }
}
