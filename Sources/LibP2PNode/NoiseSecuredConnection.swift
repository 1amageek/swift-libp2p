// NoiseSecuredConnection.swift
// A Noise-secured `[UInt8]` connection: wraps a raw connection with the post-
// handshake transport cipher states, length-prefix-framing each encrypted message.
// Conforms to `RawConnection` so the mux (Yamux) and negotiation
// (multistream-select) run over it unchanged. Embedded-clean: actor-isolated
// cipher state (Embedded-OK), `[UInt8]` currency, no `any`, no Foundation.

import _Concurrency   // REQUIRED under Embedded for async/Task
import P2PCoreBytes
import P2PCoreCrypto
import LibP2PCore

/// A Noise transport-encrypted byte stream over a raw connection.
///
/// After the XX handshake, traffic is split into two `NoiseCipherStateCore<C>`
/// (send / recv). Every application write is sealed and framed with a 2-byte
/// big-endian length prefix (`NoiseFraming`); reads reassemble frames, decrypt,
/// and surface plaintext. The cipher states advance a nonce per message, so all
/// mutation is serialised on this actor.
public final actor NoiseSecuredConnection<
    R: RawConnection,
    C: CryptoProvider
>: RawConnection {

    private let raw: R
    private var sendCipher: NoiseCipherStateCore<C>
    private var recvCipher: NoiseCipherStateCore<C>

    /// Buffered inbound ciphertext bytes not yet forming a complete frame.
    private var inboundBuffer: [UInt8]
    /// Decrypted plaintext ready to hand to the next `read()`.
    private var plaintextBuffer: [UInt8]
    private var closed: Bool

    /// The verified remote identity public key (protobuf-encoded). The PeerID is
    /// derived from this; it is present precisely because the handshake verified it.
    ///
    /// `nonisolated`: an immutable `Sendable` value fixed at handshake completion,
    /// so it is safe to read synchronously from outside the actor.
    public nonisolated let remoteIdentityPublicKey: [UInt8]

    init(
        raw: R,
        sendCipher: NoiseCipherStateCore<C>,
        recvCipher: NoiseCipherStateCore<C>,
        remoteIdentityPublicKey: [UInt8]
    ) {
        self.raw = raw
        self.sendCipher = sendCipher
        self.recvCipher = recvCipher
        self.remoteIdentityPublicKey = remoteIdentityPublicKey
        self.inboundBuffer = []
        self.plaintextBuffer = []
        self.closed = false
    }

    // MARK: - RawConnection

    public func read() async throws(NodeError) -> [UInt8] {
        if !plaintextBuffer.isEmpty {
            let out = plaintextBuffer
            plaintextBuffer = []
            return out
        }
        if closed {
            throw .connectionClosed
        }

        while true {
            // Try to decode + decrypt one complete frame from the inbound buffer.
            let framed: (message: [UInt8], consumed: Int)?
            do {
                framed = try NoiseFraming.read(from: inboundBuffer)
            } catch {
                throw .noiseFramingFailed
            }
            if let framed {
                inboundBuffer.removeFirst(framed.consumed)
                let plaintext: [UInt8]
                do {
                    plaintext = try recvCipher.decryptWithAD([], ciphertext: framed.message)
                } catch {
                    // A tag mismatch or backend failure aborts the connection
                    // (fail-closed; never surface garbage).
                    throw .noiseHandshakeFailed
                }
                return plaintext
            }

            // Need more ciphertext.
            let chunk = try await raw.read()
            if chunk.isEmpty {
                closed = true
                throw .unexpectedEndOfStream
            }
            inboundBuffer.append(contentsOf: chunk)
        }
    }

    public func write(_ data: [UInt8]) async throws(NodeError) {
        if closed {
            throw .connectionClosed
        }
        // Chunk to the Noise max plaintext size so each frame fits the 2-byte prefix.
        var offset = 0
        var out = [UInt8]()
        while offset < data.count {
            let end = min(offset + NoiseFraming.maxPlaintextSize, data.count)
            let plaintext = Array(data[offset..<end])
            offset = end

            let ciphertext: [UInt8]
            do {
                ciphertext = try sendCipher.encryptWithAD([], plaintext: plaintext)
            } catch {
                throw .noiseHandshakeFailed
            }
            let frame: [UInt8]
            do {
                frame = try NoiseFraming.encode(ciphertext)
            } catch {
                throw .noiseFramingFailed
            }
            out.append(contentsOf: frame)
        }
        if data.isEmpty {
            // Preserve a zero-length write as a single empty encrypted frame so the
            // peer observes the boundary (no silent drop).
            let ciphertext: [UInt8]
            do {
                ciphertext = try sendCipher.encryptWithAD([], plaintext: [])
            } catch {
                throw .noiseHandshakeFailed
            }
            let frame: [UInt8]
            do {
                frame = try NoiseFraming.encode(ciphertext)
            } catch {
                throw .noiseFramingFailed
            }
            out.append(contentsOf: frame)
        }
        try await raw.write(out)
    }

    public func close() async {
        closed = true
        await raw.close()
    }
}
