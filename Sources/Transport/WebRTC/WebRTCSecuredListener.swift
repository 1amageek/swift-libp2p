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
import WebRTC
import DTLSCore

/// A listener that yields pre-secured WebRTC connections.
public final class WebRTCSecuredListener: SecuredListener, Sendable {

    private let listener: WebRTCListener
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
        localAddress: Multiaddr,
        localKeyPair: KeyPair
    ) {
        self.listener = listener
        self._localAddress = localAddress
        self.localKeyPair = localKeyPair
        self.listenerState = Mutex(ListenerState())
    }

    /// Start accepting connections and forwarding them as MuxedConnections.
    public func startAccepting() {
        Task { [weak self] in
            guard let self else { return }
            for await webrtcConn in listener.connections {
                // Remote peer is unknown until DTLS handshake completes.
                // Use localPeer as placeholder; updated via updateRemotePeer() after handshake.
                //
                // Remote address is the peer's source address, which will be
                // provided by the transport layer. Use localAddress as initial value.
                let muxed = WebRTCMuxedConnection(
                    webrtcConnection: webrtcConn,
                    localPeer: localKeyPair.peerID,
                    remotePeer: localKeyPair.peerID, // TODO: derive from remote DTLS certificate
                    localAddress: _localAddress,
                    remoteAddress: _localAddress // TODO: use actual remote address from transport
                )
                muxed.startForwarding()

                let continuation = listenerState.withLock { $0.connectionsContinuation }
                continuation?.yield(muxed)
            }
        }
    }

    /// Closes the listener.
    public func close() async throws {
        listenerState.withLock { state in
            state.isClosed = true
            state.connectionsContinuation?.finish()
            state.connectionsContinuation = nil
            state.connectionsStream = nil
        }
        listener.close()
    }
}
