// QUICTLSHandshakeDriver.swift
// The libp2p-over-QUIC TLS 1.3 handshake driver: it runs swift-quic's cored TLS
// 1.3 FSMs (`QUICClientHandshake` / `QUICServerHandshake` / `QUICClientAuthMachine`)
// as the handshake engine and hands the produced CRYPTO bytes + secrets to the
// `QUICEngineClient` TLS seam (`takeHandshakeData` → ingest → `queueHandshake` /
// `installKeys` / `applyPeerTransportParameters` / `markHandshakeComplete`).
//
// The cored FSMs are NEGOTIATION-LEAN: they own the transcript + key schedule and
// the security-critical checks (binder, CertificateVerify, Finished MAC) but leave
// extension assembly, ephemeral (EC)DHE, inbound-message parsing, and the libp2p
// RPK identity to this driver. This driver supplies exactly those, using:
//   * `C: CryptoProvider` for x25519 ECDHE + P-256 CertificateVerify sign/verify,
//   * the Embedded-clean `QUICTLSCore` wire codecs for messages/extensions,
//   * `LibP2PRPKCertificateBuilder<C>` for the libp2p cert (build + fail-closed
//     verify → verified PeerID).
//
// There is NO Noise / Yamux on the QUIC path: QUIC's native TLS 1.3 (with the
// libp2p RPK cert in the handshake) provides BOTH security (PeerID via the cert)
// and stream multiplexing (QUIC native streams). Noise/Yamux are the TCP-path
// primitives only.
//
// Embedded-clean: monomorphic over `<C, Transport, Timer>`, `[UInt8]` currency,
// no `any`, no Foundation, no String(describing:), typed throws (no try?/try!),
// bare `catch` (no catch-as-typed). The driver POLLS the engine seam (the engine's
// run loop does datagram I/O + timers only; it never calls a TLS callback).

import _Concurrency   // REQUIRED under Embedded for async/Task
import P2PCoreBytes
import P2PCoreCrypto
import P2PCoreTransport           // DatagramTransport / SocketEndpoint
import QUIC                       // QUICEngineClient
import QUICConnectionEngineCore   // HandshakeChunk
import QUICConnectionCore         // TransportParametersCore / TransportParameterCodecCore
import QUICPacketProtectionCore   // QUICProtectionSuite
import QUICWire                   // EncryptionLevel
import QUICTLSCore                // the cored TLS 1.3 FSMs + wire codecs
import P2PCoreDER                 // SubjectPublicKeyInfoDER

/// The outcome of a completed libp2p-over-QUIC TLS 1.3 handshake.
public struct QUICHandshakeResult: Sendable {
    /// The remote peer's verified PeerID multihash (extracted from the RPK cert
    /// after the in-handshake proof-of-possession + CertificateVerify checks).
    public let peerIDMultihash: [UInt8]
}

/// Drives the QUIC TLS 1.3 handshake over the `QUICEngineClient` seam.
///
/// Monomorphic over the crypto seam `C`, the datagram `Transport`, and the `Timer`
/// — the same three seams the engine facade carries.
public enum QUICTLSHandshakeDriver<
    C: CryptoProvider,
    Transport: DatagramTransport,
    Timer: AsyncTimer
> {

    // MARK: - Shared parameters

    /// The TLS 1.3 cipher suite the minimal node negotiates: AES-128-GCM-SHA256
    /// (RFC 9001 mandatory-to-implement). The ChaCha20/AES-256 suites are offered
    /// neither by the client nor selected by the server on this minimal path.
    private static var cipherSuiteWire: CipherSuite { .tls_aes_128_gcm_sha256 }
    private static var cipherSuiteCore: TLSCipherSuiteCore { .aes128GCMSHA256 }
    private static var protectionSuite: QUICProtectionSuite { .aes128GCM }

    /// The single ECDHE group the minimal node uses: x25519 (RFC 9001 §4.4.4).
    private static var group: NamedGroup { .x25519 }

    /// The ALPN the libp2p QUIC transport negotiates.
    private static var alpn: String { "libp2p" }

    /// The CertificateVerify signature scheme for the ephemeral P-256 leaf key.
    /// Qualified: `SignatureScheme` is also a `P2PCoreCrypto` protocol; here it is
    /// the `QUICTLSCore` wire enum.
    private static var certVerifyScheme: QUICTLSCore.SignatureScheme { .ecdsa_secp256r1_sha256 }

    // MARK: - Client

    /// Drives the client side of the handshake to completion over `client`.
    ///
    /// Pumps the engine seam in a loop: produce ClientHello → install handshake +
    /// application keys as the FSMs derive them → parse the server flight (with the
    /// fail-closed RPK + CertificateVerify checks) → send the client Finished →
    /// mark complete. Bounded by `deadlineNanos` (fail-closed on timeout).
    ///
    /// - Throws: a typed ``EmbeddedNodeError`` on any failure (NEVER a half-open
    ///   connection — the caller tears down on a throw).
    public static func runClient(
        client: QUICEngineClient<Transport, Timer>,
        identity: EmbeddedNodeIdentity<C>,
        localTransportParameters: TransportParametersCore,
        timer: Timer,
        deadlineNanos: UInt64,
        replayBuffered: @Sendable @escaping () -> Void
    ) async throws(EmbeddedNodeError) -> QUICHandshakeResult {

        // 1. Ephemeral x25519 key share.
        let ecdhePrivate: C.X25519.PrivateKey
        do {
            ecdhePrivate = try C.X25519.generatePrivateKey()
        } catch {
            throw .quicHandshakeKeyExchangeFailed
        }
        let ecdhePublic = C.X25519.publicKey(for: ecdhePrivate)
        let clientShareBytes = C.X25519.rawRepresentation(of: ecdhePublic)

        // The minimal client does NOT authenticate to the server (no mTLS on this
        // slice): the server does not send a CertificateRequest, so the client
        // presents no libp2p RPK certificate. `identity` is reserved for the future
        // mutual-auth slice (the client would then build + present its own RPK leaf).
        _ = identity

        // 2. Assemble + produce ClientHello.
        var handshake = QUICClientHandshake<C>(cipherSuite: cipherSuiteCore)
        let random = C.random.randomBytes(32)
        let extensions = clientHelloExtensions(
            clientShareBytes: clientShareBytes,
            localTransportParameters: localTransportParameters
        )
        let clientHelloBytes: [UInt8]
        do {
            (clientHelloBytes, _) = try handshake.produceClientHello(
                random: random,
                legacySessionID: [],
                cipherSuites: [cipherSuiteWire],
                extensions: extensions,
                offeredPsks: nil,
                pskBinder: nil,
                attemptEarlyData: false
            )
        } catch {
            throw .quicHandshakeFailed
        }
        await client.queueHandshake(clientHelloBytes, level: .initial)

        // 4. Pull the server flight: ServerHello (Initial) then EE..Finished
        //    (Handshake). Accumulate per-level CRYPTO bytes and process records as
        //    they complete.
        var reassembler = HandshakeReassembler()
        var authMachine: QUICClientAuthMachine<C>? = nil
        var peerLeafKeyBytes: [UInt8]? = nil
        var peerIDMultihash: [UInt8]? = nil

        while true {
            if timer.monotonicNanos() >= deadlineNanos {
                throw .quicHandshakeTimedOut
            }
            let chunks = client.takeHandshakeData()
            if chunks.isEmpty {
                if client.isClosed { throw .quicHandshakeFailed }
                do { try await timer.sleep(untilNanos: timer.monotonicNanos() &+ 2_000_000) }
                catch { throw .quicHandshakeFailed }
                continue
            }

            for chunk in chunks {
                reassembler.append(level: chunk.level, bytes: chunk.data)
            }

            // ServerHello at Initial.
            if handshake.currentState == .waitServerHello {
                guard let message = try reassembler.takeMessage(level: .initial) else {
                    continue
                }
                guard message.type == .serverHello else {
                    throw .quicHandshakeFailed
                }
                try ingestServerHello(
                    handshake: &handshake,
                    rawMessage: message.raw,
                    content: message.content,
                    ecdhePrivate: ecdhePrivate
                )
                // Install handshake keys (read = server, write = client).
                guard let clientHS = handshake.clientHandshakeSecret,
                      let serverHS = handshake.serverHandshakeSecret else {
                    throw .quicHandshakeFailed
                }
                do {
                    try client.installKeys(
                        level: .handshake,
                        readSecret: serverHS,
                        writeSecret: clientHS,
                        suite: protectionSuite
                    )
                } catch {
                    throw .quicHandshakeFailed
                }
                // Replay buffered datagrams: the server's Handshake-level packets
                // may have arrived (and been dropped by the engine) BEFORE these
                // read keys existed. Re-feeding them lets the engine decrypt them now
                // (RFC 9001 §5.7), avoiding a deadlock the engine's PING-only PTO
                // probe would not recover from.
                replayBuffered()
                do {
                    authMachine = try handshake.makeAuthMachine()
                } catch {
                    throw .quicHandshakeFailed
                }
            }

            // Server Handshake flight: EncryptedExtensions, Certificate,
            // CertificateVerify, Finished — at the Handshake level.
            if var auth = authMachine {
                let outcome = try driveClientAuth(
                    client: client,
                    auth: &auth,
                    reassembler: &reassembler,
                    peerLeafKeyBytes: &peerLeafKeyBytes,
                    peerIDMultihash: &peerIDMultihash
                )
                authMachine = auth
                if outcome == .serverFinishedProcessed {
                    // Install application keys (read = server, write = client).
                    guard let clientApp = auth.clientApplicationSecret,
                          let serverApp = auth.serverApplicationSecret else {
                        throw .quicHandshakeFailed
                    }
                    // Produce the client Finished BEFORE installing 1-RTT write
                    // keys — but the client Finished is sent at the HANDSHAKE level,
                    // so install app keys first, then send Finished at handshake.
                    let clientFinished: [UInt8]
                    do {
                        clientFinished = try auth.produceClientFinished()
                    } catch {
                        throw .quicHandshakeFailed
                    }
                    authMachine = auth
                    await client.queueHandshake(clientFinished, level: .handshake)
                    do {
                        try client.installKeys(
                            level: .application,
                            readSecret: serverApp,
                            writeSecret: clientApp,
                            suite: protectionSuite
                        )
                    } catch {
                        throw .quicHandshakeFailed
                    }
                    await client.markHandshakeComplete()
                    guard let verifiedPeer = peerIDMultihash else {
                        // The peer must have been verified (cert presented + checked)
                        // before the server Finished; a missing PeerID is fail-closed.
                        throw .quicHandshakePeerVerificationFailed
                    }
                    return QUICHandshakeResult(peerIDMultihash: verifiedPeer)
                }
            }
        }
    }

    // MARK: - Server

    /// Drives the server side of the handshake to completion over `server`.
    ///
    /// Waits for the ClientHello (Initial), produces the full server flight
    /// (ServerHello + EncryptedExtensions + Certificate(RPK) + CertificateVerify +
    /// Finished), installs handshake + application keys, then waits for the client
    /// Finished and marks complete. Bounded by `deadlineNanos` (fail-closed).
    ///
    /// - Note: the minimal node does NOT request a client certificate (no mTLS),
    ///   so the client is unauthenticated at the TLS layer. Mutual libp2p
    ///   authentication on the QUIC path is a later slice; here the SERVER proves
    ///   its PeerID to the client, and the client learns the server's verified
    ///   PeerID. The server therefore returns no peer PeerID.
    public static func runServer(
        server: QUICEngineClient<Transport, Timer>,
        identity: EmbeddedNodeIdentity<C>,
        localTransportParameters: TransportParametersCore,
        timer: Timer,
        deadlineNanos: UInt64,
        replayBuffered: @Sendable @escaping () -> Void
    ) async throws(EmbeddedNodeError) -> QUICHandshakeResult {

        var handshake = QUICServerHandshake<C>(cipherSuite: cipherSuiteCore)
        var reassembler = HandshakeReassembler()
        var flightSent = false

        while true {
            if timer.monotonicNanos() >= deadlineNanos {
                throw .quicHandshakeTimedOut
            }
            let chunks = server.takeHandshakeData()
            if chunks.isEmpty {
                if server.isClosed { throw .quicHandshakeFailed }
                do { try await timer.sleep(untilNanos: timer.monotonicNanos() &+ 2_000_000) }
                catch { throw .quicHandshakeFailed }
                continue
            }
            for chunk in chunks {
                reassembler.append(level: chunk.level, bytes: chunk.data)
            }

            // 1. ClientHello (Initial) → server flight.
            if !flightSent {
                guard let message = try reassembler.takeMessage(level: .initial) else {
                    continue
                }
                guard message.type == .clientHello else {
                    throw .quicHandshakeFailed
                }
                try await produceServerFlight(
                    server: server,
                    handshake: &handshake,
                    clientHelloRaw: message.raw,
                    clientHelloContent: message.content,
                    identity: identity,
                    localTransportParameters: localTransportParameters,
                    timer: timer
                )
                flightSent = true
                // Replay any buffered datagrams now that handshake read keys exist,
                // in case a client handshake-level packet arrived early (symmetry
                // with the client's post-key-install replay).
                replayBuffered()
                continue
            }

            // 2. Client Finished (Handshake).
            guard let message = try reassembler.takeMessage(level: .handshake) else {
                continue
            }
            guard message.type == .finished else {
                throw .quicHandshakeFailed
            }
            let finished: Finished
            do {
                finished = try Finished.decode(from: message.content)
            } catch {
                throw .quicHandshakeFailed
            }
            do {
                try handshake.ingestClientFinished(verifyData: finished.verifyData)
            } catch {
                throw .quicHandshakeFailed
            }
            await server.markHandshakeComplete()
            // The minimal server does not authenticate the client (no mTLS), so it
            // returns its own identity's PeerID as a placeholder is wrong — return
            // an empty peer (the client is unauthenticated). Callers that need a
            // mutually-verified PeerID use a later mTLS slice.
            return QUICHandshakeResult(peerIDMultihash: [])
        }
    }

    // MARK: - Client helpers

    /// Decodes the QUIC transport parameters from a peer's extension list and
    /// applies them to the engine (RFC 9000 §18.2). The `quic_transport_parameters`
    /// extension MUST be present in a QUIC handshake — fail-closed if absent.
    private static func applyPeerTransportParameters(
        client: QUICEngineClient<Transport, Timer>,
        extensions: [TLSExtension]
    ) throws(EmbeddedNodeError) {
        var tpBytes: [UInt8]? = nil
        for ext in extensions {
            if case .quicTransportParameters(let bytes) = ext {
                tpBytes = bytes
                break
            }
        }
        guard let tpBytes else {
            // A QUIC peer MUST send transport parameters; their absence is fatal.
            throw .quicHandshakeFailed
        }
        let peerTP: TransportParametersCore
        do {
            peerTP = try TransportParameterCodecCore.decode(tpBytes)
        } catch {
            throw .quicHandshakeFailed
        }
        client.applyPeerTransportParameters(peerTP)
    }

    private static func clientHelloExtensions(
        clientShareBytes: [UInt8],
        localTransportParameters: TransportParametersCore
    ) -> [TLSExtension] {
        let tpBytes = TransportParameterCodecCore.encode(localTransportParameters)
        return [
            .supportedVersionsClient([0x0304]),                 // TLS 1.3
            .supportedGroupsList([group]),
            .signatureAlgorithmsList([certVerifyScheme, .ed25519]),
            .keyShareClient([KeyShareEntry(group: group, keyExchange: clientShareBytes)]),
            .alpnProtocols([alpn]),
            .quicTransportParameters(tpBytes),
        ]
    }

    private static func ingestServerHello(
        handshake: inout QUICClientHandshake<C>,
        rawMessage: [UInt8],
        content: [UInt8],
        ecdhePrivate: C.X25519.PrivateKey
    ) throws(EmbeddedNodeError) {
        let serverHello: ServerHello
        do {
            serverHello = try ServerHello.decode(from: content)
        } catch {
            throw .quicHandshakeFailed
        }
        if serverHello.isHelloRetryRequest {
            // HRR is not wired on this minimal path — fail-closed (never silently
            // mis-handled).
            throw .quicHandshakeFailed
        }
        guard serverHello.cipherSuite == cipherSuiteWire else {
            throw .quicHandshakeFailed
        }
        guard let serverShare = serverHello.keyShare,
              serverShare.serverShare.group == group else {
            throw .quicHandshakeKeyExchangeFailed
        }
        let peerPublic: C.X25519.PublicKey
        do {
            peerPublic = try C.X25519.publicKey(
                rawRepresentation: serverShare.serverShare.keyExchange.span)
        } catch {
            throw .quicHandshakeKeyExchangeFailed
        }
        let sharedSecret: [UInt8]
        do {
            sharedSecret = try C.X25519.sharedSecret(
                privateKey: ecdhePrivate, peerPublicKey: peerPublic)
        } catch {
            throw .quicHandshakeKeyExchangeFailed
        }
        do {
            _ = try handshake.ingestServerHello(
                serverRandom: serverHello.random,
                cipherSuite: cipherSuiteCore,
                pskAccepted: false,
                sharedSecret: sharedSecret,
                checkDowngrade: false,
                rawMessageBytes: rawMessage
            )
        } catch {
            throw .quicHandshakeFailed
        }
    }

    /// The result of one auth-flight drive step.
    private enum ClientAuthOutcome: Equatable {
        case needMore
        case serverFinishedProcessed
    }

    private static func driveClientAuth(
        client: QUICEngineClient<Transport, Timer>,
        auth: inout QUICClientAuthMachine<C>,
        reassembler: inout HandshakeReassembler,
        peerLeafKeyBytes: inout [UInt8]?,
        peerIDMultihash: inout [UInt8]?
    ) throws(EmbeddedNodeError) -> ClientAuthOutcome {
        // Process every complete Handshake-level message currently available, in
        // order, until we either run out or process the server Finished.
        while true {
            let maybeMessage: HandshakeReassembler.Message?
            do {
                maybeMessage = try reassembler.takeMessage(level: .handshake)
            } catch {
                throw .quicHandshakeFailed
            }
            guard let message = maybeMessage else {
                return .needMore
            }

            switch message.type {
            case .encryptedExtensions:
                // ALPN + peer transport parameters live here. Apply the peer's QUIC
                // transport parameters to the engine (RFC 9000 §18.2) BEFORE folding
                // — without them the engine's stream/flow limits stay at defaults and
                // `openStream` would be rejected.
                let ee: EncryptedExtensions
                do {
                    ee = try EncryptedExtensions.decode(from: message.content)
                } catch {
                    throw .quicHandshakeFailed
                }
                try applyPeerTransportParameters(client: client, extensions: ee.extensions)
                do {
                    try auth.ingestEncryptedExtensions(rawMessageBytes: message.raw)
                } catch {
                    throw .quicHandshakeFailed
                }

            case .certificateRequest:
                do {
                    try auth.ingestCertificateRequest(rawMessageBytes: message.raw)
                } catch {
                    throw .quicHandshakeFailed
                }

            case .certificate:
                let certificate: Certificate
                do {
                    certificate = try Certificate.decode(from: message.content)
                } catch {
                    throw .quicHandshakeFailed
                }
                let presented = !certificate.isEmpty
                guard presented, let leafDER = certificate.leafCertificate else {
                    // A libp2p server MUST present its RPK leaf — fail-closed.
                    throw .quicHandshakePeerVerificationFailed
                }
                // Verify the libp2p RPK cert + extract the verified PeerID.
                let verified = try LibP2PRPKCertificateBuilder<C>.verify(
                    certificateDER: leafDER)
                peerIDMultihash = verified.peerIDMultihash
                // The CertificateVerify is checked against the leaf's P-256 key.
                let parsedSPKI: SubjectPublicKeyInfoDER.Parsed
                do {
                    parsedSPKI = try SubjectPublicKeyInfoDER.parse(verified.leafSPKI)
                } catch {
                    throw .quicHandshakePeerVerificationFailed
                }
                guard parsedSPKI.curve == .p256 else {
                    throw .quicHandshakePeerVerificationFailed
                }
                peerLeafKeyBytes = parsedSPKI.keyBytes
                do {
                    try auth.ingestServerCertificate(
                        certificatePresented: presented, rawMessageBytes: message.raw)
                } catch {
                    throw .quicHandshakeFailed
                }

            case .certificateVerify:
                let certVerify: CertificateVerify
                do {
                    certVerify = try CertificateVerify.decode(from: message.content)
                } catch {
                    throw .quicHandshakeFailed
                }
                guard let leafKey = peerLeafKeyBytes else {
                    throw .quicHandshakePeerVerificationFailed
                }
                let peerKey = QUICClientAuthMachine<C>.PeerPublicKey(
                    bytes: leafKey, scheme: certVerifyScheme)
                do {
                    try auth.ingestServerCertificateVerify(
                        algorithm: certVerify.algorithm,
                        signature: certVerify.signature,
                        peerPublicKey: peerKey,
                        verifyPeer: true,
                        rawMessageBytes: message.raw
                    )
                } catch {
                    throw .quicHandshakePeerVerificationFailed
                }

            case .finished:
                let finished: Finished
                do {
                    finished = try Finished.decode(from: message.content)
                } catch {
                    throw .quicHandshakeFailed
                }
                do {
                    _ = try auth.ingestServerFinished(verifyData: finished.verifyData)
                } catch {
                    throw .quicHandshakeFailed
                }
                return .serverFinishedProcessed

            default:
                throw .quicHandshakeFailed
            }
        }
    }

    // MARK: - Server helpers

    private static func produceServerFlight(
        server: QUICEngineClient<Transport, Timer>,
        handshake: inout QUICServerHandshake<C>,
        clientHelloRaw: [UInt8],
        clientHelloContent: [UInt8],
        identity: EmbeddedNodeIdentity<C>,
        localTransportParameters: TransportParametersCore,
        timer: Timer
    ) async throws(EmbeddedNodeError) {
        let clientHello: ClientHello
        do {
            clientHello = try ClientHello.decode(from: clientHelloContent)
        } catch {
            throw .quicHandshakeFailed
        }
        // Negotiate: the minimal server only supports AES-128-GCM + x25519.
        guard clientHello.cipherSuites.contains(cipherSuiteWire) else {
            throw .quicHandshakeFailed
        }
        guard let clientShares = clientHello.keyShare,
              let clientEntry = clientShares.keyShare(for: group) else {
            throw .quicHandshakeKeyExchangeFailed
        }

        // Apply the client's QUIC transport parameters to the engine (RFC 9000
        // §18.2) — without them the server's stream/flow limits stay at defaults.
        try applyPeerTransportParameters(client: server, extensions: clientHello.extensions)

        // Server ephemeral x25519 + shared secret.
        let ecdhePrivate: C.X25519.PrivateKey
        do {
            ecdhePrivate = try C.X25519.generatePrivateKey()
        } catch {
            throw .quicHandshakeKeyExchangeFailed
        }
        let ecdhePublic = C.X25519.publicKey(for: ecdhePrivate)
        let serverShareBytes = C.X25519.rawRepresentation(of: ecdhePublic)
        let clientPublic: C.X25519.PublicKey
        do {
            clientPublic = try C.X25519.publicKey(
                rawRepresentation: clientEntry.keyExchange.span)
        } catch {
            throw .quicHandshakeKeyExchangeFailed
        }
        let sharedSecret: [UInt8]
        do {
            sharedSecret = try C.X25519.sharedSecret(
                privateKey: ecdhePrivate, peerPublicKey: clientPublic)
        } catch {
            throw .quicHandshakeKeyExchangeFailed
        }

        // Build the local libp2p RPK certificate.
        let nowSeconds = Int64(timer.monotonicNanos() / 1_000_000_000)
        let certificate = try LibP2PRPKCertificateBuilder<C>.build(
            identity: identity, nowEpochSeconds: nowSeconds
        )

        // Assemble the server flight messages.
        let serverRandom = C.random.randomBytes(32)
        let serverHelloBytes = try encodeServerHello(
            random: serverRandom,
            sessionIDEcho: clientHello.legacySessionID,
            serverShareBytes: serverShareBytes
        )
        let encryptedExtensionsBytes = try encodeEncryptedExtensions(
            localTransportParameters: localTransportParameters
        )
        let serverCertificateBytes = try encodeCertificate(
            certificateDER: certificate.certificateDER
        )

        // Drive the FSM: begin flight → sign CertificateVerify → finish flight.
        let flightParameters = QUICServerHandshake<C>.FlightParameters(
            cipherSuite: cipherSuiteCore,
            acceptedPSK: nil,
            sharedSecret: sharedSecret,
            earlyDataAccepted: false,
            requestClientCertificate: false,
            certificateRequestSignatureAlgorithms: nil
        )
        let beginResult: (
            handshakeSecrets: (client: [UInt8], server: [UInt8]),
            clientEarlyTrafficSecret: [UInt8]?,
            certificateVerifyRequest: QUICServerHandshake<C>.ServerCertificateVerifyRequest?
        )
        do {
            beginResult = try handshake.beginServerFlight(
                clientHelloBytes: clientHelloRaw,
                parameters: flightParameters,
                serverHelloBytes: serverHelloBytes,
                encryptedExtensionsBytes: encryptedExtensionsBytes,
                certificateRequestBytes: nil,
                serverCertificateBytes: serverCertificateBytes
            )
        } catch {
            throw .quicHandshakeFailed
        }

        guard let cvRequest = beginResult.certificateVerifyRequest else {
            // A non-PSK handshake must request a CertificateVerify signature.
            throw .quicHandshakeFailed
        }
        // Sign the CertificateVerify with the ephemeral P-256 leaf key.
        let cvSignature: [UInt8]
        do {
            cvSignature = try TLSSignatureSigner<C>.sign(
                algorithm: certVerifyScheme,
                privateKeyBytes: certificate.leafSigningKeyBytes.span,
                transcriptHash: cvRequest.transcriptHash.span,
                isServer: true
            )
        } catch {
            throw .quicHandshakeFailed
        }
        let certVerifyMessage: [UInt8]
        do {
            certVerifyMessage = try CertificateVerify(
                algorithm: certVerifyScheme, signature: cvSignature
            ).encodeAsHandshakeBytes()
        } catch {
            throw .quicHandshakeFailed
        }
        do {
            try handshake.foldServerCertificateVerify(messageBytes: certVerifyMessage)
        } catch {
            throw .quicHandshakeFailed
        }

        let finishResult: (
            serverFinished: [UInt8],
            applicationSecrets: (client: [UInt8], server: [UInt8]),
            exporterMasterSecret: [UInt8]
        )
        do {
            finishResult = try handshake.finishServerFlight()
        } catch {
            throw .quicHandshakeFailed
        }

        // Install handshake keys (read = client, write = server).
        do {
            try server.installKeys(
                level: .handshake,
                readSecret: beginResult.handshakeSecrets.client,
                writeSecret: beginResult.handshakeSecrets.server,
                suite: protectionSuite
            )
        } catch {
            throw .quicHandshakeFailed
        }

        // Send the whole Handshake-level flight: EncryptedExtensions, Certificate,
        // CertificateVerify, Finished. (ServerHello goes at Initial.)
        await server.queueHandshake(serverHelloBytes, level: .initial)
        var handshakeFlight = [UInt8]()
        handshakeFlight.append(contentsOf: encryptedExtensionsBytes)
        handshakeFlight.append(contentsOf: serverCertificateBytes)
        handshakeFlight.append(contentsOf: certVerifyMessage)
        handshakeFlight.append(contentsOf: finishResult.serverFinished)
        await server.queueHandshake(handshakeFlight, level: .handshake)

        // Install application keys (read = client, write = server).
        do {
            try server.installKeys(
                level: .application,
                readSecret: finishResult.applicationSecrets.client,
                writeSecret: finishResult.applicationSecrets.server,
                suite: protectionSuite
            )
        } catch {
            throw .quicHandshakeFailed
        }
    }

    private static func encodeServerHello(
        random: [UInt8],
        sessionIDEcho: [UInt8],
        serverShareBytes: [UInt8]
    ) throws(EmbeddedNodeError) -> [UInt8] {
        do {
            let serverHello = try ServerHello(
                random: random,
                legacySessionIDEcho: sessionIDEcho,
                cipherSuite: cipherSuiteWire,
                extensions: [
                    .supportedVersionsServer(0x0304),
                    .keyShareServer(KeyShareEntry(group: group, keyExchange: serverShareBytes)),
                ]
            )
            return try serverHello.encodeAsHandshakeBytes()
        } catch {
            throw .quicHandshakeFailed
        }
    }

    private static func encodeEncryptedExtensions(
        localTransportParameters: TransportParametersCore
    ) throws(EmbeddedNodeError) -> [UInt8] {
        let tpBytes = TransportParameterCodecCore.encode(localTransportParameters)
        do {
            return try EncryptedExtensions(extensions: [
                .alpnProtocols([alpn]),
                .quicTransportParameters(tpBytes),
            ]).encodeAsHandshakeBytes()
        } catch {
            throw .quicHandshakeFailed
        }
    }

    private static func encodeCertificate(
        certificateDER: [UInt8]
    ) throws(EmbeddedNodeError) -> [UInt8] {
        do {
            return try Certificate(certificates: [certificateDER]).encodeAsHandshakeBytes()
        } catch {
            throw .quicHandshakeFailed
        }
    }
}
