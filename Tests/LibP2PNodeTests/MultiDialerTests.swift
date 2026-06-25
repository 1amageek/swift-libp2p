// MultiDialerTests.swift
// Slice 5 (b): SERVER-DEMUX. Two DISTINCT nodes A and C both dial ONE listener B over
// a SHARED `DatagramTransport`. B demultiplexes inbound datagrams by QUIC Destination
// Connection ID (parsed from the long header — NOT decrypted), spins up a per-dialer
// connection, completes BOTH mutually-authenticated (mTLS) handshakes, and tracks A's
// and C's DISTINCT verified PeerIDs. A↔B and C↔B then ping + echo INDEPENDENTLY.
//
// HOST test (Foundation/Synchronization for the test doubles); the code under test —
// `ServerDemultiplexer`, `DemuxRoutedTransport`, the mTLS handshake driver, `Node` —
// is the dual-build Embedded-clean path.

import Testing
import Foundation
import Synchronization
import P2PCoreCrypto
import P2PCoreTransport
import P2PCoreDER
import P2PCrypto
import LibP2PCore
import QUICWire
import QUICConnectionCore
import QUICConnectionEngineCore
import QUIC
@testable import LibP2PNode

private typealias Provider = DefaultCryptoProvider

// MARK: - Shared hub: many dialers ↔ one listener (routed by endpoint)

/// The listener's shared inbound transport. Datagrams from ANY dialer surface on its
/// single `incoming`; sends route back to the addressed dialer's transport by
/// endpoint. Models one UDP socket serving many peers.
private final class HubTransport: DatagramTransport, @unchecked Sendable {
    typealias Incoming = AsyncStream<Datagram>

    let maximumDatagramSize = 1200
    let incoming: AsyncStream<Datagram>
    private let inboundContinuation: AsyncStream<Datagram>.Continuation
    private let selfEndpoint: SocketEndpoint
    // Dialer endpoint → that dialer's inbound continuation (for B→dialer sends).
    private let dialers: Mutex<[SocketEndpoint: AsyncStream<Datagram>.Continuation]>

    init(selfEndpoint: SocketEndpoint) {
        self.selfEndpoint = selfEndpoint
        var cont: AsyncStream<Datagram>.Continuation!
        self.incoming = AsyncStream<Datagram> { cont = $0 }
        self.inboundContinuation = cont
        self.dialers = Mutex([:])
    }

    /// Registers a dialer transport so the hub can route B→dialer datagrams to it.
    func attach(_ dialer: DialerTransport) {
        dialers.withLock { $0[dialer.selfEndpoint] = dialer.inboundContinuation }
    }

    /// A dialer feeds an inbound datagram into the hub's `incoming` (A/C → B).
    func deliverInbound(_ datagram: Datagram) {
        inboundContinuation.yield(datagram)
    }

    func send(_ payload: Span<UInt8>, to endpoint: SocketEndpoint) async throws(TransportError) {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(payload.count)
        for i in payload.indices { bytes.append(payload[i]) }
        let target = dialers.withLock { $0[endpoint] }
        // B → the addressed dialer; the datagram's source is B's endpoint.
        target?.yield(Datagram(payload: bytes, source: selfEndpoint))
    }

    func close() async {
        inboundContinuation.finish()
        dialers.withLock { map in
            for (_, cont) in map { cont.finish() }
            map.removeAll()
        }
    }
}

/// A single dialer's transport (A or C). Sends go to the hub; inbound arrives from B.
private final class DialerTransport: DatagramTransport, @unchecked Sendable {
    typealias Incoming = AsyncStream<Datagram>

    let maximumDatagramSize = 1200
    let incoming: AsyncStream<Datagram>
    let inboundContinuation: AsyncStream<Datagram>.Continuation
    let selfEndpoint: SocketEndpoint
    private let hub: HubTransport

    init(selfEndpoint: SocketEndpoint, hub: HubTransport) {
        self.selfEndpoint = selfEndpoint
        self.hub = hub
        var cont: AsyncStream<Datagram>.Continuation!
        self.incoming = AsyncStream<Datagram> { cont = $0 }
        self.inboundContinuation = cont
    }

    func send(_ payload: Span<UInt8>, to endpoint: SocketEndpoint) async throws(TransportError) {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(payload.count)
        for i in payload.indices { bytes.append(payload[i]) }
        // The dialer → the hub (B); the datagram's source is this dialer's endpoint.
        hub.deliverInbound(Datagram(payload: bytes, source: selfEndpoint))
    }

    func close() async {
        inboundContinuation.finish()
    }
}

// MARK: - Connection-ID plans

/// A dialer's plan: it freely chooses all three CIDs (random per dialer).
private struct RandomDialPlan: ConnectionIDPlan {
    let scid: ConnectionID
    let dcid: ConnectionID
    init?() {
        guard let s = ConnectionID.random(length: 8),
              let d = ConnectionID.random(length: 8) else { return nil }
        self.scid = s
        self.dcid = d
    }
    func dialConnectionIDs() throws(NodeError) -> ConnectionIDs {
        ConnectionIDs(localConnectionID: scid, peerConnectionID: dcid, originalDestinationConnectionID: dcid)
    }
    func acceptConnectionIDs() throws(NodeError) -> ConnectionIDs {
        // Unused by a dialer; the protocol still requires it.
        ConnectionIDs(localConnectionID: scid, peerConnectionID: dcid, originalDestinationConnectionID: dcid)
    }
}

/// The listener's plan: mints a FRESH server source CID per dialer (the second demux
/// routing key). `serverConnectionID()` MUST return a distinct CID each call so
/// concurrent dialers never collide.
private struct ServePlan: ConnectionIDPlan {
    func dialConnectionIDs() throws(NodeError) -> ConnectionIDs {
        // Unused by the serving listener.
        guard let cid = ConnectionID.random(length: 8) else { throw .quicFeatureUnsupported }
        return ConnectionIDs(localConnectionID: cid, peerConnectionID: cid, originalDestinationConnectionID: cid)
    }
    func acceptConnectionIDs() throws(NodeError) -> ConnectionIDs {
        guard let cid = ConnectionID.random(length: 8) else { throw .quicFeatureUnsupported }
        return ConnectionIDs(localConnectionID: cid, peerConnectionID: cid, originalDestinationConnectionID: cid)
    }
    func serverConnectionID() throws(NodeError) -> ConnectionID {
        guard let cid = ConnectionID.random(length: 8) else { throw .quicFeatureUnsupported }
        return cid
    }
}

@Suite("Server-demux: A and C dial one listener B; B demuxes by DCID, mTLS each")
struct MultiDialerTests {

    @Test(
        "Two distinct dialers fan out over a shared transport; B tracks both verified PeerIDs",
        .timeLimit(.minutes(1))
    )
    func twoDialersDemux() async throws {
        let identityA = try #require(makeIdentity())
        let identityB = try #require(makeIdentity())
        let identityC = try #require(makeIdentity())
        let peerIDA = try #require(verifiedPeerID(of: identityA))
        let peerIDB = try #require(verifiedPeerID(of: identityB))
        let peerIDC = try #require(verifiedPeerID(of: identityC))
        #expect(peerIDA != peerIDC, "A and C must be distinct peers")

        let epA = SocketEndpoint(v4: 127, 0, 0, 1, port: 4601)
        let epB = SocketEndpoint(v4: 127, 0, 0, 1, port: 4602)
        let epC = SocketEndpoint(v4: 127, 0, 0, 1, port: 4603)

        // One shared listener hub; A and C each dial it over their own transports.
        let hub = HubTransport(selfEndpoint: epB)
        let transportA = DialerTransport(selfEndpoint: epA, hub: hub)
        let transportC = DialerTransport(selfEndpoint: epC, hub: hub)
        hub.attach(transportA)
        hub.attach(transportC)

        let timer = TestClock()

        // B serves over the demux. Its node `Transport` is the demux's per-dialer
        // routed transport; the stored construction transport is a never-used
        // placeholder (B only `serve`s — it never `dial`s / `listen(on:)`s).
        let demux = ServerDemultiplexer(
            shared: hub,
            serverConnectionIDLength: 8,
            mintServerConnectionID: { () throws(NodeError) -> ConnectionID in
                guard let cid = ConnectionID.random(length: 8) else { throw .quicFeatureUnsupported }
                return cid
            }
        )
        let placeholder = DemuxRoutedTransport(shared: hub, dialerEndpoint: epB)
        let nodeB = Node(
            identity: identityB,
            datagramTransport: placeholder,
            timer: timer,
            parameters: .defaultParameters(),
            connectionIDPlan: ServePlan(),
            agentVersion: "swift-libp2p-node/demux-B"
        )
        // B registers an echo handler so each dialer can round-trip a frame.
        let echoProtocol = "/echo/1.0.0"
        await nodeB.handle(echoProtocol) { stream in
            do {
                let inbound = try await stream.read()
                if !inbound.isEmpty { try await stream.write(inbound) }
                await stream.close()
            } catch {
                // Stream gone; fail-closed per stream.
            }
        }

        let nodeA = Node(
            identity: identityA,
            datagramTransport: transportA,
            timer: timer,
            parameters: .defaultParameters(),
            connectionIDPlan: try #require(RandomDialPlan()),
            agentVersion: "swift-libp2p-node/demux-A"
        )
        let nodeC = Node(
            identity: identityC,
            datagramTransport: transportC,
            timer: timer,
            parameters: .defaultParameters(),
            connectionIDPlan: try #require(RandomDialPlan()),
            agentVersion: "swift-libp2p-node/demux-C"
        )

        // Start the demux reader, then have B serve over it.
        demux.start()
        try await nodeB.serve(over: demux)

        // A and C dial B concurrently. B demuxes both by their distinct DCIDs.
        async let dialA = nodeA.dial(to: epB)
        async let dialC = nodeC.dial(to: epB)
        let aGotB = try await dialA
        let cGotB = try await dialC

        // Each dialer got B's verified PeerID (server→client identity).
        #expect(aGotB == peerIDB, "A did not get B's verified PeerID")
        #expect(cGotB == peerIDB, "C did not get B's verified PeerID")

        // B tracks A's AND C's DISTINCT verified PeerIDs (mTLS client-auth on each
        // demuxed connection). Poll briefly — the handshakes complete on B's serve
        // tasks slightly after the dialers return.
        var bPeers = await nodeB.connectedPeerIDs()
        let deadline = timer.monotonicNanos() &+ 8_000_000_000
        while !(contains2D(bPeers, peerIDA) && contains2D(bPeers, peerIDC)) {
            if timer.monotonicNanos() >= deadline { break }
            try await Task.sleep(nanoseconds: 5_000_000)
            bPeers = await nodeB.connectedPeerIDs()
        }
        #expect(contains2D(bPeers, peerIDA), "B must track A's verified PeerID (demux + mTLS)")
        #expect(contains2D(bPeers, peerIDC), "B must track C's verified PeerID (demux + mTLS)")

        // A↔B and C↔B ping INDEPENDENTLY (distinct connections, distinct verified peers).
        let pingAB = try await nodeA.ping(peerIDB)
        #expect(pingAB.roundTripNanos > 0, "A→B ping RTT must be positive")
        let pingCB = try await nodeC.ping(peerIDB)
        #expect(pingCB.roundTripNanos > 0, "C→B ping RTT must be positive")

        // A↔B and C↔B echo INDEPENDENTLY through B's registered handler.
        let payloadA: [UInt8] = Array("hello-from-A".utf8)
        let echoedA = try await echoRoundTrip(node: nodeA, peerID: peerIDB, protocolID: echoProtocol, payload: payloadA, timer: timer)
        #expect(echoedA == payloadA, "A↔B echo failed")

        let payloadC: [UInt8] = Array("hello-from-C".utf8)
        let echoedC = try await echoRoundTrip(node: nodeC, peerID: peerIDB, protocolID: echoProtocol, payload: payloadC, timer: timer)
        #expect(echoedC == payloadC, "C↔B echo failed")

        // B identifies A and C back, each fail-closed bound to the right PeerID.
        let aIdentify = try await nodeB.identify(peerIDA)
        #expect(aIdentify.publicKey == identityA.protobufPublicKey, "B's identify of A: publicKey mismatch")
        let cIdentify = try await nodeB.identify(peerIDC)
        #expect(cIdentify.publicKey == identityC.protobufPublicKey, "B's identify of C: publicKey mismatch")

        demux.shutdown()
        await nodeA.close()
        await nodeB.close()
        await nodeC.close()
        await hub.close()
        await transportA.close()
        await transportC.close()
    }

    // MARK: - Helpers

    private func echoRoundTrip<T: DatagramTransport, M: AsyncTimer, I: ConnectionIDPlan>(
        node: Node<T, M, I>,
        peerID: [UInt8],
        protocolID: String,
        payload: [UInt8],
        timer: M
    ) async throws -> [UInt8] {
        let stream = try await node.newStream(to: peerID, protocol: protocolID)
        try await stream.write(payload)
        var echoed = [UInt8]()
        let deadline = timer.monotonicNanos() &+ 8_000_000_000
        while echoed.count < payload.count {
            if timer.monotonicNanos() >= deadline { break }
            let chunk = try await stream.read()
            if chunk.isEmpty { break }
            echoed.append(contentsOf: chunk)
        }
        await stream.close()
        return echoed
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

    private func contains2D(_ list: [[UInt8]], _ value: [UInt8]) -> Bool {
        for item in list where item == value { return true }
        return false
    }
}
