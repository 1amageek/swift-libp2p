// NodeError.swift
// The single typed error surface for the libp2p node data path.
// Embedded-clean: no Foundation, no `any`, no `String(describing:)`. Every
// fallible entrypoint on the data path throws this closed enum so the
// caller can pattern-match exhaustively (no silent fallback).

import _Concurrency   // REQUIRED under Embedded for async/Task

/// Errors surfaced by the libp2p node's data path
/// (transport → security → mux → negotiation).
///
/// A closed enum (no `any Error`) so it crosses the typed-throws boundary cleanly
/// under Embedded Swift. Each case names the failing layer; callers fail-closed.
public enum NodeError: Error, Sendable, Equatable {

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

    // MARK: - QUIC TLS 1.3 handshake (libp2p-over-QUIC security + mux)

    /// Building the local libp2p RPK certificate failed (a crypto/DER step in the
    /// handshake identity assembly). FAIL-CLOSED: no malformed cert is presented.
    case quicHandshakeCertificateFailed

    /// The QUIC TLS 1.3 handshake state machine failed (a wire-codec, key-schedule,
    /// or message-ordering error driving ``QUICClientHandshake`` /
    /// ``QUICServerHandshake`` / ``QUICClientAuthMachine``). FAIL-CLOSED.
    case quicHandshakeFailed

    /// The QUIC ECDHE (key share) negotiation failed: the peer offered no
    /// supported group, sent a malformed key share, or the (EC)DHE agreement
    /// itself failed. FAIL-CLOSED.
    case quicHandshakeKeyExchangeFailed

    /// The peer's libp2p RPK certificate did not verify (missing/invalid libp2p
    /// extension, bad proof-of-possession signature, unsupported identity key type,
    /// or an un-deriveable PeerID). FAIL-CLOSED: the peer is NEVER admitted.
    case quicHandshakePeerVerificationFailed

    /// The QUIC handshake did not complete within the configured deadline. The
    /// half-open connection is torn down, never handed back. FAIL-CLOSED.
    case quicHandshakeTimedOut

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

    // MARK: - Ping (`/ipfs/ping/1.0.0`)

    /// A ping echo did not byte-match the 32 bytes the client sent.
    /// FAIL-CLOSED: a mismatched echo is never accepted as a successful ping.
    case pingMismatch

    /// A ping echo ended (stream FIN / close) before the full 32-byte frame
    /// arrived. FAIL-CLOSED: a truncated echo is a failure, never a partial pass.
    case pingTruncated

    /// The entropy seam returned fewer than the 32 bytes the ping payload
    /// requires. FAIL-CLOSED: the node never sends a short / predictable ping.
    case pingEntropyFailed

    // MARK: - Identify (`/ipfs/id/1.0.0`)

    /// The Identify protobuf failed to decode (truncated / malformed framing).
    case identifyDecodeFailed

    /// The peer's Identify message carried no `publicKey` field, so its advertised
    /// identity cannot be bound to the handshake PeerID. FAIL-CLOSED.
    case identifyMissingPublicKey

    /// The PeerID derived from the Identify-advertised `publicKey` did not match the
    /// cryptographically-verified PeerID from the QUIC TLS 1.3 handshake.
    /// FAIL-CLOSED: the handshake identity always wins; an Identify message can
    /// NEVER re-assert a different identity than the one the handshake proved.
    case identifyPeerIDMismatch
}
