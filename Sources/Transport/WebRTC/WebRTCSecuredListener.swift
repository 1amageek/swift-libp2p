/// WebRTC Secured Listener
///
/// Implements SecuredListener for WebRTC Direct, yielding
/// pre-secured, pre-multiplexed connections.
///
/// Remote peer ID is initially unknown. It is updated after the DTLS
/// handshake provides the remote certificate. Remote address is derived
/// from the peer's connection identifier.

import Foundation
import Synchronization
import P2PCore
import P2PTransport
import P2PMux
import P2PCertificate
import WebRTC
import DTLSCore

/// A listener that yields pre-secured WebRTC connections.
public final class WebRTCSecuredListener: SecuredListener, Sendable {

    private let listener: WebRTCListener
    private let socket: WebRTCUDPSocket
    private let _localAddress: Multiaddr
    private let localKeyPair: KeyPair
    private let listenerState: Mutex<ListenerState>

    private struct ListenerState: Sendable {
        var connectionsStream: AsyncStream<any MuxedConnection>?
        var connectionsContinuation: AsyncStream<any MuxedConnection>.Continuation?
        var isClosed: Bool = false
    }

    public var localAddress: Multiaddr { _localAddress }

    /// Stream of incoming secured, multiplexed connections.
    public var connections: AsyncStream<any MuxedConnection> {
        listenerState.withLock { state in
            if let existing = state.connectionsStream { return existing }
            let (stream, continuation) = AsyncStream<any MuxedConnection>.makeStream()
            state.connectionsStream = stream
            state.connectionsContinuation = continuation
            return stream
        }
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
        self.listenerState = Mutex(ListenerState())
    }

    /// Start accepting connections and forwarding them as MuxedConnections.
    ///
    /// When a connection arrives, the remote PeerID is initially set to a
    /// placeholder. If the DTLS handshake has already completed (the remote
    /// certificate is available), the PeerID is extracted immediately.
    /// Otherwise, the integration layer should call
    /// `WebRTCMuxedConnection.tryExtractRemotePeerID()` once the handshake
    /// finishes.
    public func startAccepting() {
        Task { [weak self] in
            guard let self else { return }
            for await webrtcConn in listener.connections {
                let muxed = WebRTCMuxedConnection(
                    webrtcConnection: webrtcConn,
                    localPeer: localKeyPair.peerID,
                    remotePeer: localKeyPair.peerID,
                    localAddress: _localAddress,
                    remoteAddress: _localAddress,
                    udpSocket: nil,
                    onClose: { [weak self] in
                        // Clean up route table entry when connection closes
                        self?.socket.removeRoute(for: webrtcConn)
                    }
                )
                muxed.startForwarding()

                // Best-effort PeerID extraction if DTLS handshake is already complete
                do {
                    _ = try muxed.tryExtractRemotePeerID()
                } catch {
                    // Certificate not yet available or missing libp2p extension.
                    // PeerID will be resolved later via tryExtractRemotePeerID().
                }

                let continuation = listenerState.withLock { $0.connectionsContinuation }
                continuation?.yield(muxed)
            }
        }
    }

    /// Closes the listener and its UDP socket.
    public func close() async throws {
        listenerState.withLock { state in
            state.isClosed = true
            state.connectionsContinuation?.finish()
            state.connectionsContinuation = nil
            state.connectionsStream = nil
        }
        socket.close()
        listener.close()
    }
}
