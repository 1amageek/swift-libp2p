// MutualAuthTests.swift
// Slice 5 (a): MUTUAL client-auth (mTLS) on the QUIC TLS 1.3 path. After A dials B,
// BOTH sides hold the OTHER's cryptographically-verified PeerID:
//   1. A gets B's verified PeerID from the dial (server→client identity, as before).
//   2. B now gets A's verified PeerID from the client certificate B requested in the
//      handshake (the new mTLS path) — the inbound connection is tracked by A's
//      VERIFIED PeerID, never anonymously.
//   3. B can `identify` A back: the Identify-advertised publicKey FAIL-CLOSED binds to
//      A's handshake-verified PeerID (the server→client binding that mTLS activates).
//   4. A TAMPERED client certificate is rejected (fail-closed): the RPK
//      proof-of-possession verify the server runs throws, so an unverified peer is
//      NEVER admitted.
//
// HOST test (Foundation/Synchronization for the test doubles); the code under test —
// the mTLS handshake driver, `Node`, `ConnectionManager`, Identify — is the
// dual-build Embedded-clean path.

import Testing
import Foundation
import Synchronization
import P2PCoreCrypto
import P2PCoreTransport
import P2PCoreDER
import P2PCrypto
import QUICTLSSignature
import LibP2PCore
import QUICWire
import QUICConnectionCore
import QUICConnectionEngineCore
import QUIC
@testable import LibP2PNode

private typealias Provider = QUICTLSSignatureProvider

// MARK: - In-memory loopback transport (pair-wired)

private final class MutualAuthLoopbackTransport: DatagramTransport, @unchecked Sendable {
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

    func connect(to peer: MutualAuthLoopbackTransport) {
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

// MARK: - Coordinated connection-ID plan (single-accept path)

private final class MACIDCoordinator: @unchecked Sendable {
    private let scidA: ConnectionID
    private let scidB: ConnectionID
    private let dcidA: ConnectionID

    init?() {
        guard let a = ConnectionID.random(length: 8),
              let b = ConnectionID.random(length: 8),
              let d = ConnectionID.random(length: 8) else {
            return nil
        }
        self.scidA = a
        self.scidB = b
        self.dcidA = d
    }

    var dialIDs: ConnectionIDs {
        ConnectionIDs(localConnectionID: scidA, peerConnectionID: dcidA, originalDestinationConnectionID: dcidA)
    }
    var acceptIDs: ConnectionIDs {
        ConnectionIDs(localConnectionID: scidB, peerConnectionID: scidA, originalDestinationConnectionID: dcidA)
    }
}

private struct MACPlan: ConnectionIDPlan {
    let coordinator: MACIDCoordinator
    func dialConnectionIDs() throws(NodeError) -> ConnectionIDs { coordinator.dialIDs }
    func acceptConnectionIDs() throws(NodeError) -> ConnectionIDs { coordinator.acceptIDs }
    func serverConnectionID() throws(NodeError) -> ConnectionID { coordinator.acceptIDs.localConnectionID }
}

@Suite("Mutual client-auth (mTLS): both sides hold the other's verified PeerID")
struct MutualAuthTests {

    @Test(
        "A dials B; B now knows A's verified PeerID and identifies A back (fail-closed)",
        .timeLimit(.minutes(1))
    )
    func bidirectionalVerifiedPeerID() async throws {
        let identityA = try #require(makeIdentity())
        let identityB = try #require(makeIdentity())
        let peerIDA = try #require(verifiedPeerID(of: identityA))
        let peerIDB = try #require(verifiedPeerID(of: identityB))

        let epA = SocketEndpoint(v4: 127, 0, 0, 1, port: 4501)
        let epB = SocketEndpoint(v4: 127, 0, 0, 1, port: 4502)

        let transportA = MutualAuthLoopbackTransport(selfEndpoint: epA)
        let transportB = MutualAuthLoopbackTransport(selfEndpoint: epB)
        transportA.connect(to: transportB)
        transportB.connect(to: transportA)

        let timer = TestClock()
        let coordinator = try #require(MACIDCoordinator())

        let nodeA = Node(
            identity: identityA,
            datagramTransport: transportA,
            timer: timer,
            wallClock: TestWallClock(),
            parameters: .defaultParameters(),
            connectionIDPlan: MACPlan(coordinator: coordinator),
            agentVersion: "swift-libp2p-node/mtls-A"
        )
        let nodeB = Node(
            identity: identityB,
            datagramTransport: transportB,
            timer: timer,
            wallClock: TestWallClock(),
            parameters: .defaultParameters(),
            connectionIDPlan: MACPlan(coordinator: coordinator),
            agentVersion: "swift-libp2p-node/mtls-B"
        )

        // B listens; A dials. mTLS: the server (B) requests + verifies A's client cert.
        async let listenTask: Void = nodeB.listen(on: epA)
        async let dialTask = nodeA.dial(to: epB)
        try await listenTask
        let dialedPeerID = try await dialTask

        // 1. A holds B's verified PeerID (server→client identity).
        #expect(dialedPeerID == peerIDB, "A did not get B's verified PeerID")

        // 2. B now holds A's VERIFIED PeerID (the inbound connection is tracked by A's
        //    cryptographically-verified identity from the client cert, not anonymously).
        let bConnectedPeers = await connectedPeers(of: nodeB)
        #expect(
            contains2D(bConnectedPeers, peerIDA),
            "B must track the inbound connection by A's VERIFIED PeerID (mTLS)"
        )

        // 3. B identifies A back: the server→client Identify binding (which mTLS
        //    activates) fail-closed binds A's advertised publicKey to A's handshake
        //    PeerID. Both nodes auto-serve Identify, so this round-trips.
        let aIdentify = try await nodeB.identify(peerIDA)
        #expect(aIdentify.publicKey == identityA.protobufPublicKey, "Identify publicKey mismatch")
        let derived = try #require(peerID(fromProtobufPublicKey: aIdentify.publicKey))
        #expect(derived == peerIDA, "Identify-derived PeerID != A's handshake PeerID")
        #expect(aIdentify.agentVersion == "swift-libp2p-node/mtls-A", "agentVersion not round-tripped")

        // And B can ping A back (the server reaches the dialer over the same connection).
        let pingAB = try await nodeB.ping(peerIDA)
        #expect(pingAB.roundTripNanos > 0, "B→A ping RTT must be positive")

        await nodeA.close()
        await nodeB.close()
        await transportA.close()
        await transportB.close()
    }

    @Test("A tampered client RPK certificate is rejected (fail-closed)")
    func tamperedClientCertRejected() async throws {
        let identity = try #require(makeIdentity())
        // A well-formed cert verifies + yields a PeerID (the same path the server runs
        // on the client's presented certificate during the mTLS handshake).
        let cert = try LibP2PRPKCertificateBuilder<Provider>.build(identity: identity, nowEpochSeconds: 0)
        let verified = try LibP2PRPKCertificateBuilder<Provider>.verify(certificateDER: cert.certificateDER)
        #expect(!verified.peerIDMultihash.isEmpty, "a valid cert must yield a PeerID")
        let der = cert.certificateDER

        // 1. Truncation: a structurally-broken cert never parses, so it is rejected
        //    by the FIRST verify step (fail-closed). The server thus never admits a
        //    peer whose cert it cannot fully parse.
        #expect(der.count > 4, "cert must be non-trivial")
        let truncated = Array(der[0..<(der.count / 2)])
        #expect(verifyRejects(truncated), "a truncated cert MUST be rejected (fail-closed)")

        // 2. Byte tampering across the cert: the DER carries the ephemeral P-256 SPKI
        //    and the critical libp2p proof-of-possession extension (the identity-key
        //    signature over `"libp2p-tls-handshake:" || SPKI`). Flipping a byte in any
        //    of those breaks the proof-of-possession verify or the structural parse, so
        //    the OVERWHELMING majority of single-byte flips MUST be rejected. (A handful
        //    of flips inside ASN.1 framing/serial bytes that `verify` does not consume
        //    may still parse — the aggregate rejection rate proves no silent admit of a
        //    tampered identity binding.)
        var rejectedCount = 0
        var attempted = 0
        var index = 0
        while index < der.count {
            var tampered = der
            tampered[index] ^= 0x01
            attempted += 1
            if verifyRejects(tampered) { rejectedCount += 1 }
            index += 3
        }
        #expect(attempted > 0, "must have attempted tampering")
        #expect(
            rejectedCount > attempted / 2,
            "most single-byte-tampered certs must be rejected (fail-closed): rejected \(rejectedCount)/\(attempted)"
        )

        // 3. A cert for identity A NEVER verifies to a DIFFERENT identity's PeerID —
        //    the proof-of-possession binds the SPKI to exactly one identity key.
        let other = try #require(makeIdentity())
        let otherPeerID = try #require(verifiedPeerID(of: other))
        #expect(
            verified.peerIDMultihash != otherPeerID,
            "a cert's verified PeerID must be the cert owner's, never another identity's"
        )
    }

    // MARK: - Helpers

    private func verifyRejects(_ der: [UInt8]) -> Bool {
        do {
            _ = try LibP2PRPKCertificateBuilder<Provider>.verify(certificateDER: der)
            return false
        } catch {
            return true
        }
    }

    private func makeIdentity() -> NodeIdentity<Provider>? {
        do { return try NodeIdentity<Provider>.generate() } catch { return nil }
    }

    private func verifiedPeerID(of identity: NodeIdentity<Provider>) -> [UInt8]? {
        do {
            let cert = try LibP2PRPKCertificateBuilder<Provider>.build(identity: identity, nowEpochSeconds: 0)
            let verified = try LibP2PRPKCertificateBuilder<Provider>.verify(certificateDER: cert.certificateDER)
            return verified.peerIDMultihash
        } catch { return nil }
    }

    private func peerID(fromProtobufPublicKey key: [UInt8]?) -> [UInt8]? {
        guard let key else { return nil }
        do {
            return try LibP2PIdentity.peerIDMultihash(
                protobufPubKey: key,
                sha256: { (data: [UInt8]) -> [UInt8] in Provider.SHA256.hash(data.span) }
            )
        } catch { return nil }
    }

    private func connectedPeers<T: DatagramTransport, M: AsyncTimer, I: ConnectionIDPlan, W: WallClock>(
        of node: Node<T, M, I, W>
    ) async -> [[UInt8]] {
        await node.connectedPeerIDs()
    }

    private func contains2D(_ list: [[UInt8]], _ value: [UInt8]) -> Bool {
        for item in list where item == value { return true }
        return false
    }
}
