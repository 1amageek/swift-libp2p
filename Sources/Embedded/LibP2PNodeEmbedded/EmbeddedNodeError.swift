// EmbeddedNodeError.swift
// The single typed error surface for the Embedded libp2p node data path.
// Embedded-clean: no Foundation, no `any`, no `String(describing:)`. Every
// fallible entrypoint on the Embedded data path throws this closed enum so the
// caller can pattern-match exhaustively (no silent fallback).

import _Concurrency   // REQUIRED under Embedded for async/Task

/// Errors surfaced by the Embedded libp2p node's data path
/// (transport → security → mux → negotiation).
///
/// A closed enum (no `any Error`) so it crosses the typed-throws boundary cleanly
/// under Embedded Swift. Each case names the failing layer; callers fail-closed.
public enum EmbeddedNodeError: Error, Sendable, Equatable {

    // MARK: - Transport

    /// The underlying raw connection is closed; no further I/O is permitted.
    case connectionClosed

    /// A raw transport read returned end-of-stream before a complete frame.
    case unexpectedEndOfStream

    /// The transport reported an I/O failure.
    case transportFailure

    /// A QUIC engine operation that this slice does not wire (Retry / 0-RTT /
    /// migration / the full TLS handshake driver) was requested. Surfaced rather
    /// than silently mis-handled (no silent fallback).
    ///
    /// No associated value: an Embedded-clean reason would be a `StaticString`,
    /// which is not `Equatable` and would block the synthesized `Equatable`
    /// conformance used by tests. The specific feature is documented at each throw
    /// site instead.
    case quicFeatureUnsupported

    // MARK: - Security (Noise)

    /// The Noise handshake failed (a crypto/state-machine error in the core).
    case noiseHandshakeFailed

    /// The remote's libp2p identity signature did not verify against the Noise
    /// static key. FAIL-CLOSED: the identity is rejected, never silently accepted.
    case noiseIdentityVerificationFailed

    /// The remote presented an unsupported identity key type (only Ed25519 and
    /// ECDSA P-256 are admitted on the minimal node).
    case noiseUnsupportedIdentityKeyType(UInt64)

    /// The decrypted Noise payload was malformed (bad protobuf framing).
    case noiseInvalidPayload

    /// A Noise transport-frame was malformed (bad length prefix / oversize).
    case noiseFramingFailed

    // MARK: - Mux (Yamux)

    /// A Yamux frame violated the protocol (bad version / type / stream id).
    case yamuxProtocolError

    /// A Yamux frame exceeded the configured maximum size (DoS bound).
    case yamuxFrameTooLarge

    /// The Yamux stream is closed for the attempted operation.
    case yamuxStreamClosed

    // MARK: - Negotiation (multistream-select)

    /// The peer did not offer (or rejected) the requested protocol.
    case negotiationRejected

    /// A multistream-select message was malformed on the wire.
    case negotiationProtocolError

    /// The negotiation deadline elapsed before a complete exchange.
    case negotiationTimedOut
}
