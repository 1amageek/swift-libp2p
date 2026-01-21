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
    }

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
        self.state = Mutex(SecuredListenerState())
    }

    /// Stream of incoming secured connections.
    ///
    /// Each connection is already authenticated and ready for use.
    /// Connections that fail PeerID extraction are rejected and closed.
    public var connections: AsyncStream<any MuxedConnection> {
        AsyncStream { continuation in
            state.withLock { $0.connectionsContinuation = continuation }

            Task { [weak self] in
                guard let self = self else {
                    continuation.finish()
                    return
                }

                for await quicConnection in await self.endpoint.incomingConnections {
                    // Wait for handshake to complete before extracting PeerID
                    // The connection is yielded before handshake is done
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
                    // Reject connections that fail PeerID extraction (security requirement)
                    let remotePeer: PeerID
                    do {
                        remotePeer = try self.extractPeerID(from: quicConnection)
                    } catch {
                        #if DEBUG
                        print("Rejecting connection: failed to extract PeerID - \(error)")
                        #endif
                        // Close the connection with an application error code
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

                    continuation.yield(muxedConnection)
                }

                continuation.finish()
                self.state.withLock { $0.connectionsContinuation = nil }
            }
        }
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
        state.withLock { s in
            s.isClosed = true
            s.connectionsContinuation?.finish()
            s.connectionsContinuation = nil
        }
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
