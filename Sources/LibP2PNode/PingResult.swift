// PingResult.swift
// The outcome of a successful libp2p ping: the measured round-trip time.
// Embedded-clean: a plain value type over `UInt64` nanos (no `Duration`,
// no Foundation). Named by responsibility (no Embedded/Byte qualifier).

/// The result of a successful `/ipfs/ping/1.0.0` exchange.
///
/// A `PingResult` is only ever produced when the 32-byte echo byte-matched the
/// sent payload (fail-closed): a mismatch or truncation throws a ``NodeError``
/// instead of returning a result.
public struct PingResult: Sendable, Equatable {

    /// The measured round-trip time in nanoseconds, from just before the write of
    /// the 32-byte ping to just after the full echo was read back.
    ///
    /// Measured through the injected ``AsyncTimer``/`MonotonicClock` seam — never
    /// `ContinuousClock` — so it is identical on host and Embedded builds.
    public let roundTripNanos: UInt64

    public init(roundTripNanos: UInt64) {
        self.roundTripNanos = roundTripNanos
    }
}
