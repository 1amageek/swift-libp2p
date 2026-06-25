// IdentifyService.swift
// The libp2p identify protocol (`/ipfs/id/1.0.0`) over a `MuxedStream`. The server
// writes its Identify protobuf and half-closes; the client reads the whole message
// (delimited by FIN), decodes it, and FAIL-CLOSED binds the Identify-advertised
// `publicKey` to the cryptographically-verified handshake PeerID.
//
// Embedded-clean: monomorphic over `<C: CryptoProvider>`, `[UInt8]` currency, no
// `any`, typed throws, no try?/try!. The wire framing is the LibP2PCore
// `IdentifyFields` codec; the PeerID derivation is the cored
// `LibP2PIdentity.peerIDMultihash` over the SHA-256 seam.
//
// SECURITY INVARIANT: an Identify message can NEVER re-assert a peer identity
// different from the one the QUIC TLS 1.3 handshake cryptographically proved. The
// handshake PeerID always wins; a mismatch is rejected, never preferred.

import _Concurrency   // REQUIRED under Embedded for async/Task
import P2PCoreBytes
import P2PCoreCrypto   // CryptoProvider (SHA-256 seam)
import P2PCoreDER      // LibP2PIdentity (PeerID derivation)
import LibP2PCore      // IdentifyFields

/// Drives `/ipfs/id/1.0.0` over an already-negotiated ``MuxedStream``.
///
/// Monomorphic over the crypto seam `C` (its SHA-256 derives the PeerID from the
/// advertised public key). The protocol id is *not* negotiated here — the caller
/// negotiates `/ipfs/id/1.0.0` via ``MultistreamNegotiator`` first, then runs this
/// over the same stream.
public enum IdentifyService<C: CryptoProvider> {

    /// A safety bound on the inbound Identify message size (1 MiB), matching the
    /// codec's per-field bound. A peer cannot force an unbounded read.
    public static var maxMessageBytes: Int { 1_048_576 }

    // MARK: - Client

    /// Reads the peer's Identify message and binds it to the handshake PeerID.
    ///
    /// Reads the full message (the server half-closes after writing it), decodes the
    /// `IdentifyFields`, requires the `publicKey` field, derives its PeerID
    /// multihash, and compares it byte-for-byte against
    /// `verifiedPeerIDMultihash` — the PeerID the QUIC TLS 1.3 handshake proved.
    ///
    /// - Parameters:
    ///   - stream: An open mux stream over which `/ipfs/id/1.0.0` is already
    ///     negotiated; the peer writes its Identify and half-closes.
    ///   - verifiedPeerIDMultihash: The handshake-verified PeerID multihash of the
    ///     peer (from the RPK certificate). Must be non-empty: identity binding is
    ///     mandatory — an unauthenticated peer cannot be Identify-bound.
    /// - Returns: The decoded ``IdentifyFields`` once the advertised identity is
    ///   confirmed to match the handshake identity.
    /// - Throws: ``NodeError/identifyDecodeFailed`` on malformed framing,
    ///   ``NodeError/identifyMissingPublicKey`` if no `publicKey` is present,
    ///   ``NodeError/identifyPeerIDMismatch`` if the advertised key's PeerID does
    ///   not match the handshake PeerID (fail-closed), or a propagated stream
    ///   ``NodeError`` on I/O failure.
    public static func identify<S: MuxedStream>(
        on stream: S,
        verifiedPeerIDMultihash: [UInt8]
    ) async throws(NodeError) -> IdentifyFields {
        // A binding check requires a cryptographically-verified peer identity. If
        // the handshake produced none (e.g. an unauthenticated path), refuse rather
        // than bind to nothing — fail-closed.
        guard !verifiedPeerIDMultihash.isEmpty else {
            throw .identifyPeerIDMismatch
        }

        let raw = try await readToEnd(stream, max: Self.maxMessageBytes)

        let fields: IdentifyFields
        do {
            fields = try IdentifyFields.decode(from: raw)
        } catch {
            // `error` binds as `IdentifyCodecError`; bare catch (no cross-type `as`).
            throw .identifyDecodeFailed
        }

        guard let advertisedKey = fields.publicKey else {
            throw .identifyMissingPublicKey
        }

        // Derive the PeerID from the ADVERTISED key and compare it to the
        // HANDSHAKE-verified PeerID. The handshake identity always wins.
        let advertisedPeerID = try Self.derivePeerID(protobufPublicKey: advertisedKey)
        guard Self.bytesEqual(advertisedPeerID, verifiedPeerIDMultihash) else {
            throw .identifyPeerIDMismatch
        }

        return fields
    }

    // MARK: - Server

    /// Responds to an inbound identify request: writes this node's `IdentifyFields`
    /// and half-closes the stream (the FIN delimits the message for the client).
    ///
    /// - Parameters:
    ///   - stream: The inbound mux stream over which `/ipfs/id/1.0.0` is already
    ///     negotiated by the listener.
    ///   - fields: This node's Identify message (its public key, listen addrs,
    ///     supported protocols, agent/protocol versions). The caller assembles it
    ///     from the local ``NodeIdentity`` and configuration.
    /// - Throws: a propagated stream ``NodeError`` on I/O failure (fail-closed —
    ///   the handler does not swallow a write failure).
    public static func respond<S: MuxedStream>(
        on stream: S,
        fields: IdentifyFields
    ) async throws(NodeError) {
        let encoded = fields.encode()
        try await stream.write(encoded)
        // Half-close so the client's read-to-end terminates at the message boundary.
        await stream.close()
    }

    // MARK: - Private

    /// Derives the PeerID multihash from a protobuf-encoded public key over the
    /// SHA-256 seam, surfacing any derivation failure as a node error.
    private static func derivePeerID(
        protobufPublicKey: [UInt8]
    ) throws(NodeError) -> [UInt8] {
        do {
            return try LibP2PIdentity.peerIDMultihash(
                protobufPubKey: protobufPublicKey,
                sha256: { (data: [UInt8]) -> [UInt8] in C.SHA256.hash(data.span) }
            )
        } catch {
            // `error` binds as `LibP2PIdentityError` (unsupported key type / bad
            // protobuf); a non-deriveable identity cannot be bound — reject.
            throw .identifyPeerIDMismatch
        }
    }

    /// Reads the stream until a clean end-of-stream (empty read / FIN), bounded by
    /// `max`. The Identify wire has no outer length prefix — the message is the
    /// entire stream content, delimited by the peer's half-close.
    ///
    /// - Throws: ``NodeError/identifyDecodeFailed`` if the message exceeds `max`
    ///   (a malformed / abusive peer), or a propagated stream ``NodeError``.
    private static func readToEnd<S: MuxedStream>(
        _ stream: S, max: Int
    ) async throws(NodeError) -> [UInt8] {
        var out = [UInt8]()
        while true {
            let chunk = try await stream.read()
            if chunk.isEmpty {
                return out
            }
            if out.count + chunk.count > max {
                throw .identifyDecodeFailed
            }
            out.append(contentsOf: chunk)
        }
    }

    /// Constant-shape byte equality (avoids `Array.==` overload ambiguity under
    /// Embedded with `[UInt8]`).
    private static func bytesEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        for i in 0..<a.count where a[i] != b[i] {
            return false
        }
        return true
    }
}
