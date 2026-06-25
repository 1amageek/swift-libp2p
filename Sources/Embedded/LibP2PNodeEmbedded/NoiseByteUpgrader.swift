// NoiseByteUpgrader.swift
// Drives the libp2p Noise XX handshake over a raw `[UInt8]` connection, producing a
// `NoiseSecuredConnection`. Wraps the Embedded-clean `NoiseHandshakeCore<C>` and
// frames each handshake message with the 2-byte length prefix (`NoiseFraming`).
// FAIL-CLOSED: the remote identity signature is verified against the remote Noise
// static key; a failure throws and the connection is NOT established (no silent
// accept). Embedded-clean: monomorphic over `<R, C>`, `[UInt8]`, no `any`.
//
// XX pattern:
//   -> e
//   <- e, ee, s, es
//   -> s, se

import _Concurrency   // REQUIRED under Embedded for async/Task
import P2PCoreBytes
import P2PCoreCrypto
import LibP2PCore

/// Performs the Noise XX security upgrade over a raw connection.
///
/// Monomorphic over the raw connection `R` and crypto seam `C` (no `any`). The
/// caller supplies the local identity (to sign the static-key proof); the upgrader
/// generates the Noise static + ephemeral X25519 keys through the seam, runs the
/// three XX messages, verifies the remote identity fail-closed, and returns a
/// `NoiseSecuredConnection` carrying the verified remote identity public key.
public struct NoiseByteUpgrader<
    R: EmbeddedRawConnection,
    C: CryptoProvider
>: Sendable {

    private let raw: R
    private let identity: EmbeddedNodeIdentity<C>

    public init(raw: R, identity: EmbeddedNodeIdentity<C>) {
        self.raw = raw
        self.identity = identity
    }

    // MARK: - Dialer (initiator)

    /// Runs the XX handshake as the dialer and returns the secured connection.
    ///
    /// - Throws: ``EmbeddedNodeError`` (`noise*` cases) on any handshake / identity
    ///   failure (fail-closed).
    public func dial() async throws(EmbeddedNodeError) -> NoiseSecuredConnection<R, C> {
        var core = try makeCore(isInitiator: true)

        // -> e
        let msgA: [UInt8]
        do {
            msgA = try core.writeMessageA()
        } catch {
            throw .noiseHandshakeFailed
        }
        try await writeFramed(msgA)

        // <- e, ee, s, es
        let msgB = try await readFramed()
        let payloadB: NoisePayloadFields
        do {
            payloadB = try core.readMessageB(msgB)
        } catch {
            throw .noiseHandshakeFailed
        }
        try verifyRemote(payload: payloadB, core: core)

        // -> s, se
        let signedPayload = try makeSignedPayload(core: core)
        let msgC: [UInt8]
        do {
            msgC = try core.writeMessageC(payload: signedPayload)
        } catch {
            throw .noiseHandshakeFailed
        }
        try await writeFramed(msgC)

        return makeSecured(core: core, remoteIdentity: payloadB.identityKey)
    }

    // MARK: - Listener (responder)

    /// Runs the XX handshake as the listener and returns the secured connection.
    ///
    /// - Throws: ``EmbeddedNodeError`` (`noise*` cases) on any handshake / identity
    ///   failure (fail-closed).
    public func listen() async throws(EmbeddedNodeError) -> NoiseSecuredConnection<R, C> {
        var core = try makeCore(isInitiator: false)

        // -> e
        let msgA = try await readFramed()
        do {
            try core.readMessageA(msgA)
        } catch {
            throw .noiseHandshakeFailed
        }

        // <- e, ee, s, es
        let signedPayload = try makeSignedPayload(core: core)
        let msgB: [UInt8]
        do {
            msgB = try core.writeMessageB(payload: signedPayload)
        } catch {
            throw .noiseHandshakeFailed
        }
        try await writeFramed(msgB)

        // -> s, se
        let msgC = try await readFramed()
        let payloadC: NoisePayloadFields
        do {
            payloadC = try core.readMessageC(msgC)
        } catch {
            throw .noiseHandshakeFailed
        }
        try verifyRemote(payload: payloadC, core: core)

        return makeSecured(core: core, remoteIdentity: payloadC.identityKey)
    }

    // MARK: - Private

    private func makeCore(isInitiator: Bool) throws(EmbeddedNodeError) -> NoiseHandshakeCore<C> {
        // Generate the Noise static + ephemeral X25519 keys through the seam.
        let staticPriv: C.X25519.PrivateKey
        let ephemeralPriv: C.X25519.PrivateKey
        do {
            staticPriv = try C.X25519.generatePrivateKey()
            ephemeralPriv = try C.X25519.generatePrivateKey()
        } catch {
            throw .noiseHandshakeFailed
        }
        let staticRaw = C.X25519.rawRepresentation(of: staticPriv)
        let ephemeralRaw = C.X25519.rawRepresentation(of: ephemeralPriv)

        let core: NoiseHandshakeCore<C>
        do {
            core = try NoiseHandshakeCore<C>(
                staticPrivateKeyRaw: staticRaw,
                ephemeralPrivateKeyRaw: ephemeralRaw,
                isInitiator: isInitiator,
                protocolName: [UInt8](NoiseFraming.protocolName.utf8)
            )
        } catch {
            throw .noiseHandshakeFailed
        }
        return core
    }

    /// Builds the signed handshake payload: the local identity public key plus the
    /// signature over `"noise-libp2p-static-key:" || localStaticKey`.
    private func makeSignedPayload(core: NoiseHandshakeCore<C>) throws(EmbeddedNodeError) -> [UInt8] {
        var signed = [UInt8](NoiseFraming.staticKeySignaturePrefix.utf8)
        signed.append(contentsOf: core.localStaticPublicKey)
        let signature = try identity.sign(signed)
        let fields = NoisePayloadFields(
            identityKey: identity.protobufPublicKey,
            identitySig: signature,
            data: []
        )
        return fields.encode()
    }

    /// Verifies the remote identity against the remote Noise static key, fail-closed.
    private func verifyRemote(
        payload: NoisePayloadFields, core: NoiseHandshakeCore<C>
    ) throws(EmbeddedNodeError) {
        guard let remoteStatic = core.remoteStaticPublicKey else {
            throw .noiseHandshakeFailed
        }
        _ = try NoiseIdentityVerification<C>.verify(
            payload: payload, noiseStaticPublicKey: remoteStatic
        )
    }

    private func makeSecured(
        core: NoiseHandshakeCore<C>, remoteIdentity: [UInt8]
    ) -> NoiseSecuredConnection<R, C> {
        let (send, recv) = core.split()
        return NoiseSecuredConnection(
            raw: raw,
            sendCipher: send,
            recvCipher: recv,
            remoteIdentityPublicKey: remoteIdentity
        )
    }

    // MARK: - Framed handshake I/O

    private func writeFramed(_ message: [UInt8]) async throws(EmbeddedNodeError) {
        let frame: [UInt8]
        do {
            frame = try NoiseFraming.encode(message)
        } catch {
            throw .noiseFramingFailed
        }
        try await raw.write(frame)
    }

    /// Reads one length-prefixed handshake message, accumulating partial reads.
    private func readFramed() async throws(EmbeddedNodeError) -> [UInt8] {
        var buffer = [UInt8]()
        while true {
            let framed: (message: [UInt8], consumed: Int)?
            do {
                framed = try NoiseFraming.read(from: buffer)
            } catch {
                throw .noiseFramingFailed
            }
            if let framed {
                return framed.message
            }
            let chunk = try await raw.read()
            if chunk.isEmpty {
                throw .unexpectedEndOfStream
            }
            buffer.append(contentsOf: chunk)
        }
    }
}
