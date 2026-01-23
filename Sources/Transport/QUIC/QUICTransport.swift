/// QUIC Transport implementation for libp2p.

import Foundation
import P2PCore
import P2PTransport
import P2PMux
import QUIC
import QUICCrypto
import NIOUDPTransport

// MARK: - QUIC Transport

/// A libp2p transport using QUIC.
///
/// QUIC provides built-in:
/// - TLS 1.3 encryption (security)
/// - Stream multiplexing (muxer)
/// - Congestion control
/// - 0-RTT connection establishment
///
/// Unlike TCP, QUIC connections bypass the standard libp2p upgrade pipeline
/// because security and multiplexing are native to the protocol.
///
/// ## Usage
///
/// ```swift
/// let transport = QUICTransport()
///
/// // Dial a QUIC address
/// let connection = try await transport.dialSecured(
///     address,
///     localKeyPair: keyPair
/// )
///
/// // Open streams
/// let stream = try await connection.newStream()
/// ```
public final class QUICTransport: SecuredTransport, Sendable {

    /// QUIC configuration
    private let configuration: QUICConfiguration

    /// Supported protocol chains.
    ///
    /// QUIC uses UDP as the underlying transport:
    /// - `/ip4/<ip>/udp/<port>/quic-v1`
    /// - `/ip6/<ip>/udp/<port>/quic-v1`
    public var protocols: [[String]] {
        [["ip4", "udp", "quic-v1"], ["ip6", "udp", "quic-v1"]]
    }

    /// Creates a new QUIC transport.
    ///
    /// - Parameter configuration: QUIC configuration (defaults to libp2p preset)
    public init(configuration: QUICConfiguration = .libp2p()) {
        self.configuration = configuration
    }

    // MARK: - Transport Protocol

    /// Dials a QUIC address.
    ///
    /// - Note: This method returns a `RawConnection` for compatibility with the
    ///   standard Transport protocol, but QUIC connections are already secured.
    ///   Prefer using `dialSecured(_:localKeyPair:)` to get a `QUICMuxedConnection`.
    ///
    /// - Parameter address: The multiaddr to dial
    /// - Returns: A raw connection wrapper
    /// - Throws: `TransportError.unsupportedAddress` if the address is not QUIC
    public func dial(_ address: Multiaddr) async throws -> any RawConnection {
        // QUIC connections don't fit the RawConnection model well because
        // they are already secured and multiplexed.
        // This implementation wraps stream 0 as a RawConnection for compatibility.
        throw TransportError.unsupportedAddress(address)
    }

    /// Listens for incoming QUIC connections.
    ///
    /// - Parameter address: The multiaddr to listen on
    /// - Returns: A listener for incoming connections
    /// - Throws: `TransportError.unsupportedAddress` if the address is not QUIC
    public func listen(_ address: Multiaddr) async throws -> any Listener {
        guard let socketAddress = address.toQUICSocketAddress() else {
            throw TransportError.unsupportedAddress(address)
        }

        let endpoint = try await QUICEndpoint.listen(
            address: socketAddress,
            configuration: configuration
        )

        return QUICListener(endpoint: endpoint, localAddress: address)
    }

    /// Whether this transport can dial the given address.
    ///
    /// - Parameter address: The address to check
    /// - Returns: `true` if this is a valid QUIC address
    public func canDial(_ address: Multiaddr) -> Bool {
        address.toQUICSocketAddress() != nil
    }

    /// Whether this transport can listen on the given address.
    ///
    /// - Parameter address: The address to check
    /// - Returns: `true` if this is a valid QUIC address
    public func canListen(_ address: Multiaddr) -> Bool {
        canDial(address)
    }

    // MARK: - QUIC-Specific API

    /// Dials a QUIC address and returns a secured, multiplexed connection.
    ///
    /// This is the preferred method for QUIC connections as it bypasses the
    /// standard libp2p upgrade pipeline (which is not needed for QUIC).
    ///
    /// - Parameters:
    ///   - address: The multiaddr to dial (must be a QUIC address)
    ///   - localKeyPair: The local key pair for identity
    /// - Returns: A secured, multiplexed connection
    /// - Throws: `TransportError.unsupportedAddress` if not a valid QUIC address
    public func dialSecured(
        _ address: Multiaddr,
        localKeyPair: KeyPair
    ) async throws -> any MuxedConnection {
        guard let socketAddress = address.toQUICSocketAddress() else {
            throw TransportError.unsupportedAddress(address)
        }

        // Create configuration with libp2p TLS provider factory
        var config = configuration
        config.tlsProviderFactory = { [localKeyPair] isClient in
            do {
                // Use swift-quic's pure Swift TLS 1.3 implementation
                return try SwiftQUICTLSProvider(localKeyPair: localKeyPair)
            } catch {
                // Return a failing provider instead of crashing
                // The error will be reported during handshake
                return FailingTLSProvider(error: error)
            }
        }

        // Create client endpoint with libp2p TLS
        let endpoint = QUICEndpoint(configuration: config)

        // Dial server and wait for handshake completion
        let quicConnection = try await endpoint.dial(address: socketAddress)

        // Extract PeerID from TLS certificate
        let remotePeer = try extractPeerID(from: quicConnection)

        // Create local address from socket if available
        let localAddress: Multiaddr?
        if let local = quicConnection.localAddress {
            localAddress = local.toQUICMultiaddr()
        } else {
            localAddress = nil
        }

        let connection = QUICMuxedConnection(
            quicConnection: quicConnection,
            localPeer: localKeyPair.peerID,
            remotePeer: remotePeer,
            localAddress: localAddress,
            remoteAddress: address
        )

        // Start forwarding incoming streams
        connection.startForwarding()

        return connection
    }

    /// Listens and returns a QUIC-specific listener.
    ///
    /// - Parameters:
    ///   - address: The multiaddr to listen on
    ///   - localKeyPair: The local key pair for identity
    /// - Returns: A QUIC listener that yields secured connections
    public func listenSecured(
        _ address: Multiaddr,
        localKeyPair: KeyPair
    ) async throws -> any SecuredListener {
        guard let socketAddress = address.toQUICSocketAddress() else {
            throw TransportError.unsupportedAddress(address)
        }

        // Create configuration with libp2p TLS provider factory
        var config = configuration
        config.tlsProviderFactory = { [localKeyPair] isClient in
            do {
                // Use swift-quic's pure Swift TLS 1.3 implementation
                return try SwiftQUICTLSProvider(localKeyPair: localKeyPair)
            } catch {
                // Return a failing provider instead of crashing
                // The error will be reported during handshake
                return FailingTLSProvider(error: error)
            }
        }

        // Create server socket bound to the specific address (will be started by serve())
        let udpConfig = UDPConfiguration(
            bindAddress: .specific(host: socketAddress.ipAddress, port: Int(socketAddress.port)),
            reuseAddress: true
        )
        let socket = NIOQUICSocket(configuration: udpConfig)

        // Create server endpoint - this starts the socket and runs the I/O loop
        let (endpoint, _) = try await QUICEndpoint.serve(
            socket: socket,
            configuration: config
        )

        // Get actual bound address (important when port 0 was used)
        let actualAddress: Multiaddr
        if let localAddr = await endpoint.localAddress {
            actualAddress = localAddr.toQUICMultiaddr()
        } else {
            actualAddress = address
        }

        let listener = QUICSecuredListener(
            endpoint: endpoint,
            localAddress: actualAddress,
            localKeyPair: localKeyPair
        )

        // Start accepting incoming connections
        listener.startAccepting()

        return listener
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
        guard let managedConnection = connection as? ManagedConnection else {
            throw QUICTransportError.certificateInvalid("Unexpected connection type")
        }

        guard let swiftQUICProvider = managedConnection.underlyingTLSProvider as? SwiftQUICTLSProvider else {
            throw QUICTransportError.certificateInvalid("Unexpected TLS provider type")
        }

        guard let remotePeerID = swiftQUICProvider.remotePeerID else {
            throw QUICTransportError.certificateInvalid("Remote PeerID not available after handshake")
        }

        return remotePeerID
    }
}

// MARK: - QUIC Errors

/// Errors specific to QUIC transport operations.
public enum QUICTransportError: Error, Sendable {
    /// The address is not a valid QUIC address.
    case invalidAddress(Multiaddr)

    /// TLS handshake failed.
    case tlsHandshakeFailed(underlying: Error)

    /// Certificate verification failed.
    case certificateInvalid(String)

    /// PeerID mismatch between expected and actual.
    case peerIDMismatch(expected: PeerID, actual: PeerID)

    /// Connection was closed.
    case connectionClosed

    /// Stream error.
    case streamError(streamID: UInt64, code: UInt64)

    /// TLS handshake timed out.
    case handshakeTimeout
}
