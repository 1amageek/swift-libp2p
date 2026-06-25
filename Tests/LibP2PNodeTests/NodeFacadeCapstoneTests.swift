// NodeFacadeCapstoneTests.swift
// THE capstone 2-node test through the `Node` FACADE API (Slice 4). Node A and node
// B each a `Node` over a shared in-process loopback `DatagramTransport`:
//   1. B `listen`s; A `dial`s B → A gets B's HANDSHAKE-VERIFIED PeerID.
//   2. A `ping`s B (`/ipfs/ping/1.0.0`) → RTT > 0 (32-byte echo round-trip).
//   3. A `identify`s B (`/ipfs/id/1.0.0`) → B's advertised publicKey is FAIL-CLOSED
//      bound to the handshake PeerID.
//   4. A `newStream(to: B, protocol: "/echo/1.0.0")` with B's registered echo handler
//      → a `[UInt8]` round-trip through the facade.
//   5. Both nodes `close()`.
//
// HOST test (Foundation/Synchronization for the test doubles); the code under test —
// the `Node` facade, `ConnectionManager`, `ProtocolRouter`, the Ping/Identify
// services — is the dual-build Embedded-clean path.

import Testing
import Foundation
import Synchronization
import P2PCoreCrypto
import P2PCoreTransport
import P2PCoreDER
import P2PCrypto
import P2PCryptoFoundation
import QUICTLSSignature
import LibP2PCore
import QUICWire
import QUICConnectionCore
import QUICConnectionEngineCore
import QUIC
@testable import LibP2PNode

private typealias Provider = QUICTLSSignatureProvider

// MARK: - In-memory loopback transport

/// A pair-wired in-memory `DatagramTransport`: bytes sent on one side surface on the
/// other side's `incoming`. No sockets — deterministic, host-only test double.
private final class NodeLoopbackTransport: DatagramTransport, @unchecked Sendable {
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

    func connect(to peer: NodeLoopbackTransport) {
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

// MARK: - Coordinated connection-ID plan (test double)

/// A `ConnectionIDPlan` pair sharing one connection's CIDs between the dial side and
/// the accept side. On the QUIC path a server derives its Initial keys from the
/// dialer's chosen original-DCID (RFC 9001 §5.2); the live `Node` learns this from a
/// server-demux primitive (out-of-scope this slice), so the test injects matching
/// CIDs deterministically through a shared coordinator.
private final class CIDCoordinator: @unchecked Sendable {
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

    /// The dialer (A) freely chooses all three CIDs (peer == originalDestination).
    var dialIDs: ConnectionIDs {
        ConnectionIDs(
            localConnectionID: scidA,
            peerConnectionID: dcidA,
            originalDestinationConnectionID: dcidA
        )
    }

    /// The listener (B): local = its own SCID, peer = the dialer's SCID,
    /// originalDestination = the dialer's chosen DCID (so Initial keys match).
    var acceptIDs: ConnectionIDs {
        ConnectionIDs(
            localConnectionID: scidB,
            peerConnectionID: scidA,
            originalDestinationConnectionID: dcidA
        )
    }
}

/// The dial side of the coordinated plan.
private struct DialPlan: ConnectionIDPlan {
    let coordinator: CIDCoordinator
    func dialConnectionIDs() throws(NodeError) -> ConnectionIDs { coordinator.dialIDs }
    func acceptConnectionIDs() throws(NodeError) -> ConnectionIDs { coordinator.acceptIDs }
}

/// The accept side of the coordinated plan (same coordinator, used by `listen`).
private struct AcceptPlan: ConnectionIDPlan {
    let coordinator: CIDCoordinator
    func dialConnectionIDs() throws(NodeError) -> ConnectionIDs { coordinator.dialIDs }
    func acceptConnectionIDs() throws(NodeError) -> ConnectionIDs { coordinator.acceptIDs }
}

@Suite("Node facade capstone: dial → ping → identify → echo newStream → close")
struct NodeFacadeCapstoneTests {

    @Test(
        "2 nodes over loopback: A dials B, pings, identifies, opens an echo stream",
        .timeLimit(.minutes(1))
    )
    func twoNodeFacadeRoundTrip() async throws {
        // Identities. A dials, B listens. A verifies B's PeerID via the handshake.
        let identityA = try #require(makeIdentity())
        let identityB = try #require(makeIdentity())
        let peerIDB = try #require(peerIDMultihash(of: identityB))

        let epA = SocketEndpoint(v4: 127, 0, 0, 1, port: 4401)
        let epB = SocketEndpoint(v4: 127, 0, 0, 1, port: 4402)

        let transportA = NodeLoopbackTransport(selfEndpoint: epA)
        let transportB = NodeLoopbackTransport(selfEndpoint: epB)
        transportA.connect(to: transportB)
        transportB.connect(to: transportA)

        let timer = TestClock()
        let coordinator = try #require(CIDCoordinator())

        let nodeA = Node(
            identity: identityA,
            datagramTransport: transportA,
            timer: timer,
            wallClock: SystemWallClock(),
            parameters: .defaultParameters(),
            connectionIDPlan: DialPlan(coordinator: coordinator),
            agentVersion: "swift-libp2p-node/capstone-A"
        )
        let nodeB = Node(
            identity: identityB,
            datagramTransport: transportB,
            timer: timer,
            wallClock: SystemWallClock(),
            parameters: .defaultParameters(),
            connectionIDPlan: AcceptPlan(coordinator: coordinator),
            agentVersion: "swift-libp2p-node/capstone-B"
        )

        // B registers an echo handler for "/echo/1.0.0" (one frame echoed back).
        let echoProtocol = "/echo/1.0.0"
        await nodeB.handle(echoProtocol) { stream in
            do {
                let inbound = try await stream.read()
                if !inbound.isEmpty {
                    try await stream.write(inbound)
                }
                await stream.close()
            } catch {
                // Stream gone; nothing to echo. Fail-closed per stream.
            }
        }

        // B listens; A dials. Drive both upgrades concurrently.
        async let listenTask: Void = nodeB.listen(on: epA)
        async let dialTask = nodeA.dial(to: epB)

        try await listenTask
        let dialedPeerID = try await dialTask

        // 1. A got B's HANDSHAKE-VERIFIED PeerID.
        #expect(dialedPeerID == peerIDB, "dial did not return B's verified PeerID")

        // 2. A pings B: RTT > 0 from a real 32-byte echo round-trip.
        let pingResult = try await nodeA.ping(peerIDB)
        #expect(pingResult.roundTripNanos > 0, "ping RTT must be positive")

        // 3. A identifies B: the advertised publicKey is fail-closed bound to the
        //    handshake PeerID, and the fields round-trip.
        let bIdentify = try await nodeA.identify(peerIDB)
        #expect(bIdentify.publicKey == identityB.protobufPublicKey, "Identify publicKey mismatch")
        let derivedFromIdentify = try #require(peerID(fromProtobufPublicKey: bIdentify.publicKey))
        #expect(derivedFromIdentify == peerIDB, "Identify-derived PeerID != handshake PeerID")
        #expect(bIdentify.agentVersion == "swift-libp2p-node/capstone-B", "agentVersion not round-tripped")
        #expect(
            contains(bIdentify.protocols, NodeProtocolID.ping)
                && contains(bIdentify.protocols, NodeProtocolID.identify)
                && contains(bIdentify.protocols, echoProtocol),
            "Identify must advertise ping + identify + the registered echo protocol"
        )

        // 4. A opens an echo stream through the facade and round-trips [UInt8].
        let payload: [UInt8] = Array("hello-node-facade".utf8)
        let echoStream = try await nodeA.newStream(to: peerIDB, protocol: echoProtocol)
        try await echoStream.write(payload)
        var echoed = [UInt8]()
        let readDeadline = timer.monotonicNanos() &+ 8_000_000_000
        while echoed.count < payload.count {
            if timer.monotonicNanos() >= readDeadline { break }
            let chunk = try await echoStream.read()
            if chunk.isEmpty { break }
            echoed.append(contentsOf: chunk)
        }
        await echoStream.close()
        #expect(echoed == payload, "echo round-trip through the facade failed")

        // 5. Close both nodes.
        await nodeA.close()
        await nodeB.close()
        await transportA.close()
        await transportB.close()
    }

    // MARK: - Helpers

    private func makeIdentity() -> NodeIdentity<Provider>? {
        do {
            return try NodeIdentity<Provider>.generate()
        } catch {
            return nil
        }
    }

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

    private func contains(_ list: [String], _ value: String) -> Bool {
        for item in list where item == value { return true }
        return false
    }
}
