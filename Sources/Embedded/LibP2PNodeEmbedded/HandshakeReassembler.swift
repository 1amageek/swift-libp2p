// HandshakeReassembler.swift
// Reassembles the ordered CRYPTO-stream bytes the QUIC engine delivers per
// encryption level into complete TLS handshake messages. The engine hands out
// ordered `HandshakeChunk`s (level + bytes); a single TLS handshake message can
// span multiple chunks, and a single chunk can carry multiple messages. This
// buffers per level and yields one complete handshake message at a time (header +
// declared content), or `nil` when the level's buffer holds only a partial message.
//
// Embedded-clean: `[UInt8]` currency, no Foundation, no `any`, typed throws, bare
// `catch` (no catch-as-typed).

import QUICWire        // EncryptionLevel
import QUICTLSCore     // HandshakeMessageCodec / HandshakeType / TLSWireError

/// Per-level reassembly of the QUIC CRYPTO stream into complete handshake messages.
struct HandshakeReassembler {

    /// A fully reassembled handshake message.
    struct Message {
        /// The message type (ClientHello / ServerHello / Finished / …).
        let type: HandshakeType
        /// The message content (without the 4-byte handshake header).
        let content: [UInt8]
        /// The complete handshake-message bytes (header + content) — the form the
        /// cored FSMs fold into their transcript.
        let raw: [UInt8]
    }

    /// Pending CRYPTO bytes at the Initial level.
    private var initialBuffer: [UInt8] = []
    /// Pending CRYPTO bytes at the Handshake level.
    private var handshakeBuffer: [UInt8] = []

    /// Appends ordered CRYPTO bytes for `level`.
    mutating func append(level: EncryptionLevel, bytes: [UInt8]) {
        switch level {
        case .initial:
            initialBuffer.append(contentsOf: bytes)
        case .handshake:
            handshakeBuffer.append(contentsOf: bytes)
        case .zeroRTT, .application:
            // The minimal node never carries handshake CRYPTO at these levels; drop
            // (the engine only surfaces handshake CRYPTO at Initial/Handshake).
            break
        }
    }

    /// Takes one complete handshake message from `level`'s buffer, or `nil` if the
    /// buffer holds fewer than one complete message.
    ///
    /// - Throws: ``EmbeddedNodeError/quicHandshakeFailed`` on a malformed handshake
    ///   header (fail-closed — never a silently mis-parsed message).
    mutating func takeMessage(
        level: EncryptionLevel
    ) throws(EmbeddedNodeError) -> Message? {
        // Copy the level's buffer to a local (avoids an exclusivity violation from
        // passing `inout self.field` while `self` is being mutated). The local is
        // written back only if a message is consumed.
        var buffer: [UInt8]
        switch level {
        case .initial:
            buffer = initialBuffer
        case .handshake:
            buffer = handshakeBuffer
        case .zeroRTT, .application:
            return nil
        }

        guard buffer.count >= HandshakeMessageCodec.headerLength else {
            return nil
        }
        let decoded: (type: HandshakeType, content: [UInt8], consumed: Int)
        do {
            decoded = try HandshakeMessageCodec.decodeMessage(from: buffer)
        } catch {
            // `error` binds as `TLSWireError`; a truncated message (insufficientData)
            // means we need more bytes — that is not a failure, it is `nil`. Any
            // other wire error is a malformed header → fail-closed.
            switch error {
            case .insufficientData:
                return nil
            default:
                throw EmbeddedNodeError.quicHandshakeFailed
            }
        }
        let raw = Array(buffer[0..<decoded.consumed])
        buffer.removeFirst(decoded.consumed)

        // Write the consumed buffer back.
        switch level {
        case .initial:
            initialBuffer = buffer
        case .handshake:
            handshakeBuffer = buffer
        case .zeroRTT, .application:
            break
        }
        return Message(type: decoded.type, content: decoded.content, raw: raw)
    }
}
