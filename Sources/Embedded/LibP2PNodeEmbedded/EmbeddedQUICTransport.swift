// EmbeddedQUICTransport.swift
// Wraps swift-quic's `[UInt8]` engine facade (`QUICEngineClient<Transport, Timer>`)
// as the Embedded node's transport seam. It injects the two platform seams the
// facade needs — a `DatagramTransport` (UDP I/O) and an `AsyncTimer` (clock+sleep) —
// and exposes the established connection's stream surface as a raw `[UInt8]`
// connection over which security/mux/negotiation run. Embedded-clean: monomorphic
// over `<Transport, Timer>`, `[UInt8]`/`SocketEndpoint` currency, no `any`, no
// Foundation, typed throws.
//
// SLICE-1 SCOPE (explicit, no silent fallback): the engine facade is the TLS-seam
// boundary — it expects an external TLS 1.3 handshake driver to feed it CRYPTO
// bytes (`queueHandshake` / `installKeys` / `takeHandshakeData`). That driver (the
// libp2p-over-QUIC TLS handshake) is NOT wired in this slice; ``dial`` / ``listen``
// therefore surface ``EmbeddedNodeError/quicFeatureUnsupported`` rather than
// silently producing an un-handshaken connection. The facade is fully constructed
// and its run loop is runnable; the next slice wires the TLS handshake driver.

import _Concurrency   // REQUIRED under Embedded for async/Task
import P2PCoreCrypto       // AsyncTimer
import P2PCoreTransport    // DatagramTransport / SocketEndpoint
import P2PCrypto           // DefaultCryptoProvider
import QUIC                // QUICEngineClient / QUICPeerValidator
import QUICConnectionEngineCore  // QUICConnectionEngineConfiguration / QUICEngineError

/// The Embedded node's QUIC transport, wrapping ``QUICEngineClient``.
///
/// Monomorphic over the injected `Transport` (UDP datagram I/O) and `Timer`
/// (monotonic clock + sleep) seams — the same two seams the QUIC facade requires.
/// The crypto provider is pinned by the facade to ``DefaultCryptoProvider`` (host
/// swift-crypto / Embedded BoringSSL), so the embedder never spells the crypto
/// generic.
public struct EmbeddedQUICTransport<
    Transport: DatagramTransport,
    Timer: AsyncTimer
>: Sendable {

    private let transport: Transport
    private let timer: Timer

    public init(transport: Transport, timer: Timer) {
        self.transport = transport
        self.timer = timer
    }

    /// Builds the underlying ``QUICEngineClient`` for `peer` from `configuration`.
    ///
    /// The returned client's ``QUICEngineClient/run()`` drives the connection I/O +
    /// timer loops over the injected seams. The TLS handshake hand-off
    /// (`queueHandshake`/`installKeys`) is the caller's responsibility and is NOT
    /// wired in this slice — see ``dial`` / ``listen``.
    ///
    /// - Throws: ``EmbeddedNodeError/quicFeatureUnsupported`` if the engine facade
    ///   rejects the configuration (mapped from `QUICEngineError`).
    public func makeClient(
        configuration: QUICConnectionEngineConfiguration<DefaultCryptoProvider>,
        peer: SocketEndpoint,
        peerValidator: QUICPeerValidator? = nil
    ) throws(EmbeddedNodeError) -> QUICEngineClient<Transport, Timer> {
        let client: QUICEngineClient<Transport, Timer>
        do {
            client = try QUICEngineClient(
                configuration: configuration,
                transport: transport,
                timer: timer,
                peer: peer,
                peerValidator: peerValidator
            )
        } catch {
            // `error` binds as `QUICEngineError`; bare catch (no cross-type `as`).
            // The engine facade rejected the configuration (e.g. unsupported
            // version with no Initial salt).
            throw .quicFeatureUnsupported
        }
        return client
    }

    /// Dials `peer` and returns a raw `[UInt8]` connection once established.
    ///
    /// NOT WIRED IN THIS SLICE: establishing a libp2p-over-QUIC connection requires
    /// driving the TLS 1.3 handshake through the facade's TLS seam, which is the
    /// next slice. This entrypoint exists so the transport surface is complete and
    /// fails CLOSED (typed throw) rather than returning an un-handshaken connection.
    ///
    /// - Throws: ``EmbeddedNodeError/quicFeatureUnsupported`` — always, this slice.
    public func dial(
        configuration: QUICConnectionEngineConfiguration<DefaultCryptoProvider>,
        peer: SocketEndpoint,
        peerValidator: QUICPeerValidator? = nil
    ) async throws(EmbeddedNodeError) -> EmbeddedQUICRawConnection<Transport, Timer> {
        // Construct the facade (validates configuration / derives Initial keys).
        let client = try makeClient(
            configuration: configuration, peer: peer, peerValidator: peerValidator
        )
        // The TLS handshake driver is the next slice; do not silently hand back an
        // un-handshaken connection. The unsupported feature here is the
        // libp2p-over-QUIC TLS 1.3 handshake driver.
        _ = client
        throw .quicFeatureUnsupported
    }
}

/// A raw `[UInt8]` connection over a single established QUIC stream.
///
/// Wraps a ``QUICEngineClient`` and a stream id, surfacing the stream's
/// `[UInt8]` read/write as an ``EmbeddedRawConnection``. Construction is internal:
/// it is produced once the QUIC handshake completes (next slice). The read side
/// drains the engine's contiguous receive buffer for the stream.
public final class EmbeddedQUICRawConnection<
    Transport: DatagramTransport,
    Timer: AsyncTimer
>: EmbeddedRawConnection {

    private let client: QUICEngineClient<Transport, Timer>
    private let streamID: UInt64

    init(client: QUICEngineClient<Transport, Timer>, streamID: UInt64) {
        self.client = client
        self.streamID = streamID
    }

    public func read() async throws(EmbeddedNodeError) -> [UInt8] {
        // The engine surfaces contiguous received bytes per stream. A nil result
        // means nothing is buffered yet; the next slice wires a readability event
        // wait. For now, return what is buffered or empty (EOF) if closed.
        if let bytes = client.readStream(streamID) {
            return bytes
        }
        if client.isClosed {
            throw .connectionClosed
        }
        return []
    }

    public func write(_ data: [UInt8]) async throws(EmbeddedNodeError) {
        do {
            try await client.writeStream(streamID, data: data)
        } catch {
            // `error` binds as `QUICEngineError`; bare catch (no cross-type `as`).
            throw .transportFailure
        }
    }

    public func close() async {
        await client.close(errorCode: 0, reason: [], isApplicationError: true)
    }
}
