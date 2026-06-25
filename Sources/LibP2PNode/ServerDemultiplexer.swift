// ServerDemultiplexer.swift
// THE server-demux primitive: one shared inbound `DatagramTransport` fans out to
// MANY concurrent dialers. It reads the shared transport's `incoming`, parses each
// datagram's QUIC long-header Destination Connection ID (PUBLIC header only — it does
// NOT decrypt), and routes the datagram to the matching per-dialer
// `DemuxRoutedTransport`. A datagram whose long-header DCID matches no live dialer and
// is an Initial packet is a NEW dialer: the demux mints a routed transport for it and
// surfaces a ``NewDialer`` event so the `Node` can spin up a server-side handshake.
//
// WHY (RFC 9001 §5.2 / RFC 9000 §7.2): a QUIC server derives its Initial keys from the
// dialer's *original* DCID, which it only learns from the first Initial packet. The
// single-accept path coordinates that DCID up front through the `ConnectionIDPlan`
// seam; the demux instead READS it off the wire, so one `listen`/`serve` handles
// arbitrary unknown dialers. After the server replies (ServerHello carrying the
// server's chosen source CID), the client switches its DCID to that server SCID, so
// the demux registers each dialer under BOTH keys: the dialer's original DCID (its
// Initial packets) and the server's source CID (its Handshake + 1-RTT packets).
//
// Embedded-clean: monomorphic over `<Shared: DatagramTransport>`, `[UInt8]`/
// `SocketEndpoint` currency, no Foundation, no `any`, an `AsyncStream` of events, a
// test-and-set spinlock for the routing table, typed throws, bare `catch`.

import _Concurrency   // REQUIRED under Embedded for AsyncStream/Task
import Synchronization  // Atomic (Embedded-available) for the routing-table spinlock
import P2PCoreBytes
import P2PCoreCrypto
import P2PCoreTransport
import QUICWire        // ProtectedPacketHeader / ProtectedLongHeader / ConnectionID

/// Demultiplexes a shared inbound `DatagramTransport` into per-dialer transports,
/// keyed by QUIC Destination Connection ID.
///
/// Monomorphic over the `Shared` transport. The `Node` drives ``newDialers`` to learn
/// of each fresh inbound dialer (its routed transport + parsed CIDs), runs a server
/// handshake over that routed transport, and routes subsequent datagrams to it.
public final class ServerDemultiplexer<Shared: DatagramTransport>: @unchecked Sendable {

    /// A freshly-observed inbound dialer: the per-dialer transport the demux routes
    /// its datagrams to, plus the CIDs parsed from its first Initial packet and the
    /// server's freshly-minted source CID (the second routing key).
    public struct NewDialer: Sendable {
        /// The per-dialer transport the server handshake runs over.
        public let transport: DemuxRoutedTransport<Shared>
        /// The dialer's chosen original Destination CID (derives the Initial keys).
        public let originalDestinationConnectionID: ConnectionID
        /// The dialer's source CID (the server's destination CID for replies).
        public let dialerSourceConnectionID: ConnectionID
        /// The server's freshly-minted source CID (the dialer's post-ServerHello DCID,
        /// the second routing key).
        public let serverConnectionID: ConnectionID
        /// The dialer's endpoint (where the server's outbound datagrams go).
        public let dialerEndpoint: SocketEndpoint
    }

    /// The shared inbound transport every dialer's datagrams arrive on.
    private let shared: Shared

    /// Mints the server's per-dialer source CID (the second routing key). Throwing
    /// closure over the injected ``ConnectionIDPlan`` seam — fail-closed if a CID
    /// cannot be minted (the dialer is then dropped, never silently mis-routed).
    private let mintServerConnectionID: @Sendable () throws(NodeError) -> ConnectionID

    /// The byte length of the server's source CIDs, needed to parse the DCID of an
    /// inbound SHORT-header (1-RTT) packet (its length is not on the wire).
    private let serverConnectionIDLength: Int

    /// The routing table: CID bytes → the dialer's routed transport. Each dialer is
    /// registered under two keys (its original DCID, the server's source CID).
    /// Guarded by `lockFlag`.
    private var routes: [[UInt8]: DemuxRoutedTransport<Shared>]

    /// The set of original-DCID keys already seen, so a retransmitted first Initial
    /// (before the server's reply lands) routes to the existing dialer instead of
    /// spawning a duplicate. Guarded by `lockFlag`.
    private var knownInitialDCIDs: [[UInt8]: Bool]

    private let lockFlag = Atomic<Bool>(false)

    /// The stream of fresh inbound dialers (one element per new dialer).
    public let newDialers: AsyncStream<NewDialer>
    private let dialerContinuation: AsyncStream<NewDialer>.Continuation

    /// The background datagram-reader task, cancelled on ``shutdown()``.
    private var readerTask: Task<Void, Never>?

    /// Creates a demultiplexer over `shared`.
    ///
    /// - Parameters:
    ///   - shared: the shared inbound transport carrying every dialer's datagrams.
    ///   - serverConnectionIDLength: the byte length of the server's source CIDs
    ///     (for short-header DCID parsing — must match what `mintServerConnectionID`
    ///     produces).
    ///   - mintServerConnectionID: mints a fresh server source CID per dialer.
    public init(
        shared: Shared,
        serverConnectionIDLength: Int,
        mintServerConnectionID: @escaping @Sendable () throws(NodeError) -> ConnectionID
    ) {
        self.shared = shared
        self.mintServerConnectionID = mintServerConnectionID
        self.serverConnectionIDLength = serverConnectionIDLength
        self.routes = [:]
        self.knownInitialDCIDs = [:]
        var cont: AsyncStream<NewDialer>.Continuation!
        self.newDialers = AsyncStream<NewDialer> { cont = $0 }
        self.dialerContinuation = cont
        self.readerTask = nil
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

    /// Starts the background datagram-reader loop. Call once. The loop drains the
    /// shared transport's `incoming`, routing each datagram by DCID and surfacing new
    /// dialers on ``newDialers``.
    public func start() {
        // Embedded Swift forbids `weak`; the task captures `self` strongly. The cycle
        // (the demux holds the task; the task holds the demux) is broken by
        // ``shutdown()`` (cancels the task + finishes the inner stream) and by the
        // shared `incoming` ending — both terminate the task, releasing the capture.
        let task = Task {
            do {
                for try await datagram in self.shared.incoming {
                    self.route(datagram)
                    if Task.isCancelled { break }
                }
            } catch {
                // Shared iteration ended (closed / I/O failure); stop demuxing. The
                // dialers tear down via their own engines. We do not silently retry.
            }
            // Shared transport ended — finish the new-dialer stream and every route.
            self.finishAll()
        }
        withLock { readerTask = task }
    }

    /// Shuts the demux down: cancels the reader, finishes every routed transport, and
    /// ends ``newDialers``. Idempotent.
    public func shutdown() {
        let task = withLock { readerTask }
        task?.cancel()
        finishAll()
    }

    // MARK: - Routing

    /// Routes one inbound datagram to the matching dialer, or — for an unknown-DCID
    /// Initial — registers a new dialer and surfaces it on ``newDialers``.
    private func route(_ datagram: Datagram) {
        let bytes = datagram.payload
        guard let first = bytes.first else { return }

        let isLongHeader = (first & 0x80) != 0
        if isLongHeader {
            routeLongHeader(datagram)
        } else {
            routeShortHeader(datagram)
        }
    }

    /// Routes a long-header (Initial / Handshake / 0-RTT) datagram by its DCID. An
    /// unknown DCID that is an Initial is a NEW dialer; any other unknown long-header
    /// packet is dropped (never silently mis-routed).
    private func routeLongHeader(_ datagram: Datagram) {
        let parsed: ProtectedLongHeader
        do {
            (parsed, _) = try ProtectedLongHeader.parse(from: datagram.payload)
        } catch {
            // A malformed long header is dropped (it cannot be routed); the QUIC
            // engines are unaffected. Never fabricate a route.
            return
        }
        let dcidKey = parsed.destinationConnectionID.bytes

        // An existing route (matched DCID): deliver and return.
        if let existing = withLock({ routes[dcidKey] }) {
            existing.deliver(datagram)
            return
        }

        // Unknown DCID. Only an Initial packet opens a new dialer; any other
        // long-header packet for an unknown DCID is stray — drop it.
        guard parsed.packetType == .initial else {
            return
        }
        registerNewDialer(parsed: parsed, datagram: datagram, dcidKey: dcidKey)
    }

    /// Registers a fresh inbound dialer for an unknown-DCID Initial packet: mints the
    /// server's source CID, builds the routed transport, installs both routing keys,
    /// delivers this first datagram, and surfaces the dialer on ``newDialers``.
    private func registerNewDialer(
        parsed: ProtectedLongHeader,
        datagram: Datagram,
        dcidKey: [UInt8]
    ) {
        // A retransmitted first Initial (before the server's reply lands) must route
        // to the in-flight dialer, not spawn a duplicate. Claim the DCID atomically.
        let alreadyClaimed = withLock { () -> Bool in
            if knownInitialDCIDs[dcidKey] != nil { return true }
            knownInitialDCIDs[dcidKey] = true
            return false
        }
        if alreadyClaimed {
            // A route may already exist (registered by the winning claim). Deliver if
            // so; otherwise drop this retransmit (the winning path will deliver its
            // own copy and register the route).
            if let existing = withLock({ routes[dcidKey] }) {
                existing.deliver(datagram)
            }
            return
        }

        // Mint the server's source CID (the second routing key). Fail-closed: if a CID
        // cannot be minted, drop this dialer rather than mis-route it.
        let serverCID: ConnectionID
        do {
            serverCID = try mintServerConnectionID()
        } catch {
            // Release the DCID claim so a later retransmit can retry.
            withLock { knownInitialDCIDs[dcidKey] = nil }
            return
        }

        let routed = DemuxRoutedTransport(shared: shared, dialerEndpoint: datagram.source)
        let serverCIDKey = serverCID.bytes
        withLock {
            routes[dcidKey] = routed
            routes[serverCIDKey] = routed
        }
        // Deliver the first Initial to the new dialer BEFORE surfacing it, so the
        // server handshake's first `takeHandshakeData` sees the ClientHello.
        routed.deliver(datagram)

        dialerContinuation.yield(
            NewDialer(
                transport: routed,
                originalDestinationConnectionID: parsed.destinationConnectionID,
                dialerSourceConnectionID: parsed.sourceConnectionID,
                serverConnectionID: serverCID,
                dialerEndpoint: datagram.source
            )
        )
    }

    /// Routes a short-header (1-RTT) datagram by its DCID (length = the server's
    /// source-CID length). An unknown DCID is dropped (a stray 1-RTT for a dead
    /// connection); never silently mis-routed.
    private func routeShortHeader(_ datagram: Datagram) {
        let parsed: ProtectedShortHeader
        do {
            (parsed, _) = try ProtectedShortHeader.parse(
                from: datagram.payload, dcidLength: serverConnectionIDLength)
        } catch {
            return
        }
        let dcidKey = parsed.destinationConnectionID.bytes
        if let existing = withLock({ routes[dcidKey] }) {
            existing.deliver(datagram)
        }
    }

    // MARK: - Teardown

    /// Finishes every routed transport and ends ``newDialers``. Idempotent.
    private func finishAll() {
        let all = withLock { () -> [DemuxRoutedTransport<Shared>] in
            var transports = [DemuxRoutedTransport<Shared>]()
            for (_, transport) in routes {
                transports.append(transport)
            }
            routes.removeAll()
            knownInitialDCIDs.removeAll()
            return transports
        }
        // Each dialer is registered under two keys, so a transport may appear twice;
        // `DemuxRoutedTransport.finish()` is idempotent, so a double-finish is harmless.
        for transport in all {
            transport.finish()
        }
        dialerContinuation.finish()
    }
}
