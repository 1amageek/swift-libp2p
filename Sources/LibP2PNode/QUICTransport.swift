// QUICTransport.swift
// The libp2p node's QUIC transport. It wraps swift-quic's `[UInt8]` engine facade
// (`QUICEngineClient<Transport, Timer>`) and drives the libp2p-over-QUIC TLS 1.3
// handshake to a LIVE, verified connection.
//
// ARCHITECTURE: on the QUIC path, QUIC's NATIVE TLS 1.3 — carrying the libp2p RPK
// certificate — provides BOTH security (the verified peer PeerID) AND stream
// multiplexing (QUIC native streams). There is NO Noise / Yamux here (those are the
// TCP-path primitives). `dial`/`listen` therefore:
//   1. construct the engine client over the injected `DatagramTransport` +
//      `AsyncTimer` seams,
//   2. start the engine's I/O + timer run loop in a child task,
//   3. drive the TLS 1.3 handshake (``QUICTLSHandshakeDriver``) to completion,
//      extracting the verified peer PeerID from the RPK cert (fail-closed),
//   4. on success return an ``QUICConnection`` whose streams are QUIC
//      native streams (``QUICStream``).
//
// FAIL-CLOSED: on any handshake / verification failure the engine is torn down and
// a typed ``NodeError`` is thrown — never a half-open connection.
//
// Embedded-clean: monomorphic over `<C, Transport, Timer>`, `[UInt8]`/
// `SocketEndpoint` currency, no `any`, no Foundation, typed throws, no try?/try!.

import _Concurrency   // REQUIRED under Embedded for async/Task
import P2PCoreCrypto       // AsyncTimer
import P2PCoreTransport    // DatagramTransport / SocketEndpoint
import P2PCrypto           // DefaultCryptoProvider
import QUIC                // QUICEngineClient / QUICPeerValidator
import QUICConnectionEngineCore  // QUICConnectionEngineConfiguration / QUICEngineError
import QUICConnectionCore        // TransportParametersCore

/// The libp2p node's QUIC transport, wrapping ``QUICEngineClient``.
///
/// Monomorphic over the injected `Transport` (UDP datagram I/O) and `Timer`
/// (monotonic clock + sleep) seams. The crypto provider is pinned by the facade to
/// ``DefaultCryptoProvider`` (host swift-crypto / Embedded BoringSSL), so the
/// embedder never spells the crypto generic.
public struct QUICTransport<
    Transport: DatagramTransport,
    Timer: AsyncTimer
>: Sendable {

    private let transport: Transport
    private let timer: Timer

    public init(transport: Transport, timer: Timer) {
        self.transport = transport
        self.timer = timer
    }

    /// The default handshake deadline (10 seconds in nanoseconds). The handshake
    /// driver fails closed if the TLS 1.3 exchange does not complete within it.
    public static var defaultHandshakeTimeoutNanos: UInt64 { 10_000_000_000 }

    /// Builds the underlying ``QUICEngineClient`` for `peer` over `wrapped` from
    /// `configuration`.
    ///
    /// The engine client is built over the replay-buffering transport wrapper (not
    /// the raw injected transport) so that handshake packets dropped before their
    /// keys are installed can be re-fed (RFC 9001 §5.7) — see
    /// ``BufferingDatagramTransport``.
    ///
    /// - Throws: ``NodeError/quicFeatureUnsupported`` if the engine facade
    ///   rejects the configuration (mapped from `QUICEngineError`).
    private func makeClient(
        configuration: QUICConnectionEngineConfiguration<DefaultCryptoProvider>,
        wrapped: BufferingDatagramTransport<Transport>,
        peer: SocketEndpoint
    ) throws(NodeError) -> QUICEngineClient<BufferingDatagramTransport<Transport>, Timer> {
        let client: QUICEngineClient<BufferingDatagramTransport<Transport>, Timer>
        do {
            client = try QUICEngineClient(
                configuration: configuration,
                transport: wrapped,
                timer: timer,
                peer: peer,
                peerValidator: nil
            )
        } catch {
            // `error` binds as `QUICEngineError`; bare catch (no cross-type `as`).
            throw .quicFeatureUnsupported
        }
        return client
    }

    /// Dials `peer` and returns a LIVE, verified QUIC connection.
    ///
    /// Drives the libp2p-over-QUIC TLS 1.3 client handshake (with the local RPK
    /// identity) over the injected transport + timer until established, extracting
    /// the server's verified PeerID from its RPK certificate. On success the QUIC
    /// native streams are exposed via ``QUICConnection/openStream()``.
    ///
    /// - Throws: a typed ``NodeError`` on any handshake / verification
    ///   failure (fail-closed — never a half-open connection).
    public func dial(
        configuration: QUICConnectionEngineConfiguration<DefaultCryptoProvider>,
        peer: SocketEndpoint,
        identity: NodeIdentity<DefaultCryptoProvider>,
        handshakeTimeoutNanos: UInt64? = nil
    ) async throws(NodeError) -> QUICConnection<BufferingDatagramTransport<Transport>, Timer> {
        let wrapped = BufferingDatagramTransport(inner: transport)
        let client = try makeClient(configuration: configuration, wrapped: wrapped, peer: peer)
        let runTask = Task { await client.run() }
        let deadline = timer.monotonicNanos()
            &+ (handshakeTimeoutNanos ?? Self.defaultHandshakeTimeoutNanos)

        let outcome: Result<QUICHandshakeResult, NodeError>
        do {
            let value = try await QUICTLSHandshakeDriver<DefaultCryptoProvider, BufferingDatagramTransport<Transport>, Timer>.runClient(
                client: client,
                identity: identity,
                localTransportParameters: configuration.localTransportParameters,
                timer: timer,
                deadlineNanos: deadline,
                replayBuffered: { wrapped.replayBuffered() }
            )
            outcome = .success(value)
        } catch {
            // `error` binds as `NodeError` (the only thrown type in the `do`).
            outcome = .failure(error)
        }
        let result: QUICHandshakeResult
        switch outcome {
        case .success(let value):
            result = value
        case .failure(let error):
            // Fail-closed: tear the connection down, never hand back a half-open one.
            await client.close(errorCode: 0x0a, reason: [], isApplicationError: false)
            runTask.cancel()
            throw error
        }

        return QUICConnection(
            client: client,
            timer: timer,
            runTask: runTask,
            remotePeerIDMultihash: result.peerIDMultihash,
            isInitiator: true
        )
    }

    /// Accepts an inbound connection on the (already-bound) transport and returns a
    /// LIVE, verified QUIC connection.
    ///
    /// Drives the libp2p-over-QUIC TLS 1.3 server handshake (presenting the local
    /// RPK identity) over the injected transport + timer until established. The
    /// minimal server does not request a client certificate (no mTLS on this
    /// slice), so the returned connection carries no peer PeerID; the SERVER
    /// proves its identity to the client.
    ///
    /// - Throws: a typed ``NodeError`` on any handshake failure
    ///   (fail-closed — never a half-open connection).
    public func listen(
        configuration: QUICConnectionEngineConfiguration<DefaultCryptoProvider>,
        peer: SocketEndpoint,
        identity: NodeIdentity<DefaultCryptoProvider>,
        handshakeTimeoutNanos: UInt64? = nil
    ) async throws(NodeError) -> QUICConnection<BufferingDatagramTransport<Transport>, Timer> {
        let wrapped = BufferingDatagramTransport(inner: transport)
        let client = try makeClient(configuration: configuration, wrapped: wrapped, peer: peer)
        let runTask = Task { await client.run() }
        let deadline = timer.monotonicNanos()
            &+ (handshakeTimeoutNanos ?? Self.defaultHandshakeTimeoutNanos)

        let outcome: Result<QUICHandshakeResult, NodeError>
        do {
            let value = try await QUICTLSHandshakeDriver<DefaultCryptoProvider, BufferingDatagramTransport<Transport>, Timer>.runServer(
                server: client,
                identity: identity,
                localTransportParameters: configuration.localTransportParameters,
                timer: timer,
                deadlineNanos: deadline,
                replayBuffered: { wrapped.replayBuffered() }
            )
            outcome = .success(value)
        } catch {
            // `error` binds as `NodeError` (the only thrown type in the `do`).
            outcome = .failure(error)
        }
        let result: QUICHandshakeResult
        switch outcome {
        case .success(let value):
            result = value
        case .failure(let error):
            await client.close(errorCode: 0x0a, reason: [], isApplicationError: false)
            runTask.cancel()
            throw error
        }

        return QUICConnection(
            client: client,
            timer: timer,
            runTask: runTask,
            remotePeerIDMultihash: result.peerIDMultihash,
            isInitiator: false
        )
    }
}

/// A live, handshake-verified libp2p-over-QUIC connection.
///
/// Wraps the established ``QUICEngineClient`` and exposes QUIC native streams as
/// ``QUICStream`` (`[UInt8]`). It owns the engine's run-loop task and tears
/// it down on ``close()``. The remote's verified PeerID multihash (from the RPK
/// certificate) is bound at construction; it is never a silent/unverified value.
public final class QUICConnection<
    Transport: DatagramTransport,
    Timer: AsyncTimer
>: Sendable {

    private let client: QUICEngineClient<Transport, Timer>
    private let timer: Timer
    private let runTask: Task<Void, Never>

    /// The remote peer's verified PeerID multihash (from its RPK certificate), or
    /// empty when the peer is unauthenticated on this path (server-side, no mTLS).
    public let remotePeerIDMultihash: [UInt8]

    /// Whether this side dialed (`true`) or accepted (`false`) — determines which
    /// stream-ID parity QUIC assigns to locally-opened bidirectional streams.
    public let isInitiator: Bool

    init(
        client: QUICEngineClient<Transport, Timer>,
        timer: Timer,
        runTask: Task<Void, Never>,
        remotePeerIDMultihash: [UInt8],
        isInitiator: Bool
    ) {
        self.client = client
        self.timer = timer
        self.runTask = runTask
        self.remotePeerIDMultihash = remotePeerIDMultihash
        self.isInitiator = isInitiator
    }

    /// Whether the connection is established (the handshake completed).
    public var isEstablished: Bool { client.isEstablished }

    /// Whether the connection has been closed (locally or by the peer).
    public var isClosed: Bool { client.isClosed }

    /// Opens a new bidirectional QUIC stream and exposes it as a mux
    /// stream. Opening alone produces no wire bytes; the first write sends them.
    ///
    /// - Throws: ``NodeError/connectionClosed`` if the connection is gone.
    public func openStream() throws(NodeError) -> QUICStream<Transport, Timer> {
        let id: UInt64
        do {
            id = try client.openStream(bidirectional: true)
        } catch {
            // `error` binds as `QUICEngineError`; bare catch.
            throw .connectionClosed
        }
        return QUICStream(client: client, timer: timer, streamID: id)
    }

    /// Waits for the next peer-opened stream and exposes it, or `nil` if none
    /// arrives before the connection closes. Polls the engine's new-stream events
    /// over the injected timer (the facade has no callback seam).
    public func acceptStream(
        deadlineNanos: UInt64
    ) async -> QUICStream<Transport, Timer>? {
        while true {
            let newStreams = client.takeNewStreams()
            if let id = newStreams.first {
                return QUICStream(client: client, timer: timer, streamID: id)
            }
            if client.isClosed { return nil }
            if timer.monotonicNanos() >= deadlineNanos { return nil }
            do {
                try await timer.sleep(untilNanos: timer.monotonicNanos() &+ 2_000_000)
            } catch {
                return nil
            }
        }
    }

    /// Closes the connection gracefully and tears down the engine run loop.
    public func close() async {
        await client.close(errorCode: 0, reason: [], isApplicationError: true)
        runTask.cancel()
    }
}
