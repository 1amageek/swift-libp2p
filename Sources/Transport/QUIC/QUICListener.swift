/// QUIC Listener implementations for libp2p.

import Foundation
import Synchronization
import P2PCore
import P2PTransport
import P2PMux
import QUIC
import QUICCrypto

// MARK: - QUIC Listener (Standard)

/// A QUIC listener conforming to the standard Listener protocol.
///
/// This listener is provided for compatibility with the standard Transport
/// protocol, but returns unsecured connections which is not typical for QUIC.
///
/// For QUIC connections, prefer using `QUICSecuredListener` which returns
/// `QUICMuxedConnection` directly.
public final class QUICListener: Listener, @unchecked Sendable {

    private let endpoint: QUICEndpoint
    private let _localAddress: Multiaddr
    private let state: Mutex<ListenerState>

    private struct ListenerState: Sendable {
        var isClosed: Bool = false
    }

    /// The local address this listener is bound to.
    public var localAddress: Multiaddr { _localAddress }

    /// Creates a new QUIC listener.
    ///
    /// - Parameters:
    ///   - endpoint: The underlying QUIC endpoint
    ///   - localAddress: The local multiaddr
    init(endpoint: QUICEndpoint, localAddress: Multiaddr) {
        self.endpoint = endpoint
        self._localAddress = localAddress
        self.state = Mutex(ListenerState())
    }

    /// Accepts the next incoming connection.
    ///
    /// - Note: QUIC connections don't fit the RawConnection model well.
    ///   This method throws `TransportError.listenerClosed` to indicate
    ///   that callers should use `QUICSecuredListener` instead.
    ///
    /// - Returns: Never returns a connection
    /// - Throws: `TransportError.listenerClosed`
    public func accept() async throws -> any RawConnection {
        // QUIC connections are already secured and multiplexed.
        // The standard accept() -> RawConnection model doesn't apply.
        throw TransportError.listenerClosed
    }

    /// Closes the listener.
    public func close() async throws {
        state.withLock { $0.isClosed = true }
        // Note: QUICEndpoint doesn't have a close method in the current API
        // This would need to be added for proper cleanup
    }
}

// MARK: - QUIC Secured Listener

/// A QUIC listener that yields secured, multiplexed connections directly.
///
/// This is the preferred listener for QUIC because it returns
/// `QUICMuxedConnection` objects that are already authenticated
/// and ready for protocol negotiation.
///
/// ## Usage
///
/// ```swift
/// let listener = try await transport.listenSecured(address, localKeyPair: keyPair)
///
/// for await connection in listener.connections {
///     Task {
///         for await stream in connection.inboundStreams {
///             // Handle stream
///         }
///     }
/// }
/// ```
public final class QUICSecuredListener: SecuredListener, Sendable {

    private let endpoint: QUICEndpoint
    private let _localAddress: Multiaddr
    private let localKeyPair: KeyPair

    private let state: Mutex<SecuredListenerState>

    private struct SecuredListenerState: Sendable {
        var isClosed: Bool = false
        var connectionsContinuation: AsyncStream<any MuxedConnection>.Continuation?
        var forwardingTask: Task<Void, Never>?
    }

    /// Stream of incoming secured connections.
    /// This stream is created once and should be consumed by a single consumer.
    public let connections: AsyncStream<any MuxedConnection>

    /// The local address this listener is bound to.
    public var localAddress: Multiaddr { _localAddress }

    /// The local peer ID.
    public var localPeer: PeerID {
        localKeyPair.peerID
    }

    /// Creates a new secured QUIC listener.
    ///
    /// - Parameters:
    ///   - endpoint: The underlying QUIC endpoint
    ///   - localAddress: The local multiaddr
    ///   - localKeyPair: The local key pair for identity
    init(endpoint: QUICEndpoint, localAddress: Multiaddr, localKeyPair: KeyPair) {
        self.endpoint = endpoint
        self._localAddress = localAddress
        self.localKeyPair = localKeyPair

        // Create AsyncStream once in init
        let (stream, continuation) = AsyncStream<any MuxedConnection>.makeStream()
        self.connections = stream

        var initialState = SecuredListenerState()
        initialState.connectionsContinuation = continuation
        self.state = Mutex(initialState)
    }

    /// Starts accepting incoming connections.
    ///
    /// This method must be called after initialization to begin
    /// yielding connections to the `connections` AsyncStream.
    public func startAccepting() {
        let task = Task { [weak self] in
            guard let self = self else { return }

            for await quicConnection in await self.endpoint.incomingConnections {
                // Check if closed
                let isClosed = self.state.withLock { $0.isClosed }
                if isClosed { break }

                // Wait for handshake to complete before extracting PeerID
                var timeoutCount = 0
                while !quicConnection.isEstablished {
                    timeoutCount += 1
                    if timeoutCount > 3000 {  // 30 seconds (10ms * 3000)
                        #if DEBUG
                        print("Rejecting connection: handshake timeout")
                        #endif
                        try? await quicConnection.close(error: 0x100)
                        continue
                    }
                    try? await Task.sleep(for: .milliseconds(10))
                }

                // Extract remote PeerID from TLS certificate
                let remotePeer: PeerID
                do {
                    remotePeer = try self.extractPeerID(from: quicConnection)
                } catch {
                    #if DEBUG
                    print("Rejecting connection: failed to extract PeerID - \(error)")
                    #endif
                    try? await quicConnection.close(error: 0x100)
                    continue
                }

                // Build remote address
                let remoteAddress = quicConnection.remoteAddress.toQUICMultiaddr()

                // Build local address if available
                let localAddr: Multiaddr?
                if let local = quicConnection.localAddress {
                    localAddr = local.toQUICMultiaddr()
                } else {
                    localAddr = self._localAddress
                }

                let muxedConnection = QUICMuxedConnection(
                    quicConnection: quicConnection,
                    localPeer: self.localKeyPair.peerID,
                    remotePeer: remotePeer,
                    localAddress: localAddr,
                    remoteAddress: remoteAddress
                )

                // Start forwarding incoming streams for this connection
                muxedConnection.startForwarding()

                let shouldYield = self.state.withLock { s -> Bool in
                    guard !s.isClosed else { return false }
                    s.connectionsContinuation?.yield(muxedConnection)
                    return true
                }
                if !shouldYield { break }
            }

            self.state.withLock { s in
                s.connectionsContinuation?.finish()
                s.connectionsContinuation = nil
            }
        }

        state.withLock { $0.forwardingTask = task }
    }

    /// Accepts the next incoming secured connection.
    ///
    /// - Returns: The next incoming connection
    /// - Throws: Error if accept fails or listener is closed
    public func acceptSecured() async throws -> any MuxedConnection {
        let isClosed = state.withLock { $0.isClosed }
        guard !isClosed else {
            throw TransportError.listenerClosed
        }

        for await connection in connections {
            return connection
        }

        throw TransportError.listenerClosed
    }

    /// Closes the listener.
    public func close() async throws {
        let task = state.withLock { s -> Task<Void, Never>? in
            s.isClosed = true
            s.connectionsContinuation?.finish()
            s.connectionsContinuation = nil
            let t = s.forwardingTask
            s.forwardingTask = nil
            return t
        }

        task?.cancel()
    }

    // MARK: - Private Helpers

    /// Extracts PeerID from a QUIC connection using the TLS provider.
    ///
    /// The PeerID is extracted from the X.509 certificate extension
    /// (OID 1.3.6.1.4.1.53594.1.1) that was verified during the TLS handshake.
    ///
    /// - Parameter connection: The QUIC connection
    /// - Returns: The remote peer's PeerID
    /// - Throws: `QUICTransportError.certificateInvalid` if PeerID extraction fails
    private func extractPeerID(from connection: any QUICConnectionProtocol) throws -> PeerID {
        // Try to get the TLS provider from the connection
        if let managedConnection = connection as? ManagedConnection {
            let tlsProvider = managedConnection.underlyingTLSProvider

            // Extract PeerID from SwiftQUIC TLS provider
            if let swiftQUICProvider = tlsProvider as? SwiftQUICTLSProvider {
                if let remotePeerID = swiftQUICProvider.remotePeerID {
                    return remotePeerID
                }
            }
        }

        // No fallback - this is a security requirement.
        // Connections without valid PeerID must be rejected.
        throw QUICTransportError.certificateInvalid(
            "Failed to extract PeerID from TLS certificate"
        )
    }
}
