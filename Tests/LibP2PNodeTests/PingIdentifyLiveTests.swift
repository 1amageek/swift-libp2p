// PingIdentifyLiveTests.swift
// The 2-node-over-live-QUIC test for Slice 3: node A dials node B over the loopback
// `DatagramTransport`, the libp2p-over-QUIC TLS 1.3 handshake completes (A binds B's
// verified PeerID from the RPK certificate), then:
//   * A pings B (`/ipfs/ping/1.0.0`): 32-byte echo round-trips, RTT > 0.
//   * A runs Identify (`/ipfs/id/1.0.0`): A reads B's Identify and FAIL-CLOSED
//     binds B's advertised publicKey to the handshake-verified PeerID.
//
// B's inbound streams are dispatched through `ProtocolRouter` (the minimal
// server-side router): the listener negotiates multistream-select, then routes the
// agreed id to the ping echo handler or the identify responder.
//
// This is a HOST test (it uses Foundation/Synchronization for the test doubles);
// the code under test (`PingService` / `IdentifyService` / `ProtocolRouter` /
// `StreamNegotiation`) is the dual-build Embedded-clean path.

import Testing
import Foundation
import Synchronization
import P2PCoreCrypto
import P2PCoreTransport
import P2PCoreDER
import P2PCrypto
import P2PCryptoFoundationEssentials
import QUICTLSSignature
import LibP2PCore
import QUICWire
import QUICConnectionCore
import QUICConnectionEngineCore
import QUIC
@testable import LibP2PNode

private typealias Provider = QUICTLSSignatureProvider

// MARK: - In-memory loopback transport

/// A pair-wired in-memory `DatagramTransport` (same shape as the live-handshake
/// test): bytes sent on one side surface on the other side's `incoming`.
private final class PingLoopbackTransport: DatagramTransport, @unchecked Sendable {
    typealias Incoming = AsyncStream<Datagram>

    let maximumDatagramSize = 1200
    let incoming: AsyncStream<Datagram>
    private let inboundContinuation: AsyncStream<Datagram>.Continuation
    private let peerContinuation: Mutex<AsyncStream<Datagram>.Continuation?>
    private let selfEndpoint: SocketEndpoint

    init(selfEndpoint: SocketEndpoint) {
        self.selfEndpoint = selfEndpoint
        var cont: AsyncStream<Datagram>.Continuation!
        self.incoming = AsyncStream<Datagram> { cont = $0 }
        self.inboundContinuation = cont
        self.peerContinuation = Mutex(nil)
    }

    func connect(to peer: PingLoopbackTransport) {
        peerContinuation.withLock { $0 = peer.inboundContinuation }
    }

    func send(_ payload: Span<UInt8>, to endpoint: SocketEndpoint) async throws(TransportError) {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(payload.count)
        for i in payload.indices { bytes.append(payload[i]) }
        let target = peerContinuation.withLock { $0 }
        target?.yield(Datagram(payload: bytes, source: selfEndpoint))
    }

    func close() async {
        inboundContinuation.finish()
        peerContinuation.withLock { $0?.finish() }
    }
}

@Suite("Ping + Identify over live libp2p-over-QUIC (loopback)")
struct PingIdentifyLiveTests {

    private func makeConfig(
        role: QUICEngineRole,
        localCID: ConnectionID,
        peerCID: ConnectionID,
        originalDCID: ConnectionID
    ) -> QUICConnectionEngineConfiguration<DefaultCryptoProvider> {
        var tp = TransportParametersCore()
        tp.initialMaxData = 1_000_000
        tp.initialMaxStreamDataBidiLocal = 256 * 1024
        tp.initialMaxStreamDataBidiRemote = 256 * 1024
        tp.initialMaxStreamDataUni = 256 * 1024
        tp.initialMaxStreamsBidi = 100
        tp.initialMaxStreamsUni = 100
        return QUICConnectionEngineConfiguration<DefaultCryptoProvider>(
            role: role,
            version: .v1,
            localConnectionID: localCID,
            initialPeerConnectionID: peerCID,
            originalDestinationConnectionID: originalDCID,
            localTransportParameters: tp,
            maxDatagramSize: 1200,
            idleTimeoutNanos: 30_000_000_000,
            maxAckDelayNanos: 25_000_000,
            pathValidationTimeoutNanos: 3_000_000_000
        )
    }

    @Test(
        "A dials B, pings B (32-byte echo + RTT>0), Identify binds B's verified PeerID",
        .timeLimit(.minutes(1))
    )
    func pingAndIdentifyOverLiveQUIC() async throws {
        // Identities. A dials, B listens. The client verifies B's PeerID.
        let identityA = try #require(makeIdentity())
        let identityB = try #require(makeIdentity())
        let peerIDB = try #require(peerIDMultihash(of: identityB))

        let dcidA = try #require(ConnectionID.random(length: 8))
        let scidA = try #require(ConnectionID.random(length: 8))
        let scidB = try #require(ConnectionID.random(length: 8))

        let epA = SocketEndpoint(v4: 127, 0, 0, 1, port: 4201)
        let epB = SocketEndpoint(v4: 127, 0, 0, 1, port: 4202)

        let transportA = PingLoopbackTransport(selfEndpoint: epA)
        let transportB = PingLoopbackTransport(selfEndpoint: epB)
        transportA.connect(to: transportB)
        transportB.connect(to: transportA)

        let timer = TestClock()

        let nodeATransport = QUICTransport(transport: transportA, timer: timer, wallClock: SystemWallClock())
        let nodeBTransport = QUICTransport(transport: transportB, timer: timer, wallClock: SystemWallClock())

        let configA = makeConfig(role: .client, localCID: scidA, peerCID: dcidA, originalDCID: dcidA)
        let configB = makeConfig(role: .server, localCID: scidB, peerCID: scidA, originalDCID: dcidA)

        // Drive both handshakes concurrently.
        async let bConnTask = nodeBTransport.listen(configuration: configB, peer: epA, identity: identityB)
        async let aConnTask = nodeATransport.dial(configuration: configA, peer: epB, identity: identityA)

        let connA = try await aConnTask
        let connB = try await bConnTask

        #expect(connA.isEstablished, "A connection not established")
        #expect(connB.isEstablished, "B connection not established")
        #expect(connA.remotePeerIDMultihash == peerIDB, "A-verified B PeerID mismatch")

        // B's Identify message advertises B's identity public key.
        let bIdentifyFields = IdentifyFields(
            publicKey: identityB.protobufPublicKey,
            listenAddrs: [],
            protocols: [NodeProtocolID.ping, NodeProtocolID.identify],
            observedAddr: nil,
            protocolVersion: "ipfs/0.1.0",
            agentVersion: "swift-libp2p-node/slice3"
        )

        // B's server: accept two inbound streams and dispatch each via the router
        // (ping echo, then identify responder).
        let serverTask = Task { () -> Bool in
            let router = ProtocolRouter<QUICStream<BufferingDatagramTransport<PingLoopbackTransport>, TestClock>, TestClock>(
                routes: [
                    .init(protocolID: NodeProtocolID.ping) { stream throws(NodeError) in
                        try await PingService<Provider, TestClock>.serve(on: stream)
                    },
                    .init(protocolID: NodeProtocolID.identify) { stream throws(NodeError) in
                        try await IdentifyService<Provider>.respond(on: stream, fields: bIdentifyFields)
                    }
                ],
                timer: timer
            )
            // (handlers receive a BufferedMuxedStream carrying any negotiation residual)
            // Accept and dispatch two streams (ping, then identify).
            for _ in 0..<2 {
                let deadline = timer.monotonicNanos() &+ 8_000_000_000
                guard let inbound = await connB.acceptStream(deadlineNanos: deadline) else {
                    return false
                }
                do {
                    try await router.dispatch(inbound: inbound)
                } catch {
                    return false
                }
            }
            return true
        }

        // A: PING — open a stream, negotiate /ipfs/ping/1.0.0, run the ping over the
        // residual-aware stream the negotiation returns.
        let pingRaw = try connA.openStream()
        let pingStream = try await StreamNegotiation.dial(NodeProtocolID.ping, on: pingRaw, timer: timer)
        let pingResult = try await PingService<Provider, TestClock>.ping(on: pingStream, timer: timer)
        await pingStream.close()

        #expect(pingResult.roundTripNanos > 0, "ping RTT must be positive")

        // A: IDENTIFY — open a stream, negotiate /ipfs/id/1.0.0, read B's Identify,
        // bind B's advertised publicKey to the handshake-verified PeerID.
        let identifyRaw = try connA.openStream()
        let identifyStream = try await StreamNegotiation.dial(NodeProtocolID.identify, on: identifyRaw, timer: timer)
        let bIdentify = try await IdentifyService<Provider>.identify(
            on: identifyStream,
            verifiedPeerIDMultihash: connA.remotePeerIDMultihash
        )

        // The Identify-advertised key matches the handshake PeerID (fail-closed
        // binding succeeded), and its fields round-tripped.
        #expect(bIdentify.publicKey == identityB.protobufPublicKey, "Identify publicKey mismatch")
        let derivedFromIdentify = try #require(
            peerID(fromProtobufPublicKey: bIdentify.publicKey)
        )
        #expect(derivedFromIdentify == peerIDB, "Identify-derived PeerID != handshake PeerID")
        #expect(bIdentify.agentVersion == "swift-libp2p-node/slice3", "agentVersion not round-tripped")
        #expect(
            Set(bIdentify.protocols) == Set([NodeProtocolID.ping, NodeProtocolID.identify]),
            "protocols not round-tripped"
        )

        let serverOK = await serverTask.value
        #expect(serverOK, "B server failed to dispatch ping + identify")

        await connA.close()
        await connB.close()
        await transportA.close()
        await transportB.close()
    }

    // MARK: - Identity helpers

    private func makeIdentity() -> NodeIdentity<Provider>? {
        do {
            return try NodeIdentity<Provider>.generate()
        } catch {
            return nil
        }
    }

    /// Derives the PeerID multihash for an identity by running the same RPK
    /// certificate build + verify the handshake uses.
    private func peerIDMultihash(of identity: NodeIdentity<Provider>) -> [UInt8]? {
        do {
            let cert = try LibP2PRPKCertificateBuilder<Provider>.build(
                identity: identity, nowEpochSeconds: 0)
            let verified = try LibP2PRPKCertificateBuilder<Provider>.verify(
                certificateDER: cert.certificateDER)
            return verified.peerIDMultihash
        } catch {
            return nil
        }
    }

    /// Derives the PeerID multihash directly from a protobuf public key (the same
    /// derivation `IdentifyService` performs), for the test's cross-check.
    private func peerID(fromProtobufPublicKey key: [UInt8]?) -> [UInt8]? {
        guard let key else { return nil }
        do {
            return try LibP2PIdentity.peerIDMultihash(
                protobufPubKey: key,
                sha256: { (data: [UInt8]) -> [UInt8] in Provider.SHA256.hash(data.span) }
            )
        } catch {
            return nil
        }
    }
}
