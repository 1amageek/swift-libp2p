/// WebRTC Secured Listener
///
/// Implements SecuredListener for WebRTC Direct, yielding
/// pre-secured, pre-multiplexed connections.
///
/// Owns the accept pipeline for the shared UDP socket:
/// new source addresses arrive via `handleNewPeer(_:)`, which accepts a
/// raw WebRTC connection and registers its route. `startAccepting()`
/// drives the DTLS + SCTP handshake for each accepted connection in
/// parallel and yields verified connections as MuxedConnections.
///
/// Every accepted connection is tracked in a peer registry so that
/// failure paths (handshake timeout, certificate rejection, capacity
/// limit, muxed-connection close) tear down all three bookkeeping
/// sites together: the socket route, the listener's connection table,
/// and the registry itself.

import Foundation
import Synchronization
import Logging
import NIOCore
import P2PCore
import P2PTransport
import P2PMux
import P2PCertificate
import WebRTC

/// A listener that yields pre-secured WebRTC connections.
public final class WebRTCSecuredListener: SecuredListener, Sendable {

    /// Cap on connections concurrently performing the DTLS + SCTP
    /// handshake. Excess connections are rejected explicitly instead of
    /// queueing without bound.
    private static let maxConcurrentHandshakes = 64

    private let listener: WebRTCListener
    private let socket: WebRTCUDPSocket
    private let _localAddress: Multiaddr
    private let localKeyPair: KeyPair
    private let logger: Logger
    private let listenerState: Mutex<ListenerState>

    /// Bookkeeping for one accepted raw connection.
    private struct PeerEntry: Sendable {
        let key: String
        let address: SocketAddress
    }

    private struct ListenerState: Sendable {
        /// Created eagerly at init so connections yielded before the
        /// first subscription are buffered rather than dropped.
        var connectionsStream: AsyncStream<any MuxedConnection>
        var connectionsContinuation: AsyncStream<any MuxedConnection>.Continuation?
        /// Accepted raw connections by identity, with the route key and
        /// source address registered at accept time.
        var peers: [ObjectIdentifier: PeerEntry] = [:]
        /// Connections discarded before `handleNewPeer` registered them.
        /// The accept loop can reject a connection while `handleNewPeer`
        /// is still between `acceptConnection` and registration; the
        /// tombstone tells it to abandon the registration. Always
        /// consumed by the in-flight `handleNewPeer` call.
        var discardedWithoutEntry: Set<ObjectIdentifier> = []
        var handshakeCount: Int = 0
        var didStartAccepting: Bool = false
        var isClosed: Bool = false
    }

    public var localAddress: Multiaddr { _localAddress }

    /// Stream of incoming secured, multiplexed connections.
    public var connections: AsyncStream<any MuxedConnection> {
        listenerState.withLock { $0.connectionsStream }
    }

    init(
        listener: WebRTCListener,
        socket: WebRTCUDPSocket,
        localAddress: Multiaddr,
        localKeyPair: KeyPair
    ) {
        self.listener = listener
        self.socket = socket
        self._localAddress = localAddress
        self.localKeyPair = localKeyPair
        self.logger = Logger(label: "swift-libp2p.WebRTCSecuredListener")
        let (stream, continuation) = AsyncStream<any MuxedConnection>.makeStream()
        self.listenerState = Mutex(ListenerState(
            connectionsStream: stream,
            connectionsContinuation: continuation
        ))
    }

    // MARK: - Accept pipeline

    /// Handles a datagram from an unknown source address: accepts a new
    /// raw WebRTC connection, registers it in the peer registry, and
    /// adds the socket route so this and subsequent datagrams reach it.
    ///
    /// Called by the shared UDP socket's onNewPeer callback.
    func handleNewPeer(_ remoteAddress: SocketAddress) {
        let key = remoteAddress.addressKey
        let sendHandler = socket.makeSendHandler(remoteAddress: remoteAddress)
        guard let connection = listener.acceptConnection(peerID: key, sendHandler: sendHandler) else {
            // The underlying listener is closed — nothing to route
            return
        }

        enum Admission {
            case admitted
            case discardedEarly
            case closed
        }

        let admission = listenerState.withLock { state -> Admission in
            // The accept loop may have rejected this connection already —
            // its discard() could not clean the upstream entry because the
            // route key was not registered yet
            if state.discardedWithoutEntry.remove(ObjectIdentifier(connection)) != nil {
                return .discardedEarly
            }
            guard !state.isClosed else { return .closed }
            state.peers[ObjectIdentifier(connection)] = PeerEntry(key: key, address: remoteAddress)
            return .admitted
        }

        switch admission {
        case .admitted:
            if !socket.addRoute(remoteAddress: remoteAddress, connection: connection) {
                logger.warning("Socket closed while admitting peer \(key); discarding connection")
                discard(connection)
            }
        case .discardedEarly:
            // Finish the cleanup discard() could not do: drop the
            // upstream listener entry (also closes the connection)
            listener.removeConnection(peerID: key)
        case .closed:
            // close() is tearing the listener down; listener.close()
            // runs after this acceptConnection and removes the upstream
            // entry. Close the connection eagerly.
            connection.close()
        }
    }

    /// Start accepting connections and forwarding them as MuxedConnections.
    ///
    /// Each accepted connection performs its DTLS + SCTP handshake in
    /// its own task (up to `maxConcurrentHandshakes` in parallel), so a
    /// slow or stalled peer cannot block other peers from connecting.
    ///
    /// Connections that fail the handshake or certificate extraction
    /// are discarded with a warning — route, listener entry, and
    /// registry entry are all removed.
    public func startAccepting() {
        let alreadyStarted = listenerState.withLock { state -> Bool in
            if state.didStartAccepting { return true }
            state.didStartAccepting = true
            return false
        }
        guard !alreadyStarted else { return }

        Task { [weak self] in
            guard let self else { return }
            for await webrtcConn in self.listener.connections {
                let admitted = self.listenerState.withLock { state -> Bool in
                    guard !state.isClosed,
                          state.handshakeCount < Self.maxConcurrentHandshakes else {
                        return false
                    }
                    state.handshakeCount += 1
                    return true
                }
                guard admitted else {
                    self.logger.warning(
                        "Rejecting inbound WebRTC connection: listener closed or handshake capacity (\(Self.maxConcurrentHandshakes)) reached"
                    )
                    self.discard(webrtcConn)
                    continue
                }
                Task { [weak self] in
                    guard let self else { return }
                    defer {
                        self.listenerState.withLock { $0.handshakeCount -= 1 }
                    }
                    await self.handleAccepted(webrtcConn)
                }
            }
        }
    }

    /// Drive one accepted connection through handshake, verification,
    /// and muxed-connection construction.
    private func handleAccepted(_ webrtcConn: WebRTCConnection) async {
        // Wait for DTLS + SCTP handshake to complete
        do {
            try await webrtcConn.waitForConnected()
        } catch {
            logger.warning("Inbound WebRTC handshake failed: \(error)")
            discard(webrtcConn)
            return
        }

        // Extract PeerID from certificate (guaranteed available after handshake)
        let remotePeerID: PeerID
        do {
            guard let certDER = webrtcConn.remoteCertificateDER else {
                logger.warning("Inbound WebRTC connection has no remote certificate after handshake")
                discard(webrtcConn)
                return
            }
            remotePeerID = try LibP2PCertificate.extractPeerID(from: certDER)
        } catch {
            logger.warning("Rejecting inbound WebRTC connection: certificate PeerID extraction failed: \(error)")
            discard(webrtcConn)
            return
        }

        // Build the remote address from the source address registered at
        // accept time. The peer's certhash is unknown on the inbound
        // side, so the address carries no certhash component.
        let entry = listenerState.withLock { $0.peers[ObjectIdentifier(webrtcConn)] }
        guard let entry, let remoteAddress = entry.address.toWebRTCDirectMultiaddr() else {
            logger.warning("Inbound WebRTC connection has no registered source address; discarding")
            discard(webrtcConn)
            return
        }

        let muxed = WebRTCMuxedConnection(
            webrtcConnection: webrtcConn,
            localPeer: localKeyPair.peerID,
            remotePeer: remotePeerID,
            localAddress: _localAddress,
            remoteAddress: remoteAddress,
            udpSocket: nil,
            onClose: { [weak self] in
                self?.discard(webrtcConn)
            }
        )
        muxed.startForwarding()

        let continuation = listenerState.withLock { state -> AsyncStream<any MuxedConnection>.Continuation? in
            state.isClosed ? nil : state.connectionsContinuation
        }
        guard let continuation, case .enqueued = continuation.yield(muxed) else {
            // Listener closed during the handshake — tear the connection
            // back down instead of leaking it
            logger.info("Listener closed during inbound handshake; discarding connection")
            do {
                try await muxed.close()
            } catch {
                logger.warning("Failed to close orphaned muxed connection: \(error)")
            }
            return
        }
    }

    /// Drop all bookkeeping for a connection and close it: the socket
    /// route, the listener's connection table entry, and the peer
    /// registry entry.
    private func discard(_ connection: WebRTCConnection) {
        let entry = listenerState.withLock { state -> PeerEntry? in
            if let entry = state.peers.removeValue(forKey: ObjectIdentifier(connection)) {
                return entry
            }
            // Not registered yet: handleNewPeer is still between
            // acceptConnection and registration — leave a tombstone so it
            // abandons the registration and cleans the upstream entry
            if !state.isClosed {
                state.discardedWithoutEntry.insert(ObjectIdentifier(connection))
            }
            return nil
        }
        socket.removeRoute(for: connection)
        if let entry {
            // The address key may already be owned by a newer connection
            // accepted after this one's route was removed — only drop the
            // upstream entry when it still maps to this connection
            if listener.connection(for: entry.key) === connection {
                // removeConnection also closes the connection
                listener.removeConnection(peerID: entry.key)
            } else {
                connection.close()
            }
        } else {
            connection.close()
        }
    }

    // MARK: - Lifecycle

    /// Closes the listener, its UDP socket, and all raw connections. Idempotent.
    public func close() async throws {
        let continuation = listenerState.withLock { state -> AsyncStream<any MuxedConnection>.Continuation? in
            guard !state.isClosed else { return nil }
            state.isClosed = true
            state.peers.removeAll()
            state.discardedWithoutEntry.removeAll()
            let continuation = state.connectionsContinuation
            state.connectionsContinuation = nil
            return continuation
        }
        guard let continuation else { return }
        continuation.finish()
        socket.close()
        listener.close()
    }
}
