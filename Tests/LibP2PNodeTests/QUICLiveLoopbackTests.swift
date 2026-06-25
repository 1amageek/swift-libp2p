// QUICLiveLoopbackTests.swift
// The live libp2p-over-QUIC handshake test: two `QUICTransport` over a
// shared in-process loopback `DatagramTransport`, client dials server, the TLS 1.3
// handshake COMPLETES (driving the cored TLS FSMs through the engine seam), both
// bind the verified peer PeerID from the RPK certificate (fail-closed), the client
// opens a QUIC stream, and a `[UInt8]` echo round-trips.
//
// This is a HOST test (it may use Foundation/Synchronization for the test doubles);
// the code under test (`QUICTransport` / `QUICTLSHandshakeDriver` /
// `LibP2PRPKCertificateBuilder`) is the dual-build Embedded-clean path.

import Testing
import Foundation
import Synchronization
import P2PCoreCrypto
import P2PCoreTransport
import P2PCrypto
import QUICWire
import QUICConnectionCore
import QUICConnectionEngineCore
import QUIC
@testable import LibP2PNode

private typealias Provider = DefaultCryptoProvider

// MARK: - In-memory loopback transport

/// A pair-wired in-memory `DatagramTransport`: bytes sent on one side surface on
/// the other side's `incoming`. No sockets — deterministic, host-only test double.
private final class LoopbackTransport: DatagramTransport, @unchecked Sendable {
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

    func connect(to peer: LoopbackTransport) {
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

@Suite("Live libp2p-over-QUIC handshake (loopback)")
struct QUICLiveLoopbackTests {

    private func makeConfig(
        role: QUICEngineRole,
        localCID: ConnectionID,
        peerCID: ConnectionID,
        originalDCID: ConnectionID
    ) -> QUICConnectionEngineConfiguration<Provider> {
        var tp = TransportParametersCore()
        tp.initialMaxData = 1_000_000
        tp.initialMaxStreamDataBidiLocal = 256 * 1024
        tp.initialMaxStreamDataBidiRemote = 256 * 1024
        tp.initialMaxStreamDataUni = 256 * 1024
        tp.initialMaxStreamsBidi = 100
        tp.initialMaxStreamsUni = 100
        return QUICConnectionEngineConfiguration<Provider>(
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

    @Test("client dials server, TLS 1.3 completes, verified PeerID bound, stream echoes", .timeLimit(.minutes(1)))
    func liveHandshakeAndEcho() async throws {
        // Identities.
        let clientIdentity = try #require(makeIdentity())
        let serverIdentity = try #require(makeIdentity())
        let serverPeerIDMultihash = try #require(peerIDMultihash(of: serverIdentity))

        // Connection IDs: the client picks a random DCID that the server uses as
        // its original-destination CID to derive matching Initial keys.
        let clientDCID = try #require(ConnectionID.random(length: 8))
        let clientSCID = try #require(ConnectionID.random(length: 8))
        let serverSCID = try #require(ConnectionID.random(length: 8))

        let clientEP = SocketEndpoint(v4: 127, 0, 0, 1, port: 4101)
        let serverEP = SocketEndpoint(v4: 127, 0, 0, 1, port: 4102)

        // Loopback transport pair.
        let clientT = LoopbackTransport(selfEndpoint: clientEP)
        let serverT = LoopbackTransport(selfEndpoint: serverEP)
        clientT.connect(to: serverT)
        serverT.connect(to: clientT)

        let timer = TestClock()

        let clientTransport = QUICTransport(transport: clientT, timer: timer)
        let serverTransport = QUICTransport(transport: serverT, timer: timer)

        let clientConfig = makeConfig(
            role: .client, localCID: clientSCID, peerCID: clientDCID, originalDCID: clientDCID)
        let serverConfig = makeConfig(
            role: .server, localCID: serverSCID, peerCID: clientSCID, originalDCID: clientDCID)

        // Drive both handshakes concurrently.
        async let serverConnTask = serverTransport.listen(
            configuration: serverConfig,
            peer: clientEP,
            identity: serverIdentity
        )
        async let clientConnTask = clientTransport.dial(
            configuration: clientConfig,
            peer: serverEP,
            identity: clientIdentity
        )

        let clientConn = try await clientConnTask
        let serverConn = try await serverConnTask

        // The handshake completed on both sides.
        #expect(clientConn.isEstablished, "client connection not established")
        #expect(serverConn.isEstablished, "server connection not established")

        // The client verified the server's PeerID from the RPK certificate
        // (fail-closed). It must match the server identity's PeerID.
        #expect(
            clientConn.remotePeerIDMultihash == serverPeerIDMultihash,
            "client-verified server PeerID mismatch"
        )

        // Echo: the client opens a stream and writes; the server accepts it and
        // echoes the bytes back; the client reads them.
        let payload: [UInt8] = Array("hello-libp2p-over-quic".utf8)

        // Server side: accept the stream and echo whatever it reads.
        let echoTask = Task { () -> [UInt8] in
            let deadline = timer.monotonicNanos() &+ 8_000_000_000
            guard let stream = await serverConn.acceptStream(deadlineNanos: deadline) else {
                return []
            }
            do {
                let inbound = try await stream.read()
                try await stream.write(inbound)
                return inbound
            } catch {
                return []
            }
        }

        let stream = try clientConn.openStream()
        try await stream.write(payload)

        // Read the echo back (poll-read loop already inside `read()`).
        var echoed: [UInt8] = []
        let readDeadline = timer.monotonicNanos() &+ 8_000_000_000
        while echoed.count < payload.count {
            if timer.monotonicNanos() >= readDeadline { break }
            let chunk = try await stream.read()
            if chunk.isEmpty { break }
            echoed.append(contentsOf: chunk)
        }

        let serverSaw = await echoTask.value

        await clientConn.close()
        await serverConn.close()
        await clientT.close()
        await serverT.close()

        #expect(serverSaw == payload, "server did not receive the client payload")
        #expect(echoed == payload, "client did not receive the echoed payload")
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
    /// certificate build + verify the handshake uses — so the test's expectation is
    /// exactly the value the driver extracts.
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
}
