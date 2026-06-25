// EmbeddedQUICStream.swift
// Exposes a QUIC native stream as an ``EmbeddedMuxedStream`` (`[UInt8]` surface).
// On the QUIC path the multiplexer IS QUIC: there is no Yamux. A QUIC stream maps
// directly onto the mux stream the node hands protocol handlers — `read`/`write`/
// `close` forward to `QUICEngineClient.readStream/writeStream/finishStream`.
//
// Read model: the engine surfaces contiguous received bytes per stream via
// `readStream(_:)` (or `nil` when nothing is buffered). This wrapper polls the
// engine over the injected `AsyncTimer` until bytes arrive, the stream finishes,
// or the connection closes — there is no callback seam on the facade. Embedded-
// clean: `[UInt8]` currency, no `any`, no Foundation, typed throws, no try?/try!.

import _Concurrency   // REQUIRED under Embedded for async/Task
import P2PCoreCrypto       // AsyncTimer
import P2PCoreTransport    // DatagramTransport
import QUIC                // QUICEngineClient
import QUICConnectionEngineCore  // QUICEngineError

/// A QUIC native stream presented as an Embedded mux stream (`[UInt8]`).
public final class EmbeddedQUICStream<
    Transport: DatagramTransport,
    Timer: AsyncTimer
>: EmbeddedMuxedStream {

    private let client: QUICEngineClient<Transport, Timer>
    private let timer: Timer
    private let streamID: UInt64

    /// The poll interval used while waiting for inbound bytes (nanoseconds).
    private static var pollIntervalNanos: UInt64 { 2_000_000 }

    init(client: QUICEngineClient<Transport, Timer>, timer: Timer, streamID: UInt64) {
        self.client = client
        self.timer = timer
        self.streamID = streamID
    }

    public var id: UInt64 { streamID }

    public func read() async throws(EmbeddedNodeError) -> [UInt8] {
        while true {
            if let bytes = client.readStream(streamID), !bytes.isEmpty {
                return bytes
            }
            if client.isClosed {
                // Clean end-of-stream when the connection is gone with nothing
                // buffered. An empty return signals the remote half-closed (FIN).
                return []
            }
            do {
                try await timer.sleep(untilNanos: timer.monotonicNanos() &+ Self.pollIntervalNanos)
            } catch {
                // The wait was cancelled — surface the stream as closed (fail-closed,
                // no silent retry on an external cancel).
                throw .yamuxStreamClosed
            }
        }
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
        do {
            try await client.finishStream(streamID)
        } catch {
            // A finish failure means the stream/connection is already gone; the
            // send side is closed regardless. No silent retry.
        }
    }
}
