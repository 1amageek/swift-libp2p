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
    Timer: AsyncTimer,
    Clock: WallClock
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
    /// - Throws: a typed ``NodeError`` on any failure (NEVER a half-open
    ///   connection — the caller tears down on a throw).
    public static func runClient(
        client: QUICEngineClient<Transport, Timer>,
        identity: NodeIdentity<C>,
        localTransportParameters: TransportParametersCore,
        timer: Timer,
        wallClock: Clock,
        deadlineNanos: UInt64,
        replayBuffered: @Sendable @escaping () -> Void
    ) async throws(NodeError) -> QUICHandshakeResult {

        // 1. Ephemeral x25519 key share.
        let ecdhePrivate: C.X25519.PrivateKey
        do {
            ecdhePrivate = try C.X25519.generatePrivateKey()
        } catch {
            throw .quicHandshakeKeyExchangeFailed
        }
        let ecdhePublic = C.X25519.publicKey(for: ecdhePrivate)
        let clientShareBytes = C.X25519.rawRepresentation(of: ecdhePublic)

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
                    // The whole client Handshake-level flight (mTLS Certificate +
                    // CertificateVerify, if the server requested client auth, then
                    // Finished). All three messages ride the HANDSHAKE level, so the
                    // 1-RTT (application) write keys are installed AFTER this flight.
                    // libp2p mandates MUTUAL authentication: the dialer MUST present and
                    // prove its own libp2p RPK certificate so the listener binds the
                    // dialer's verified PeerID. The generic TLS auth machine permits
                    // OPTIONAL client auth (a client presents its certificate only when
                    // the server sent a CertificateRequest); libp2p does NOT. A server
                    // that completes its flight WITHOUT a CertificateRequest is not a
                    // compliant libp2p peer — fail-closed here rather than silently
                    // establishing a one-way-authenticated connection in which we never
                    // proved who we are. (The symmetric server-side requirement is
                    // enforced in `runServer`, which refuses an empty/absent client cert.)
                    guard auth.clientCertificateRequested else {
                        throw .quicHandshakePeerVerificationFailed
                    }
                    // Present the client's RPK certificate + CertificateVerify (proof of
                    // possession), folded into the transcript BEFORE the client Finished.
                    var clientFlight = [UInt8]()
                    let clientFlightBytes = try produceClientAuthFlight(
                        auth: &auth,
                        identity: identity,
                        wallClock: wallClock
                    )
                    clientFlight.append(contentsOf: clientFlightBytes)
                    // Produce the client Finished BEFORE installing 1-RTT write keys —
                    // but the client Finished is sent at the HANDSHAKE level, so install
                    // app keys after the whole handshake flight is queued.
                    let clientFinished: [UInt8]
                    do {
                        clientFinished = try auth.produceClientFinished()
                    } catch {
                        throw .quicHandshakeFailed
                    }
                    clientFlight.append(contentsOf: clientFinished)
                    authMachine = auth
                    await client.queueHandshake(clientFlight, level: .handshake)
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
    /// (ServerHello + EncryptedExtensions + CertificateRequest + Certificate(RPK) +
    /// CertificateVerify + Finished), installs handshake + application keys, then
    /// waits for the client's auth flight (Certificate + CertificateVerify) and the
    /// client Finished and marks complete. Bounded by `deadlineNanos` (fail-closed).
    ///
    /// MUTUAL AUTH (mTLS): the server sends a CertificateRequest in its flight, the
    /// client presents its own libp2p RPK certificate + CertificateVerify (proof of
    /// possession), and the server verifies the client cert in-core (fail-closed),
    /// deriving the CLIENT's verified PeerID from the RPK extension. The returned
    /// ``QUICHandshakeResult`` carries the CLIENT's PeerID so the listener tracks the
    /// inbound connection by a cryptographically-verified identity (never anonymous).
    /// An unverified client is NEVER admitted.
    public static func runServer(
        server: QUICEngineClient<Transport, Timer>,
        identity: NodeIdentity<C>,
        localTransportParameters: TransportParametersCore,
        timer: Timer,
        wallClock: Clock,
        deadlineNanos: UInt64,
        replayBuffered: @Sendable @escaping () -> Void
    ) async throws(NodeError) -> QUICHandshakeResult {

        var handshake = QUICServerHandshake<C>(cipherSuite: cipherSuiteCore)
        var reassembler = HandshakeReassembler()
        var flightSent = false
        var clientPeerIDMultihash: [UInt8]? = nil
        var clientLeafKeyBytes: [UInt8]? = nil

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
                    wallClock: wallClock
                )
                flightSent = true
                // Replay any buffered datagrams now that handshake read keys exist,
                // in case a client handshake-level packet arrived early (symmetry
                // with the client's post-key-install replay).
                replayBuffered()
                continue
            }

            // 2. Client auth flight (Handshake): Certificate, CertificateVerify,
            //    Finished — processed in order as they reassemble.
            let outcome = try driveServerClientAuth(
                handshake: &handshake,
                reassembler: &reassembler,
                clientPeerIDMultihash: &clientPeerIDMultihash,
                clientLeafKeyBytes: &clientLeafKeyBytes
            )
            if outcome == .clientFinishedProcessed {
                await server.markHandshakeComplete()
                // The client MUST have presented a verified libp2p RPK certificate
                // (mTLS); a missing PeerID here means an unauthenticated client —
                // refuse rather than admit it (fail-closed).
                guard let verifiedClient = clientPeerIDMultihash, !verifiedClient.isEmpty else {
                    throw .quicHandshakePeerVerificationFailed
                }
                return QUICHandshakeResult(peerIDMultihash: verifiedClient)
            }
        }
    }

    /// The result of one server-side client-auth drive step.
    private enum ServerClientAuthOutcome: Equatable {
        case needMore
        case clientFinishedProcessed
    }

    /// Processes the client's mTLS auth flight (Certificate, CertificateVerify,
    /// Finished) in order, verifying the libp2p RPK certificate + proof-of-possession
    /// signature in-core (fail-closed) and deriving the client's verified PeerID.
    private static func driveServerClientAuth(
        handshake: inout QUICServerHandshake<C>,
        reassembler: inout HandshakeReassembler,
        clientPeerIDMultihash: inout [UInt8]?,
        clientLeafKeyBytes: inout [UInt8]?
    ) throws(NodeError) -> ServerClientAuthOutcome {
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
            case .certificate:
                let certificate: Certificate
                do {
                    certificate = try Certificate.decode(from: message.content)
                } catch {
                    throw .quicHandshakeFailed
                }
                let presented = !certificate.isEmpty
                // A libp2p client MUST present its RPK leaf — an empty client
                // Certificate is an unauthenticated peer; fail-closed.
                guard presented, let leafDER = certificate.leafCertificate else {
                    throw .quicHandshakePeerVerificationFailed
                }
                // Verify the libp2p RPK cert + extract the verified client PeerID.
                let verified = try LibP2PRPKCertificateBuilder<C>.verify(
                    certificateDER: leafDER)
                clientPeerIDMultihash = verified.peerIDMultihash
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
                clientLeafKeyBytes = parsedSPKI.keyBytes
                do {
                    _ = try handshake.ingestClientCertificate(
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
                guard let leafKey = clientLeafKeyBytes else {
                    throw .quicHandshakePeerVerificationFailed
                }
                let clientKey = QUICServerHandshake<C>.ClientPublicKey(
                    bytes: leafKey, scheme: certVerifyScheme)
                do {
                    try handshake.ingestClientCertificateVerify(
                        algorithm: certVerify.algorithm,
                        signature: certVerify.signature,
                        clientPublicKey: clientKey,
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
                    try handshake.ingestClientFinished(verifyData: finished.verifyData)
                } catch {
                    throw .quicHandshakeFailed
                }
                return .clientFinishedProcessed

            default:
                throw .quicHandshakeFailed
            }
        }
    }

    // MARK: - Client helpers

    /// Decodes the QUIC transport parameters from a peer's extension list and
    /// applies them to the engine (RFC 9000 §18.2). The `quic_transport_parameters`
    /// extension MUST be present in a QUIC handshake — fail-closed if absent.
    private static func applyPeerTransportParameters(
        client: QUICEngineClient<Transport, Timer>,
        extensions: [TLSExtension]
    ) throws(NodeError) {
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
            // Advertise ONLY the schemes we actually verify in the peer's
            // CertificateVerify. The leaf path verifies ECDSA P-256 only
            // (see the SPKI `.p256` guards), so advertising `.ed25519` here would
            // be a false promise — the libp2p identity Ed25519 key is a SEPARATE
            // thing from the TLS CertificateVerify signature.
            .signatureAlgorithmsList([certVerifyScheme]),
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
    ) throws(NodeError) {
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
    ) throws(NodeError) -> ClientAuthOutcome {
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
                // The CertificateRequest declares which signature schemes the server
                // will accept in the client's CertificateVerify (RFC 8446 §4.3.2). The
                // client signs ECDSA P-256 only (see `produceClientAuthFlight`); if the
                // server does not offer that scheme the client cannot satisfy the
                // request. Fail-closed here rather than signing P-256 anyway — otherwise
                // the client could treat the handshake as established off a signature
                // the server never agreed to accept.
                let certRequest: CertificateRequest
                do {
                    certRequest = try CertificateRequest.decode(from: message.content)
                } catch {
                    throw .quicHandshakeFailed
                }
                guard Self.certificateRequestOffers(certRequest, scheme: certVerifyScheme) else {
                    throw .quicHandshakePeerVerificationFailed
                }
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

    /// Builds + folds the client's mTLS authentication flight (Certificate +
    /// CertificateVerify) into the auth FSM, returning the assembled Handshake-level
    /// bytes for the engine. Called only when the server sent a CertificateRequest.
    ///
    /// The client presents its OWN libp2p RPK certificate (its ephemeral P-256 leaf
    /// + the identity-key proof-of-possession) and signs a CertificateVerify with the
    /// leaf key over the CH..client-Certificate transcript (RFC 8446 §4.4.3,
    /// `isServer: false`). Both messages are folded so the subsequent client Finished
    /// is computed over the correct transcript.
    ///
    /// - Returns: `Certificate || CertificateVerify` handshake-message bytes.
    /// - Throws: a typed ``NodeError`` on any cert-build / sign / fold failure
    ///   (fail-closed — the client never sends an unsigned or partial auth flight).
    private static func produceClientAuthFlight(
        auth: inout QUICClientAuthMachine<C>,
        identity: NodeIdentity<C>,
        wallClock: Clock
    ) throws(NodeError) -> [UInt8] {
        // 1. Build the client's libp2p RPK certificate (fresh ephemeral P-256 leaf
        //    + identity-key proof-of-possession). The cert's notBefore/notAfter MUST
        //    be real wall-clock Unix-epoch seconds (NOT the monotonic clock, which
        //    looks like ~1970) so a remote peer's validity check accepts it.
        let nowSeconds = wallClock.nowUnixSeconds()
        let certificate = try LibP2PRPKCertificateBuilder<C>.build(
            identity: identity, nowEpochSeconds: nowSeconds
        )

        // 2. Encode + fold the client Certificate. The certificate_request_context is
        //    empty (the server's CertificateRequest carried an empty context).
        let certificateBytes: [UInt8]
        do {
            certificateBytes = try Certificate(
                certificateRequestContext: [],
                certificates: [certificate.certificateDER]
            ).encodeAsHandshakeBytes()
        } catch {
            throw .quicHandshakeCertificateFailed
        }
        do {
            try auth.foldClientCertificate(rawMessageBytes: certificateBytes)
        } catch {
            throw .quicHandshakeFailed
        }

        // 3. Sign the CertificateVerify over CH..client-Certificate with the leaf key.
        let cvTranscript = auth.clientCertificateVerifyTranscript
        let cvSignature: [UInt8]
        do {
            cvSignature = try TLSSignatureSigner<C>.sign(
                algorithm: certVerifyScheme,
                privateKeyBytes: certificate.leafSigningKeyBytes.span,
                transcriptHash: cvTranscript.span,
                isServer: false
            )
        } catch {
            throw .quicHandshakeFailed
        }
        let certVerifyBytes: [UInt8]
        do {
            certVerifyBytes = try CertificateVerify(
                algorithm: certVerifyScheme, signature: cvSignature
            ).encodeAsHandshakeBytes()
        } catch {
            throw .quicHandshakeFailed
        }
        do {
            try auth.foldClientCertificateVerify(rawMessageBytes: certVerifyBytes)
        } catch {
            throw .quicHandshakeFailed
        }

        var flight = [UInt8]()
        flight.append(contentsOf: certificateBytes)
        flight.append(contentsOf: certVerifyBytes)
        return flight
    }

    // MARK: - Server helpers

    private static func produceServerFlight(
        server: QUICEngineClient<Transport, Timer>,
        handshake: inout QUICServerHandshake<C>,
        clientHelloRaw: [UInt8],
        clientHelloContent: [UInt8],
        identity: NodeIdentity<C>,
        localTransportParameters: TransportParametersCore,
        wallClock: Clock
    ) async throws(NodeError) {
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

        // Build the local libp2p RPK certificate. The cert's notBefore/notAfter MUST
        // be real wall-clock Unix-epoch seconds (NOT the monotonic clock, which looks
        // like ~1970) so a remote peer's validity check accepts it.
        let nowSeconds = wallClock.nowUnixSeconds()
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

        // Mutual auth (mTLS): the libp2p server REQUESTS a client certificate so the
        // accepted peer's PeerID is cryptographically verified (never anonymous). The
        // CertificateRequest offers EXACTLY the scheme the server will accept in the
        // client's CertificateVerify — ECDSA P-256, the only scheme this leaf path
        // signs and verifies. (The libp2p identity Ed25519 key signs the RPK cert's
        // proof-of-possession, NOT the TLS CertificateVerify, so it must not appear
        // here.) An empty certificate_request_context (RFC 8446 §4.3.2) — echoed back.
        let certificateRequestSchemes: [QUICTLSCore.SignatureScheme] = [certVerifyScheme]
        let certificateRequestBytes = try encodeCertificateRequest(
            signatureAlgorithms: certificateRequestSchemes
        )

        // Drive the FSM: begin flight → sign CertificateVerify → finish flight.
        let flightParameters = QUICServerHandshake<C>.FlightParameters(
            cipherSuite: cipherSuiteCore,
            acceptedPSK: nil,
            sharedSecret: sharedSecret,
            earlyDataAccepted: false,
            requestClientCertificate: true,
            certificateRequestSignatureAlgorithms: certificateRequestSchemes
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
                certificateRequestBytes: certificateRequestBytes,
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

        // Send the whole Handshake-level flight: EncryptedExtensions,
        // CertificateRequest (mTLS), Certificate, CertificateVerify, Finished.
        // (ServerHello goes at Initial.) The CertificateRequest MUST be folded into
        // the transcript BEFORE the server Certificate, so it is also placed before
        // the Certificate on the wire (RFC 8446 §4.3.2 message order).
        await server.queueHandshake(serverHelloBytes, level: .initial)
        var handshakeFlight = [UInt8]()
        handshakeFlight.append(contentsOf: encryptedExtensionsBytes)
        handshakeFlight.append(contentsOf: certificateRequestBytes)
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
    ) throws(NodeError) -> [UInt8] {
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
    ) throws(NodeError) -> [UInt8] {
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
    ) throws(NodeError) -> [UInt8] {
        do {
            return try Certificate(certificates: [certificateDER]).encodeAsHandshakeBytes()
        } catch {
            throw .quicHandshakeFailed
        }
    }

    /// Whether a received CertificateRequest's `signature_algorithms` extension
    /// offers `scheme`. RFC 8446 §4.3.2 makes the extension mandatory; its absence —
    /// or omission of the scheme the client can sign — means the client cannot
    /// produce an acceptable CertificateVerify, so the caller fails closed.
    private static func certificateRequestOffers(
        _ request: CertificateRequest,
        scheme: QUICTLSCore.SignatureScheme
    ) -> Bool {
        for ext in request.extensions {
            if case .signatureAlgorithms(let sigAlgs) = ext {
                return sigAlgs.supportedSignatureAlgorithms.contains(scheme)
            }
        }
        return false
    }

    /// Encodes the CertificateRequest (mTLS) with an empty context and the given
    /// `signature_algorithms` (the only signature schemes the server will accept in
    /// the client CertificateVerify, RFC 8446 §4.3.2).
    private static func encodeCertificateRequest(
        signatureAlgorithms: [QUICTLSCore.SignatureScheme]
    ) throws(NodeError) -> [UInt8] {
        do {
            let sigAlgsExtension = SignatureAlgorithmsExtension(
                supportedSignatureAlgorithms: signatureAlgorithms
            )
            return try CertificateRequest(
                certificateRequestContext: [],
                extensions: [.signatureAlgorithms(sigAlgsExtension)]
            ).encodeAsHandshakeBytes()
        } catch {
            throw .quicHandshakeFailed
        }
    }
}
