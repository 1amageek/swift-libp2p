// DemuxRoutedTransport.swift
// The per-dialer `DatagramTransport` a server-demultiplexed inbound QUIC connection
// runs over. One shared UDP transport carries datagrams from MANY dialers; the
// `ServerDemultiplexer` parses each inbound datagram's Destination Connection ID and
// routes it to the matching dialer's `DemuxRoutedTransport.incoming`. The connection
// SENDS through the same shared transport, addressed to the dialer's endpoint.
//
// RESPONSIBILITY (single): be the `DatagramTransport` seam for ONE demuxed dialer —
// surface the datagrams the demux routed to it, and forward this connection's
// outbound datagrams to the dialer's endpoint over the shared transport. It owns no
// socket; the shared transport does.
//
// Embedded-clean: `[UInt8]`/`SocketEndpoint` currency, no Foundation, no `any`, an
// `AsyncStream<Datagram>` inbound, a test-and-set spinlock (mirrors
// `BufferingDatagramTransport`), typed throws.

import _Concurrency   // REQUIRED under Embedded for AsyncStream/Task
import Synchronization  // Atomic (Embedded-available) for the routed-state spinlock
import P2PCoreBytes
import P2PCoreCrypto
import P2PCoreTransport

/// A `DatagramTransport` for ONE server-demultiplexed inbound dialer.
///
/// `incoming` is an `AsyncStream<Datagram>` the per-dialer QUIC engine iterates; the
/// `ServerDemultiplexer` feeds it the datagrams whose DCID matched this dialer.
/// `send` forwards to the shared transport, addressed to the dialer's endpoint.
public final class DemuxRoutedTransport<Shared: DatagramTransport>: DatagramTransport, @unchecked Sendable {
    public typealias Incoming = AsyncStream<Datagram>

    /// The shared UDP transport every dialer's connection sends through.
    private let shared: Shared

    /// The dialer endpoint this connection's outbound datagrams are addressed to.
    private let dialerEndpoint: SocketEndpoint

    public let incoming: AsyncStream<Datagram>
    private let continuation: AsyncStream<Datagram>.Continuation

    /// `true` once ``finish()`` (demux teardown) or ``close()`` has run. Guarded by
    /// `lockFlag`. After it is set, ``deliver(_:)`` drops rather than yields.
    private var finished: Bool = false
    private let lockFlag = Atomic<Bool>(false)

    public init(shared: Shared, dialerEndpoint: SocketEndpoint) {
        self.shared = shared
        self.dialerEndpoint = dialerEndpoint
        var cont: AsyncStream<Datagram>.Continuation!
        self.incoming = AsyncStream<Datagram> { cont = $0 }
        self.continuation = cont
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

    public var maximumDatagramSize: Int { shared.maximumDatagramSize }

    /// Forwards `payload` to the dialer endpoint over the SHARED transport (the demux
    /// owns no socket of its own).
    public func send(_ payload: Span<UInt8>, to endpoint: SocketEndpoint) async throws(TransportError) {
        // The engine sends to its configured `peer`; route every outbound datagram to
        // this dialer's endpoint regardless (the demux pins the peer).
        _ = endpoint
        try await shared.send(payload, to: dialerEndpoint)
    }

    /// The `DatagramTransport` close contract. The demux owns the shared transport's
    /// lifetime, so closing one dialer must NOT close the shared socket — it only
    /// terminates THIS dialer's `incoming` (idempotent).
    public func close() async {
        finish()
    }

    // MARK: - Demux-facing API

    /// Delivers a routed inbound datagram to this dialer's `incoming`. A no-op once
    /// finished (the connection is torn down; never a yield after `finish()`).
    func deliver(_ datagram: Datagram) {
        let isFinished = withLock { finished }
        if isFinished { return }
        continuation.yield(datagram)
    }

    /// Terminates this dialer's `incoming` (the for-await loop ends). Idempotent and
    /// safe to over-call. Does NOT touch the shared transport.
    func finish() {
        let alreadyFinished = withLock { () -> Bool in
            if finished { return true }
            finished = true
            return false
        }
        if alreadyFinished { return }
        continuation.finish()
    }
}
