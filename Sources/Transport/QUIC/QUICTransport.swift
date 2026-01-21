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

    /// TLS provider mode for QUIC connections.
    public enum TLSProviderMode: Sendable {
        /// Use swift-quic's pure Swift TLS 1.3 implementation.
        /// This is the only mode - provides real TLS 1.3 without external dependencies.
        /// Compatible with rust-libp2p and go-libp2p.
        case swiftQUIC
    }

    /// QUIC configuration
    private let configuration: QUICConfiguration

    /// TLS provider mode
    private let tlsProviderMode: TLSProviderMode

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
    /// - Parameters:
    ///   - configuration: QUIC configuration (defaults to libp2p preset)
    ///   - tlsProviderMode: TLS provider mode (defaults to swiftQUIC for pure Swift TLS)
    public init(
        configuration: QUICConfiguration = .libp2p(),
        tlsProviderMode: TLSProviderMode = .swiftQUIC
    ) {
        self.configuration = configuration
        self.tlsProviderMode = tlsProviderMode
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
        let remotePeer = try extractPeerID(from: quicConnection, localKeyPair: localKeyPair)

        // Create local address from socket if available
        let localAddress: Multiaddr?
        if let local = quicConnection.localAddress {
            localAddress = local.toQUICMultiaddr()
        } else {
            localAddress = nil
        }

        return QUICMuxedConnection(
            quicConnection: quicConnection,
            localPeer: localKeyPair.peerID,
            remotePeer: remotePeer,
            localAddress: localAddress,
            remoteAddress: address
        )
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
            actualAddress = localAddr.toQUICMultiaddr() ?? address
        } else {
            actualAddress = address
        }

        return QUICSecuredListener(
            endpoint: endpoint,
            localAddress: actualAddress,
            localKeyPair: localKeyPair
        )
    }

    // MARK: - Private Helpers

    /// Extracts PeerID from a QUIC connection using the TLS provider.
    ///
    /// The PeerID is extracted from the X.509 certificate extension
    /// (OID 1.3.6.1.4.1.53594.1.1) that was verified during the TLS handshake.
    ///
    /// - Parameters:
    ///   - connection: The QUIC connection
    ///   - localKeyPair: The local key pair (for fallback if TLS provider not available)
    /// - Returns: The remote peer's PeerID
    /// - Throws: `QUICTransportError.certificateInvalid` if PeerID extraction fails
    private func extractPeerID(from connection: any QUICConnectionProtocol, localKeyPair: KeyPair) throws -> PeerID {
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

        // Fallback: This shouldn't happen if libp2p TLS is properly configured
        throw QUICTransportError.certificateInvalid("Could not extract PeerID from TLS certificate")
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
}
