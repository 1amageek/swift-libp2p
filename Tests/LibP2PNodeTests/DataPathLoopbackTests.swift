// DataPathLoopbackTests.swift
// In-process round-trip of the data path: two pipe ends → Noise XX
// security (mutual fail-closed identity verification) → Yamux [UInt8] mux →
// multistream-select negotiation → stream byte round-trip. This is the host-
// runnable loopback the milestone asks for (transport → Noise → Yamux →
// negotiation, in-process).

import Testing
import P2PCrypto
import P2PCryptoFoundationEssentials
import QUICTLSSignature
import LibP2PCore
@testable import LibP2PNode

private typealias Provider = QUICTLSSignatureProvider

@Suite("data-path loopback")
struct DataPathLoopbackTests {

    @Test("Noise XX secures a pipe and traffic round-trips both ways")
    func noiseSecuresPipe() async throws {
        let (clientEnd, serverEnd) = PipeConnection.makePair()
        let clientID = try NodeIdentity<Provider>.generate()
        let serverID = try NodeIdentity<Provider>.generate()

        let dialer = NoiseUpgrader<PipeConnection, Provider>(raw: clientEnd, identity: clientID)
        let listener = NoiseUpgrader<PipeConnection, Provider>(raw: serverEnd, identity: serverID)

        async let clientSecured = dialer.dial()
        async let serverSecured = listener.listen()
        let client = try await clientSecured
        let server = try await serverSecured

        // Each side verified the OTHER's identity public key.
        #expect(client.remoteIdentityPublicKey == serverID.protobufPublicKey)
        #expect(server.remoteIdentityPublicKey == clientID.protobufPublicKey)

        // Encrypted round-trip both ways.
        let ping: [UInt8] = Array("hello-from-client".utf8)
        try await client.write(ping)
        let gotPing = try await readExactly(server, count: ping.count)
        #expect(gotPing == ping)

        let pong: [UInt8] = Array("hello-from-server".utf8)
        try await server.write(pong)
        let gotPong = try await readExactly(client, count: pong.count)
        #expect(gotPong == pong)

        await client.close()
        await server.close()
    }

    @Test("Full stack: Noise → Yamux → multistream-select → stream echo")
    func fullStackRoundTrip() async throws {
        let (clientEnd, serverEnd) = PipeConnection.makePair()
        let clientID = try NodeIdentity<Provider>.generate()
        let serverID = try NodeIdentity<Provider>.generate()

        let dialer = NoiseUpgrader<PipeConnection, Provider>(raw: clientEnd, identity: clientID)
        let listener = NoiseUpgrader<PipeConnection, Provider>(raw: serverEnd, identity: serverID)
        async let cs = dialer.dial()
        async let ss = listener.listen()
        let clientSecured = try await cs
        let serverSecured = try await ss

        // Yamux over the secured connections.
        let clientMux = YamuxMuxer(raw: clientSecured, isInitiator: true)
        let serverMux = YamuxMuxer(raw: serverSecured, isInitiator: false)
        let clientRun = Task { await clientMux.run() }
        let serverRun = Task { await serverMux.run() }

        let proto = "/echo/1.0.0"
        let clock = TestClock()

        // Server: accept a stream, negotiate, echo one message.
        let serverWork = Task { () -> Bool in
            let stream = try await serverMux.accept()
            let negotiator = MultistreamNegotiator(connection: StreamRawAdapter(stream), timer: clock)
            let agreed = try await negotiator.listen(supported: [proto])
            guard agreed == proto else { return false }
            let msg = try await stream.read()
            try await stream.write(msg)   // echo
            return true
        }

        // Client: open a stream, negotiate, send + read echo.
        let clientStream = try await clientMux.open()
        let clientNeg = MultistreamNegotiator(connection: StreamRawAdapter(clientStream), timer: clock)
        try await clientNeg.dial(proto)

        let payload: [UInt8] = Array("multiplexed-echo-payload".utf8)
        try await clientStream.write(payload)
        let echoed = try await readExactlyStream(clientStream, count: payload.count)
        #expect(echoed == payload)

        let serverOK = try await serverWork.value
        #expect(serverOK)

        await clientMux.close()
        await serverMux.close()
        clientRun.cancel()
        serverRun.cancel()
    }

    @Test("Identity verification accepts a correctly-signed payload")
    func identityVerificationAccepts() throws {
        let id = try NodeIdentity<Provider>.generate()
        // A Noise static key the identity signs ownership of.
        let staticKey = [UInt8](repeating: 0x42, count: 32)

        var signed = [UInt8](NoiseFraming.staticKeySignaturePrefix.utf8)
        signed.append(contentsOf: staticKey)
        let sig = try id.sign(signed)

        let payload = NoisePayloadFields(identityKey: id.protobufPublicKey, identitySig: sig, data: [])
        let verifiedKey = try NoiseIdentityVerification<Provider>.verify(
            payload: payload, noiseStaticPublicKey: staticKey
        )
        #expect(verifiedKey == id.protobufPublicKey)
    }

    @Test("Identity verification rejects a wrong-key signature (fail-closed)")
    func identityVerificationRejectsForged() throws {
        let advertised = try NodeIdentity<Provider>.generate()
        let attacker = try NodeIdentity<Provider>.generate()
        let staticKey = [UInt8](repeating: 0x77, count: 32)

        // Sign with the ATTACKER's key but advertise the victim's identity key.
        var signed = [UInt8](NoiseFraming.staticKeySignaturePrefix.utf8)
        signed.append(contentsOf: staticKey)
        let forgedSig = try attacker.sign(signed)

        let payload = NoisePayloadFields(identityKey: advertised.protobufPublicKey, identitySig: forgedSig, data: [])
        #expect(throws: NodeError.noiseIdentityVerificationFailed) {
            _ = try NoiseIdentityVerification<Provider>.verify(
                payload: payload, noiseStaticPublicKey: staticKey
            )
        }
    }

    @Test("Identity verification rejects a signature over a different static key")
    func identityVerificationRejectsWrongStaticKey() throws {
        let id = try NodeIdentity<Provider>.generate()
        let signedKey = [UInt8](repeating: 0x11, count: 32)
        let presentedKey = [UInt8](repeating: 0x22, count: 32)

        var signed = [UInt8](NoiseFraming.staticKeySignaturePrefix.utf8)
        signed.append(contentsOf: signedKey)
        let sig = try id.sign(signed)

        let payload = NoisePayloadFields(identityKey: id.protobufPublicKey, identitySig: sig, data: [])
        // Verify against a DIFFERENT static key than the one signed.
        #expect(throws: NodeError.noiseIdentityVerificationFailed) {
            _ = try NoiseIdentityVerification<Provider>.verify(
                payload: payload, noiseStaticPublicKey: presentedKey
            )
        }
    }
}

// MARK: - Helpers

/// Bridges an `MuxedStream` to the `RawConnection` surface the
/// negotiator consumes.
struct StreamRawAdapter<S: MuxedStream>: RawConnection {
    let stream: S
    init(_ stream: S) { self.stream = stream }
    func read() async throws(NodeError) -> [UInt8] { try await stream.read() }
    func write(_ data: [UInt8]) async throws(NodeError) { try await stream.write(data) }
    func close() async { await stream.close() }
}

private func readExactly(
    _ conn: NoiseSecuredConnection<PipeConnection, Provider>, count: Int
) async throws -> [UInt8] {
    var out = [UInt8]()
    while out.count < count {
        let chunk = try await conn.read()
        if chunk.isEmpty { break }
        out.append(contentsOf: chunk)
    }
    return out
}

private func readExactlyStream<S: MuxedStream>(
    _ stream: S, count: Int
) async throws -> [UInt8] {
    var out = [UInt8]()
    while out.count < count {
        let chunk = try await stream.read()
        if chunk.isEmpty { break }
        out.append(contentsOf: chunk)
    }
    return out
}
