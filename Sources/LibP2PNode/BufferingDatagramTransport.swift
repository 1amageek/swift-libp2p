// BufferingDatagramTransport.swift
// A `DatagramTransport` wrapper that buffers recently-received inbound datagrams
// and can REPLAY them on demand. This implements the RFC 9001 §5.7 packet-buffering
// the QUIC engine explicitly defers to "the facade's concern": a Handshake-level
// packet that arrives BEFORE the TLS handshake driver has installed the matching
// read keys is dropped by the engine (it cannot decrypt yet) and — because the
// engine's PTO probe is a bare PING, not a CRYPTO retransmission — would otherwise
// never be recovered, deadlocking the handshake.
//
// This wrapper tees every inbound datagram into a bounded ring buffer as it
// forwards it. After the driver installs new keys (handshake / application), it
// calls ``replayBuffered()``, which re-yields the buffered datagrams into the
// engine's `incoming` stream. A datagram the engine already decrypted is harmlessly
// de-duplicated by QUIC's per-space packet-number tracking; one it previously
// dropped now decrypts under the freshly-installed keys.
//
// Embedded-clean: `[UInt8]`/`SocketEndpoint` currency, no Foundation, no `any`,
// typed throws, `import _Concurrency` for the forwarding task + AsyncStream.

import _Concurrency   // REQUIRED under Embedded for AsyncStream/Task
import Synchronization  // Atomic (Embedded-available) for the replay-buffer spinlock
import P2PCoreBytes
import P2PCoreCrypto
import P2PCoreTransport

/// Wraps an inner ``DatagramTransport``, buffering inbound datagrams for replay.
///
/// `incoming` is a single `AsyncStream<Datagram>` the engine iterates: a forwarding
/// task drains the inner transport's `incoming` into it (buffering each datagram),
/// and ``replayBuffered()`` re-yields the buffer into the same stream. Sends forward
/// directly to the inner transport.
public final class BufferingDatagramTransport<Inner: DatagramTransport>: DatagramTransport, @unchecked Sendable {
    public typealias Incoming = AsyncStream<Datagram>

    private let inner: Inner

    public let incoming: AsyncStream<Datagram>
    private let continuation: AsyncStream<Datagram>.Continuation

    /// The bounded ring buffer of recently-received datagrams (for replay). Guarded
    /// by `lockFlag` (a test-and-set spinlock). `@unchecked Sendable` is sound
    /// because every access to this mutable state goes through ``withLock(_:)``.
    private var buffer: [Datagram] = []
    private let maxBuffered: Int
    private let lockFlag = Atomic<Bool>(false)

    /// The task forwarding `inner.incoming` into `incoming`. Guarded by `lockFlag`.
    private var forwardTask: Task<Void, Never>?

    public init(inner: Inner, maxBuffered: Int = 64) {
        self.inner = inner
        self.maxBuffered = maxBuffered
        var cont: AsyncStream<Datagram>.Continuation!
        self.incoming = AsyncStream<Datagram> { cont = $0 }
        self.continuation = cont
        self.forwardTask = nil
        startForwarding()
    }

    /// Runs `body` under the spinlock (mirrors swift-quic's Embedded `FacadeLock`).
    private func withLock<R>(_ body: () -> R) -> R {
        while true {
            if lockFlag.compareExchange(
                expected: false, desired: true, ordering: .acquiring
            ).exchanged {
                break
            }
        }
        defer { lockFlag.store(false, ordering: .releasing) }
        return body()
    }

    public var maximumDatagramSize: Int { inner.maximumDatagramSize }

    public func send(_ payload: Span<UInt8>, to endpoint: SocketEndpoint) async throws(TransportError) {
        try await inner.send(payload, to: endpoint)
    }

    public func close() async {
        let task = withLock { forwardTask }
        task?.cancel()
        continuation.finish()
        await inner.close()
    }

    /// Re-yields the buffered inbound datagrams into `incoming` so the engine
    /// re-processes them under newly-installed keys (RFC 9001 §5.7). Idempotent and
    /// safe to over-call: re-decrypted duplicates are de-duplicated by QUIC.
    public func replayBuffered() {
        let snapshot = withLock { buffer }
        for datagram in snapshot {
            continuation.yield(datagram)
        }
    }

    // MARK: - Private

    private func startForwarding() {
        // Embedded Swift forbids `weak`. The forwarding task captures `self`
        // strongly: the resulting cycle (the class holds the task; the task holds
        // the class) is broken by ``close()`` (which cancels the task and finishes
        // the inner stream), and by the inner stream ending — both terminate the
        // task, releasing the capture. The connection has a bounded lifetime.
        let task = Task {
            do {
                for try await datagram in self.inner.incoming {
                    self.record(datagram)
                    self.continuation.yield(datagram)
                }
            } catch {
                // Inner iteration errored (transport closed / I/O failure); we stop
                // forwarding. The connection tears down via the engine's run loop.
            }
            // Inner stream ended — terminate ours.
            self.continuation.finish()
        }
        withLock { forwardTask = task }
    }

    private func record(_ datagram: Datagram) {
        withLock {
            buffer.append(datagram)
            if buffer.count > maxBuffered {
                buffer.removeFirst(buffer.count - maxBuffered)
            }
        }
    }
}
