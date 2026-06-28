// Node.swift
// THE libp2p node facade — the composition root that ties the QUIC transport +
// TLS-1.3 security + native-stream mux + multistream-select negotiation + the
// Ping/Identify protocols into a single, real libp2p peer. It is the seam-based node
// that compiles on BOTH host and Embedded Swift (the milestone: a robot/IoT device
// is a libp2p peer). Named by responsibility — there is no `Embedded`/`Byte`
// qualifier; "Embedded" only ever names the build.
//
// PUBLIC API (the facade):
//   * `listen(on:)`    — bind the QUIC transport, accept an inbound connection,
//                        upgrade it (QUIC TLS 1.3 → verified PeerID), and serve the
//                        registered protocol handlers via `ProtocolRouter` on its
//                        inbound streams.
//   * `dial(to:)`      — establish + upgrade a QUIC connection, return the verified
//                        remote PeerID, track it in the connection manager (reusing
//                        an existing live connection to the same peer).
//   * `newStream(to:protocol:)` — open a QUIC stream to a connected peer, negotiate
//                        the protocol via multistream-select, return the ready stream.
//   * `handle(_:_:)`   — register an inbound protocol handler (routed by id).
//   * `ping(_:)` / `identify(_:)` — convenience over the built-in protocols.
//   * `close()`        — shut down (close connections, cancel accept/serve tasks).
//
// SOLID: the `Node` is the composition root — the `QUICTransport`, the
// `ConnectionManager`, the `ProtocolRouter` (built per inbound connection), the
// `PingService`/`IdentifyService`, and the seams (`DatagramTransport`/`AsyncTimer`/
// crypto/`ConnectionIDPlan`) are all INJECTED or COMPOSED, each with a single
// responsibility. The node owns lifecycle + routing; it delegates I/O to the parts.
//
// FAIL-CLOSED: a dial/upgrade/negotiate failure is a typed `NodeError`, never a
// silent fallback; an unverified peer is NEVER admitted (the handshake's verified
// PeerID is the only identity the node trusts). No `try?`/`try!`.
//
// Embedded-clean: an actor (Embedded-OK), monomorphic over
// `<Transport, Timer, IDs: ConnectionIDPlan>`, pinned to `DefaultCryptoProvider`,
// `[UInt8]` currency, no `any`, no Foundation, no `ContinuousClock`/`Task.sleep`
// (the timer seam drives every deadline), typed throws.

import _Concurrency   // REQUIRED under Embedded for async/Task
import P2PCoreBytes
import P2PCoreCrypto       // AsyncTimer / WallClock
import P2PCoreTransport    // DatagramTransport / SocketEndpoint
import P2PCrypto           // DefaultCryptoProvider
import QUICTLSSignature    // QUICTLSSignatureProvider (DER ECDSA for the TLS path)
import LibP2PCore          // IdentifyFields
import QUICConnectionEngineCore  // QUICEngineRole

/// A minimal, real libp2p node over the QUIC transport.
///
/// Monomorphic over the datagram `Transport`, the `Timer` clock, and the
/// `ConnectionIDPlan` that mints the per-connection QUIC connection IDs (see
/// ``QUICConnectionParameters`` for why CID coordination is a seam on this slice).
/// The crypto provider is pinned to ``DefaultCryptoProvider`` so the embedder never
/// spells the crypto generic.
public actor Node<
    Transport: DatagramTransport,
    Timer: AsyncTimer,
    IDs: ConnectionIDPlan,
    Clock: WallClock
> {

    /// The concrete inbound-stream type the node hands protocol handlers: a
    /// residual-aware wrapper over a QUIC native stream. It IS a ``MuxedStream`` —
    /// the node stays monomorphic (no `any`) while handlers read/write `[UInt8]`.
    public typealias Stream = BufferedMuxedStream<QUICStream<BufferingDatagramTransport<Transport>, Timer>>

    /// A registered inbound protocol handler over the node's concrete stream type.
    public typealias Handler = @Sendable (Stream) async -> Void

    /// The node's verified-connection type (the QUIC transport wraps the datagram
    /// transport in a replay-buffer for the handshake — see ``BufferingDatagramTransport``).
    public typealias Connection = QUICConnection<BufferingDatagramTransport<Transport>, Timer>

    // MARK: - Injected seams + composed parts

    private let identity: NodeIdentity<QUICTLSSignatureProvider>
    private let transport: QUICTransport<Transport, Timer, Clock>
    private let timer: Timer
    private let wallClock: Clock
    private let parameters: QUICConnectionParameters
    private let connectionIDPlan: IDs
    private let connections: ConnectionManager<BufferingDatagramTransport<Transport>, Timer>

    /// Application inbound handlers registered via `handle(_:_:)`, in offer order.
    /// The built-ins (Identify, Ping) are NOT stored here — they are synthesised in
    /// `makeRoutes()` from the node's current state so a fresh node answers both out
    /// of the box and Identify always advertises the latest protocol set.
    private var handlers: [(protocolID: String, handler: Handler)]

    /// This node's Identify message (its public key + supported protocols). Rebuilt
    /// when `handle` registers a new protocol so Identify advertises it.
    private var identifyFields: IdentifyFields

    /// The background tasks the node owns (accept-loop / per-connection serve loops),
    /// cancelled on `close()`.
    private var serveTasks: [Task<Void, Never>]

    /// Whether `close()` has run (idempotent shutdown).
    private var isClosed: Bool

    /// The negotiation deadline budget for an inbound dispatch / outbound newStream
    /// (nanoseconds).
    private let negotiationTimeoutNanos: UInt64

    // MARK: - Construction

    /// Builds a node from its identity and the injected seams.
    ///
    /// The Identify (`/ipfs/id/1.0.0`) and Ping (`/ipfs/ping/1.0.0`) handlers are
    /// auto-registered so a fresh node answers both immediately.
    ///
    /// - Parameters:
    ///   - identity: the node's Ed25519 libp2p identity.
    ///   - datagramTransport: the UDP datagram seam the QUIC transport binds over.
    ///   - timer: the monotonic-clock + sleep seam (no `ContinuousClock`).
    ///   - wallClock: the wall-clock (calendar) seam used to timestamp the libp2p
    ///     RPK certificate's notBefore/notAfter as real Unix-epoch seconds. REQUIRED
    ///     (no silent fallback to the monotonic clock): on host pass a system
    ///     clock-backed implementation; on Embedded supply a device-RTC-backed clock.
    ///   - parameters: the QUIC transport-parameter / timeout template.
    ///   - connectionIDPlan: the per-connection CID source (see
    ///     ``QUICConnectionParameters``).
    ///   - protocolVersion: the Identify `protocolVersion` string.
    ///   - agentVersion: the Identify `agentVersion` string.
    ///   - negotiationTimeoutNanos: the multistream-select deadline budget.
    public init(
        identity: NodeIdentity<QUICTLSSignatureProvider>,
        datagramTransport: Transport,
        timer: Timer,
        wallClock: Clock,
        parameters: QUICConnectionParameters,
        connectionIDPlan: IDs,
        protocolVersion: String = "ipfs/0.1.0",
        agentVersion: String = "swift-libp2p-node/0.1.0",
        negotiationTimeoutNanos: UInt64 = 10_000_000_000
    ) {
        self.identity = identity
        self.transport = QUICTransport(transport: datagramTransport, timer: timer, wallClock: wallClock)
        self.timer = timer
        self.wallClock = wallClock
        self.parameters = parameters
        self.connectionIDPlan = connectionIDPlan
        self.connections = ConnectionManager()
        self.serveTasks = []
        self.isClosed = false
        self.negotiationTimeoutNanos = negotiationTimeoutNanos

        // Identify advertises the built-in protocols out of the box. `handle(_:_:)`
        // appends application protocol ids as they are registered.
        self.identifyFields = IdentifyFields(
            publicKey: identity.protobufPublicKey,
            listenAddrs: [],
            protocols: [NodeProtocolID.identify, NodeProtocolID.ping],
            observedAddr: nil,
            protocolVersion: protocolVersion,
            agentVersion: agentVersion
        )
        // Only application handlers are stored; the built-in Identify/Ping routes are
        // synthesised from current state in `makeRoutes()`.
        self.handlers = []
    }

    // MARK: - Handler registration

    /// Registers an inbound protocol handler, routed by `protocolID`.
    ///
    /// The handler runs over the node's concrete ``Stream`` (a ``MuxedStream`` with a
    /// `[UInt8]` surface) AFTER multistream-select agrees `protocolID`. Registering a
    /// new id also adds it to the node's advertised Identify protocols. A handler for
    /// an already-registered id replaces the previous one (last registration wins).
    public func handle(_ protocolID: String, _ handler: @escaping Handler) async {
        for index in handlers.indices where handlers[index].protocolID == protocolID {
            handlers[index] = (protocolID, handler)
            return
        }
        handlers.append((protocolID, handler))
        // Advertise the newly-handled protocol via Identify (avoid duplicates).
        var protocols = identifyFields.protocols
        if !Self.contains(protocols, protocolID) {
            protocols.append(protocolID)
        }
        identifyFields = IdentifyFields(
            publicKey: identifyFields.publicKey,
            listenAddrs: identifyFields.listenAddrs,
            protocols: protocols,
            observedAddr: identifyFields.observedAddr,
            protocolVersion: identifyFields.protocolVersion,
            agentVersion: identifyFields.agentVersion
        )
    }

    // MARK: - Listen

    /// Binds the QUIC transport, accepts ONE inbound connection on `endpoint`,
    /// upgrades it (QUIC TLS 1.3 + mTLS → verified peer), tracks it by its verified
    /// PeerID, and serves the registered protocol handlers on its inbound streams
    /// until the node closes.
    ///
    /// SCOPE: this single-accept path needs the dialer's original-DCID coordinated up
    /// front through the ``ConnectionIDPlan`` seam (RFC 9001 §5.2). To fan out
    /// arbitrary unknown dialers over one shared transport, use ``serve(on:)`` — it
    /// demultiplexes inbound datagrams by Destination Connection ID and spins up a
    /// per-dialer connection (see ``ServerDemultiplexer``).
    ///
    /// - Throws: a typed ``NodeError`` if the accept/upgrade fails (fail-closed —
    ///   never a half-open connection).
    public func listen(on endpoint: SocketEndpoint) async throws(NodeError) {
        if isClosed { throw .connectionClosed }
        let ids = try connectionIDPlan.acceptConnectionIDs()
        let configuration = parameters.configuration(role: .server, connectionIDs: ids)
        let connection = try await transport.listen(
            configuration: configuration,
            peer: endpoint,
            identity: identity
        )
        // mTLS: the inbound peer presented + proved its libp2p RPK certificate, so the
        // server has the CLIENT's cryptographically-verified PeerID. Track it by that
        // verified identity — never anonymously. An empty PeerID would mean an
        // unverified peer slipped through; refuse it (fail-closed, never admitted).
        let peerID = connection.remotePeerIDMultihash
        guard !peerID.isEmpty else {
            await connection.close()
            throw .quicHandshakePeerVerificationFailed
        }
        let displaced = await connections.register(connection, peerID: peerID)
        if let displaced {
            await displaced.close()
        }
        startServing(connection)
    }

    // MARK: - Serve (server-demux: fan out arbitrary unknown dialers)

    /// Serves arbitrary concurrent inbound dialers over one shared `DatagramTransport`
    /// via the ``ServerDemultiplexer``.
    ///
    /// Unlike ``listen(on:)`` — which accepts ONE connection whose DCID is coordinated
    /// up front through the ``ConnectionIDPlan`` seam — `serve` reads each inbound
    /// datagram's QUIC long-header Destination Connection ID (parsed, not decrypted),
    /// spins up a per-dialer connection over a routed transport, completes the mTLS
    /// handshake, and tracks the dialer by its VERIFIED PeerID. One `serve` therefore
    /// fans out many dialers; the node serves protocol handlers on each, and its own
    /// ``newStream(to:protocol:)`` / ``ping(_:)`` / ``identify(_:)`` reach any of them
    /// by verified PeerID (so the listener can `identify` a dialer back).
    ///
    /// The node's `Transport` must be the demux's per-dialer routed transport
    /// (`DemuxRoutedTransport<Shared>`); construct such a node with the shared transport
    /// and start the demux's reader before calling `serve` (see the multi-dialer test).
    ///
    /// This returns immediately after starting the demux-drive loop; inbound dialers
    /// are handshaked + served on background tasks the node owns (cancelled on
    /// ``close()``).
    public func serve<Shared: DatagramTransport>(
        over demultiplexer: ServerDemultiplexer<Shared>
    ) async throws(NodeError) where Transport == DemuxRoutedTransport<Shared> {
        if isClosed { throw .connectionClosed }
        // The demux-drive loop. It captures `self` strongly: the resulting cycle (the
        // node holds the task in `serveTasks`; the task holds the node) is broken by
        // ``close()`` (cancels the task + shuts the demux down) and by the demux
        // finishing `newDialers` — both end the loop, releasing the capture (mirrors
        // ``BufferingDatagramTransport``; Embedded Swift forbids `weak`). Each dialer
        // is handshaked on its OWN child task so a slow / failed handshake never blocks
        // the others.
        let driveTask = Task {
            for await dialer in demultiplexer.newDialers {
                if Task.isCancelled { return }
                // The drive task inherits the actor's isolation, so `acceptDemuxedDialer`
                // and `serveTasks` mutation are same-actor; the child handshakes the
                // dialer concurrently without blocking the next.
                let child = Task { await self.acceptDemuxedDialer(dialer) }
                self.serveTasks.append(child)
            }
        }
        serveTasks.append(driveTask)
    }

    /// Completes one demuxed dialer's mTLS handshake over its routed transport, tracks
    /// it by its verified PeerID, and starts serving it. Fail-closed: an unverified
    /// dialer is dropped (never admitted); a handshake failure tears the routed
    /// transport down.
    private func acceptDemuxedDialer<Shared: DatagramTransport>(
        _ dialer: ServerDemultiplexer<Shared>.NewDialer
    ) async where Transport == DemuxRoutedTransport<Shared> {
        let ids = ConnectionIDs(
            localConnectionID: dialer.serverConnectionID,
            peerConnectionID: dialer.dialerSourceConnectionID,
            originalDestinationConnectionID: dialer.originalDestinationConnectionID
        )
        let configuration = parameters.configuration(role: .server, connectionIDs: ids)
        let connection: Connection
        do {
            connection = try await QUICTransport<Transport, Timer, Clock>.acceptServer(
                over: dialer.transport,
                configuration: configuration,
                peer: dialer.dialerEndpoint,
                identity: identity,
                timer: timer,
                wallClock: wallClock
            )
        } catch {
            // Handshake / verification failed — fail-closed: tear the routed transport
            // down (its `incoming` ends so the demux drops further datagrams for it).
            dialer.transport.finish()
            return
        }
        let peerID = connection.remotePeerIDMultihash
        guard !peerID.isEmpty else {
            await connection.close()
            dialer.transport.finish()
            return
        }
        if isClosed {
            // The node closed during the dialer's handshake; tear the connection down
            // rather than leak it.
            await connection.close()
            dialer.transport.finish()
            return
        }
        let displaced = await connections.register(connection, peerID: peerID)
        if let displaced {
            await displaced.close()
        }
        startServing(connection)
    }

    /// Spawns the per-connection serve loop: accept inbound streams and route each
    /// through the registered handlers via a fresh ``ProtocolRouter``.
    private func startServing(_ connection: Connection) {
        let routes = self.makeRoutes()
        let timer = self.timer
        let budget = self.negotiationTimeoutNanos
        let task = Task {
            let router = ProtocolRouter<QUICStream<BufferingDatagramTransport<Transport>, Timer>, Timer>(
                routes: routes,
                timer: timer,
                negotiationTimeoutNanos: budget
            )
            while !Task.isCancelled {
                if connection.isClosed { return }
                let deadline = timer.monotonicNanos() &+ budget
                guard let inbound = await connection.acceptStream(deadlineNanos: deadline) else {
                    if connection.isClosed { return }
                    // No stream within the budget but the connection is still live:
                    // keep serving (a long-lived connection idles between streams).
                    continue
                }
                // Each inbound stream is dispatched independently; a per-stream
                // failure (bad negotiation / handler error) ends that stream only,
                // never the whole serve loop — fail-closed per stream, resilient
                // connection.
                let dispatched = Task {
                    do {
                        try await router.dispatch(inbound: inbound)
                    } catch {
                        // The negotiation/handler failed for this stream; it is
                        // already half-closed by the failure. Surface nothing
                        // upstream — the per-stream contract is fail-closed.
                    }
                }
                _ = dispatched
            }
        }
        serveTasks.append(task)
    }

    /// Builds the `ProtocolRouter` routes for an inbound serve loop: the synthesised
    /// built-in Identify + Ping routes followed by the registered application
    /// handlers. Each route's body runs over the residual-aware ``Stream`` the router
    /// hands it (so no negotiation-coalesced application byte is dropped).
    private func makeRoutes() -> [ProtocolRouter<QUICStream<BufferingDatagramTransport<Transport>, Timer>, Timer>.Route] {
        typealias Route = ProtocolRouter<QUICStream<BufferingDatagramTransport<Transport>, Timer>, Timer>.Route
        var routes = [Route]()
        routes.reserveCapacity(handlers.count + 2)

        // Application handlers come FIRST so an explicit `handle(_:_:)` for a built-in
        // id deliberately overrides it (the router runs the first route matching the
        // agreed id) — never a silent shadow of a user's registration.
        for entry in handlers {
            let handler = entry.handler
            routes.append(
                Route(protocolID: entry.protocolID) { stream throws(NodeError) in
                    await handler(stream)
                }
            )
        }

        // Built-in Identify: respond with the node's current advertised fields (a
        // value snapshot — safe to capture into the @Sendable route body).
        let fields = identifyFields
        routes.append(
            Route(protocolID: NodeProtocolID.identify) { stream throws(NodeError) in
                do {
                    try await IdentifyService<DefaultCryptoProvider>.respond(on: stream, fields: fields)
                } catch {
                    // The stream is gone (write failure); the per-stream contract is
                    // fail-closed. End the handler — never a silent upstream retry.
                }
            }
        )
        // Built-in Ping: a pure 32-byte echo until the peer stops.
        routes.append(
            Route(protocolID: NodeProtocolID.ping) { stream throws(NodeError) in
                do {
                    try await PingService<DefaultCryptoProvider, Timer>.serve(on: stream)
                } catch {
                    // Truncated / closed stream: the peer stopped pinging; end here.
                }
            }
        )
        return routes
    }

    // MARK: - Dial

    /// Establishes + upgrades a QUIC connection to `endpoint` and returns the
    /// verified remote PeerID multihash.
    ///
    /// If a live connection to the resulting peer is already tracked it is REUSED
    /// (no second handshake). The new connection is tracked under its verified
    /// PeerID. The peer is admitted ONLY after the QUIC TLS 1.3 handshake
    /// cryptographically verified its RPK certificate — fail-closed.
    ///
    /// - Returns: the verified remote PeerID multihash.
    /// - Throws: a typed ``NodeError`` on any handshake / verification failure.
    public func dial(to endpoint: SocketEndpoint) async throws(NodeError) -> [UInt8] {
        if isClosed { throw .connectionClosed }
        let ids = try connectionIDPlan.dialConnectionIDs()
        let configuration = parameters.configuration(role: .client, connectionIDs: ids)
        let connection = try await transport.dial(
            configuration: configuration,
            peer: endpoint,
            identity: identity
        )
        let peerID = connection.remotePeerIDMultihash
        // A dial MUST yield a verified peer — the handshake driver returns the
        // RPK-verified PeerID. An empty PeerID here would mean an unverified peer;
        // refuse rather than track it (fail-closed).
        guard !peerID.isEmpty else {
            await connection.close()
            throw .quicHandshakePeerVerificationFailed
        }
        // Reuse-or-register: if a live connection already exists, keep it and tear
        // down the freshly-dialed duplicate; otherwise track the new one.
        if let existing = await connections.connection(to: peerID) {
            await connection.close()
            _ = existing
            return peerID
        }
        let displaced = await connections.register(connection, peerID: peerID)
        if let displaced {
            await displaced.close()
        }
        // Serve inbound streams on the dialed connection too: a libp2p node answers
        // protocol requests (Ping / Identify / app handlers) on EVERY connection,
        // not just the ones it accepted. Without this the peer we dialed could not
        // `identify` / `ping` us back over the same connection.
        startServing(connection)
        return peerID
    }

    // MARK: - newStream

    /// Opens a QUIC stream to the connected peer `peerID`, negotiates `protocolID`
    /// via multistream-select, and returns the ready stream.
    ///
    /// The peer MUST already be connected (via ``dial(to:)``) — `newStream` does not
    /// dial. The returned stream replays any negotiation residual, so the caller
    /// reads/writes it directly.
    ///
    /// - Throws: ``NodeError/connectionClosed`` if `peerID` is not connected,
    ///   ``NodeError/negotiationRejected`` if the peer declines `protocolID`, or the
    ///   negotiator's other ``NodeError`` cases (fail-closed).
    public func newStream(
        to peerID: [UInt8],
        protocol protocolID: String
    ) async throws(NodeError) -> Stream {
        if isClosed { throw .connectionClosed }
        guard let connection = await connections.connection(to: peerID) else {
            // Not connected — the minimal node does not implicitly dial here.
            throw .connectionClosed
        }
        let raw = try connection.openStream()
        return try await StreamNegotiation.dial(
            protocolID,
            on: raw,
            timer: timer,
            timeoutNanos: negotiationTimeoutNanos
        )
    }

    // MARK: - Built-in convenience: Ping + Identify

    /// Pings the connected peer `peerID` (`/ipfs/ping/1.0.0`) and returns the RTT.
    ///
    /// Opens a stream, negotiates ping, runs one 32-byte echo round-trip, and closes
    /// the stream. Fail-closed: a mismatched / truncated echo throws.
    ///
    /// - Returns: a ``PingResult`` whose `roundTripNanos > 0`.
    /// - Throws: a typed ``NodeError`` on negotiation / echo failure.
    public func ping(_ peerID: [UInt8]) async throws(NodeError) -> PingResult {
        let stream = try await newStream(to: peerID, protocol: NodeProtocolID.ping)
        let outcome: Result<PingResult, NodeError>
        do {
            let result = try await PingService<DefaultCryptoProvider, Timer>.ping(on: stream, timer: timer)
            outcome = .success(result)
        } catch {
            outcome = .failure(error)
        }
        await stream.close()
        switch outcome {
        case .success(let result):
            return result
        case .failure(let error):
            throw error
        }
    }

    /// Runs Identify (`/ipfs/id/1.0.0`) against the connected peer `peerID` and
    /// returns its advertised ``IdentifyFields``, FAIL-CLOSED bound to the
    /// handshake-verified PeerID (an Identify message can never re-assert a different
    /// identity than the handshake proved).
    ///
    /// - Throws: ``NodeError/connectionClosed`` if not connected,
    ///   ``NodeError/identifyMissingPublicKey`` / ``NodeError/identifyPeerIDMismatch``
    ///   on a missing / mismatched advertised key, or the negotiator's errors.
    public func identify(_ peerID: [UInt8]) async throws(NodeError) -> IdentifyFields {
        if isClosed { throw .connectionClosed }
        guard let connection = await connections.connection(to: peerID) else {
            throw .connectionClosed
        }
        let stream = try await newStream(to: peerID, protocol: NodeProtocolID.identify)
        // Bind to the connection's HANDSHAKE-verified PeerID, not the requested key.
        return try await IdentifyService<DefaultCryptoProvider>.identify(
            on: stream,
            verifiedPeerIDMultihash: connection.remotePeerIDMultihash
        )
    }

    // MARK: - Connected peers

    /// The verified PeerIDs of all currently-tracked live connections (dialed or
    /// mTLS-accepted). Every entry is a cryptographically-verified identity — an
    /// unverified peer is never tracked.
    public func connectedPeerIDs() async -> [[UInt8]] {
        await connections.connectedPeers()
    }

    // MARK: - Close

    /// Shuts the node down: cancels every serve task and gracefully closes every
    /// tracked connection. Idempotent.
    public func close() async {
        if isClosed { return }
        isClosed = true
        for task in serveTasks {
            task.cancel()
        }
        serveTasks.removeAll()
        let all = await connections.drainAll()
        for connection in all {
            await connection.close()
        }
    }

    // MARK: - Private helpers

    /// Embedded-clean membership test (avoids `Array.contains` overload ambiguity
    /// under Embedded with `String` elements).
    private static func contains(_ list: [String], _ value: String) -> Bool {
        for item in list where item == value {
            return true
        }
        return false
    }
}
