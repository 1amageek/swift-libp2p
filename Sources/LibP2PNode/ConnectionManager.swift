// ConnectionManager.swift
// The minimal connection manager: a `PeerID → QUICConnection` map keyed by the
// HANDSHAKE-VERIFIED peer PeerID multihash, plus the set of accepted inbound
// connections. It is NOT the full host `Swarm` — there is no reconnect/backoff, no
// resource manager, no per-peer connection pooling beyond "one live connection per
// peer". Those are deliberately OUT OF SCOPE for the minimal node (noted here, never
// silently dropped); the data path stays correct and fail-closed.
//
// RESPONSIBILITY (single): own the lifetime of the node's live QUIC connections —
// register a dialed/accepted connection under its verified PeerID, hand back an
// existing connection so a re-dial reuses it, and tear them all down on `close()`.
// It performs NO I/O inside the isolation other than the teardown `await`s in
// `closeAll()` (which the node calls during shutdown, off the hot path).
//
// Embedded-clean: an actor (no `Mutex` — `Synchronization.Mutex` is host-only in
// this stack; actors are Embedded-OK per the node design), `[UInt8]` PeerID keys,
// monomorphic over `<Transport, Timer>`, no `any`, typed throws.

import _Concurrency   // REQUIRED under Embedded for async/Task
import P2PCoreCrypto       // AsyncTimer
import P2PCoreTransport    // DatagramTransport

/// Owns the node's live, handshake-verified QUIC connections.
///
/// Keyed by the verified peer PeerID multihash (`[UInt8]`, which is `Hashable`).
/// A dial that finds an existing live connection to the same peer REUSES it rather
/// than opening a second one; inbound (accepted) connections are tracked the same
/// way once their peer is known (or in an anonymous list when the minimal server
/// path leaves the peer unauthenticated — see ``QUICTLSHandshakeDriver`` server
/// notes). `closeAll()` tears every tracked connection down.
public actor ConnectionManager<
    Transport: DatagramTransport,
    Timer: AsyncTimer
> {

    /// Connections whose peer PeerID is known (dialed, or accepted-with-mTLS).
    private var byPeer: [[UInt8]: QUICConnection<Transport, Timer>]

    /// Accepted connections whose peer is unauthenticated on the minimal server
    /// path (no mTLS this slice). Tracked so `closeAll()` still tears them down —
    /// never leaked.
    private var anonymousInbound: [QUICConnection<Transport, Timer>]

    public init() {
        self.byPeer = [:]
        self.anonymousInbound = []
    }

    // MARK: - Lookup

    /// Returns the live connection to `peerID`, or `nil` if none is tracked or the
    /// tracked one has since closed (a closed entry is evicted, never returned —
    /// fail-closed against handing back a dead connection).
    public func connection(to peerID: [UInt8]) -> QUICConnection<Transport, Timer>? {
        guard let existing = byPeer[peerID] else { return nil }
        if existing.isClosed {
            byPeer[peerID] = nil
            return nil
        }
        return existing
    }

    /// Whether a live connection to `peerID` is currently tracked.
    public func isConnected(to peerID: [UInt8]) -> Bool {
        connection(to: peerID) != nil
    }

    /// The verified PeerIDs of all currently-tracked live connections.
    public func connectedPeers() -> [[UInt8]] {
        var peers = [[UInt8]]()
        peers.reserveCapacity(byPeer.count)
        for (peerID, connection) in byPeer where !connection.isClosed {
            peers.append(peerID)
        }
        return peers
    }

    // MARK: - Registration

    /// Registers a connection under its verified `peerID`.
    ///
    /// If a different live connection to the same peer already exists it is REPLACED
    /// (the caller — `dial` — only registers after deciding to open a new one); the
    /// previous connection is returned so the caller can tear it down off-isolation
    /// (no I/O under the actor's lock other than shutdown). An empty `peerID`
    /// (unauthenticated inbound) is tracked anonymously instead.
    ///
    /// - Returns: the displaced connection to close, or `nil` if none.
    @discardableResult
    public func register(
        _ connection: QUICConnection<Transport, Timer>,
        peerID: [UInt8]
    ) -> QUICConnection<Transport, Timer>? {
        guard !peerID.isEmpty else {
            anonymousInbound.append(connection)
            return nil
        }
        let displaced = byPeer[peerID]
        byPeer[peerID] = connection
        return displaced
    }

    /// Removes the tracked connection for `peerID` (if any) and returns it for
    /// off-isolation teardown.
    @discardableResult
    public func remove(peerID: [UInt8]) -> QUICConnection<Transport, Timer>? {
        guard !peerID.isEmpty else { return nil }
        let removed = byPeer[peerID]
        byPeer[peerID] = nil
        return removed
    }

    // MARK: - Teardown

    /// Drains all tracked connections out of the manager and returns them so the
    /// caller closes them. The manager is empty afterwards.
    ///
    /// Returning the list (rather than closing inside the isolation) keeps the
    /// graceful-close `await`s — which do connection I/O — off the actor's critical
    /// section pattern, and lets the node close them concurrently.
    public func drainAll() -> [QUICConnection<Transport, Timer>] {
        var all = [QUICConnection<Transport, Timer>]()
        all.reserveCapacity(byPeer.count + anonymousInbound.count)
        for (_, connection) in byPeer {
            all.append(connection)
        }
        for connection in anonymousInbound {
            all.append(connection)
        }
        byPeer.removeAll()
        anonymousInbound.removeAll()
        return all
    }
}
