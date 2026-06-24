/// WebRTC Direct Transport for libp2p
///
/// Implements SecuredTransport using WebRTC Direct (DTLS 1.2 + SCTP).
/// Like QUIC, WebRTC provides built-in security and multiplexing,
/// so it bypasses the standard libp2p upgrade pipeline.
///
/// Multiaddr format: `/ip4/<ip>/udp/<port>/webrtc-direct/certhash/<hash>`
///
/// UDP I/O is managed internally using NIO DatagramBootstrap.
/// Each dial creates a dedicated ephemeral-port socket.
/// Each listener shares a single socket with address-based routing.

import Foundation
import P2PCore
import P2PTransport
import P2PMux
import P2PCertificate
import WebRTC
import NIOCore
import NIOPosix
import Logging

/// Debug logger for WebRTC transport
private let webrtcTransportLogger = Logger(label: "swift-libp2p.WebRTCTransport")

/// A libp2p transport using WebRTC Direct.
///
/// WebRTC Direct provides:
/// - DTLS 1.2 encryption (security)
/// - SCTP-based data channels (multiplexing)
/// - UDP-based, NAT traversal friendly
///
/// Unlike TCP, WebRTC Direct connections bypass the standard libp2p upgrade
/// pipeline because security and multiplexing are native to the protocol.
public final class WebRTCTransport: SecuredTransport, Sendable {

    private let group: EventLoopGroup
    private let ownsGroup: Bool

    /// Supported protocol chains.
    ///
    /// WebRTC Direct uses UDP as the underlying transport:
    /// - `/ip4/<ip>/udp/<port>/webrtc-direct`
    /// - `/ip6/<ip>/udp/<port>/webrtc-direct`
    public var protocols: [[String]] {
        [["ip4", "udp", "webrtc-direct"], ["ip6", "udp", "webrtc-direct"]]
    }

    public var pathKind: TransportPathKind { .ip }

    /// Creates a WebRTCTransport with a new EventLoopGroup.
    public init() {
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        self.ownsGroup = true
    }

    /// Creates a WebRTCTransport with an existing EventLoopGroup.
    public init(group: EventLoopGroup) {
        self.group = group
        self.ownsGroup = false
    }

    deinit {
        if ownsGroup {
            group.shutdownGracefully { error in
                if let error {
                    webrtcTransportLogger.error("EventLoopGroup shutdown failed: \(error)")
                }
            }
        }
    }

    // MARK: - Transport Protocol

    /// Not supported for WebRTC -- use `dialSecured` instead.
    public func dial(_ address: Multiaddr) async throws -> any RawConnection {
        throw TransportError.unsupportedOperation("WebRTC requires SecuredTransport.dialSecured()")
    }

    /// Not supported for WebRTC -- use `listenSecured` instead.
    public func listen(_ address: Multiaddr) async throws -> any Listener {
        throw TransportError.unsupportedOperation("WebRTC requires SecuredTransport.listenSecured()")
    }

    /// Whether this transport can dial the given address.
    public func canDial(_ address: Multiaddr) -> Bool {
        extractWebRTCComponents(from: address) != nil
    }

    /// Whether this transport can listen on the given address.
    public func canListen(_ address: Multiaddr) -> Bool {
        guard address.ipAddress != nil,
              address.udpPort != nil else {
            return false
        }
        return address.protocols.contains(where: {
            if case .webrtcDirect = $0 { return true }
            return false
        })
    }

    // MARK: - SecuredTransport

    /// Dials a WebRTC Direct address and returns a secured, multiplexed connection.
    ///
    /// Flow:
    /// 1. Generate libp2p certificate with OID extension
    /// 2. Bind ephemeral UDP socket (port 0)
    /// 3. Create WebRTCConnection with send handler wired to socket
    /// 4. Start DTLS handshake and wait for connection (DTLS + SCTP)
    /// 5. Extract verified remote PeerID from certificate
    ///
    /// The method blocks until the DTLS handshake and SCTP association
    /// complete (up to 30s timeout), ensuring the returned connection
    /// has a verified remote PeerID.
    ///
    /// Error handling: If any step after socket bind fails, the channel is
    /// closed to prevent resource leaks.
    public func dialSecured(
        _ address: Multiaddr,
        localKeyPair: KeyPair
    ) async throws -> any MuxedConnection {
        guard let components = extractWebRTCComponents(from: address) else {
            throw TransportError.unsupportedAddress(address)
        }

        // Generate a certificate with the libp2p extension (OID 1.3.6.1.4.1.53594.1.1)
        let generated = try LibP2PCertificate.generate(keyPair: localKeyPair)
        let certificate = try WebRTCCertificate(
            derEncoded: generated.certificateDER,
            privateKey: generated.privateKey
        )
        let endpoint = WebRTCEndpoint(certificate: certificate)

        // Bind ephemeral UDP socket
        let handler = WebRTCUDPHandler()
        let bootstrap = DatagramBootstrap(group: group)
            .channelOption(.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                channel.pipeline.addHandler(handler)
            }

        let bindHost = components.host.contains(":") ? "::0" : "0.0.0.0"
        let channel: any NIOCore.Channel
        do {
            channel = try await bootstrap.bind(host: bindHost, port: 0).get()
        } catch {
            throw WebRTCTransportError.socketBindFailed(underlying: error)
        }

        // All remaining steps are wrapped in do/catch to clean up the channel on error
        do {
            let socket = WebRTCUDPSocket(channel: channel)

            // Create remote NIO SocketAddress for sending
            let remoteSocketAddress: SocketAddress
            do {
                remoteSocketAddress = try SocketAddress(ipAddress: components.host, port: Int(components.port))
            } catch {
                webrtcTransportLogger.warning("Cannot build socket address for \(address): \(error)")
                throw WebRTCTransportError.invalidAddress(address)
            }
            let sendHandler = socket.makeSendHandler(remoteAddress: remoteSocketAddress)

            // Create WebRTC connection with real UDP send handler
            let connection: WebRTCConnection
            do {
                connection = try endpoint.connect(
                    remoteFingerprint: components.fingerprint,
                    sendHandler: sendHandler
                )
            } catch {
                throw TransportError.connectionFailed(underlying: error)
            }

            // Register route so incoming responses are delivered to this connection
            socket.addRoute(remoteAddress: remoteSocketAddress, connection: connection)

            // Wire the NIO handler to the socket's datagram router.
            // setHandlers flushes any datagrams buffered before this point.
            handler.setHandlers(
                onDatagram: { [weak socket] remoteAddr, data in
                    socket?.handleDatagram(from: remoteAddr, data: data)
                },
                onError: { [weak socket] error in
                    socket?.handleChannelError(error)
                }
            )

            // From here on, a failure must also close the connection so
            // its handshake retransmission timers stop
            do {
                // Start DTLS handshake
                do {
                    try connection.start()
                } catch {
                    throw WebRTCTransportError.dtlsHandshakeFailed(underlying: error)
                }

                // Wait for DTLS + SCTP to complete (polls state, 30s timeout)
                try await connection.waitForConnected()

                // Extract PeerID from certificate (guaranteed available after handshake)
                guard let certDER = connection.remoteCertificateDER else {
                    throw WebRTCTransportError.certificateInvalid("No certificate after handshake")
                }
                let remotePeerID: PeerID
                do {
                    remotePeerID = try LibP2PCertificate.extractPeerID(from: certDER)
                } catch {
                    throw WebRTCTransportError.certificateInvalid("PeerID extraction failed: \(error)")
                }

                // When the dialed address pins a PeerID, the certificate
                // must prove it
                if let expectedPeer = address.peerID, expectedPeer != remotePeerID {
                    throw WebRTCTransportError.peerIDMismatch(
                        expected: expectedPeer,
                        actual: remotePeerID
                    )
                }

                // Build local address from bound socket
                let localAddress = channel.localAddress?.toWebRTCDirectMultiaddr(
                    certhash: certificate.fingerprint.multihash
                )

                let muxed = WebRTCMuxedConnection(
                    webrtcConnection: connection,
                    localPeer: localKeyPair.peerID,
                    remotePeer: remotePeerID,
                    localAddress: localAddress,
                    remoteAddress: address,
                    udpSocket: socket // Dial mode: connection owns the socket
                )
                muxed.startForwarding()

                return muxed
            } catch {
                connection.close()
                throw error
            }
        } catch {
            // Clean up the bound channel on any failure after bind
            channel.close(promise: nil)
            throw error
        }
    }

    /// Listens on a WebRTC Direct address.
    ///
    /// Flow:
    /// 1. Generate libp2p certificate with OID extension
    /// 2. Bind UDP socket on requested port
    /// 3. Set up address-based routing for incoming peers
    /// 4. New peers trigger WebRTCListener.acceptConnection()
    public func listenSecured(
        _ address: Multiaddr,
        localKeyPair: KeyPair
    ) async throws -> any SecuredListener {
        guard canListen(address) else {
            throw TransportError.unsupportedAddress(address)
        }

        let host = address.ipAddress ?? "0.0.0.0"
        let port = address.udpPort ?? 0

        // Generate a certificate with the libp2p extension (OID 1.3.6.1.4.1.53594.1.1)
        let generated = try LibP2PCertificate.generate(keyPair: localKeyPair)
        let certificate = try WebRTCCertificate(
            derEncoded: generated.certificateDER,
            privateKey: generated.privateKey
        )
        let endpoint = WebRTCEndpoint(certificate: certificate)
        let listener: WebRTCListener
        do {
            listener = try endpoint.listen()
        } catch {
            throw TransportError.connectionFailed(underlying: error)
        }

        // Bind UDP socket on the requested port
        let handler = WebRTCUDPHandler()
        let bootstrap = DatagramBootstrap(group: group)
            .channelOption(.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                channel.pipeline.addHandler(handler)
            }

        let channel: any NIOCore.Channel
        do {
            channel = try await bootstrap.bind(host: host, port: Int(port)).get()
        } catch {
            // The upstream listener was created before the bind; close it
            // so its connections stream finishes instead of leaking
            listener.close()
            throw WebRTCTransportError.socketBindFailed(underlying: error)
        }

        // Create socket without onNewPeer (set after construction to avoid circular reference)
        let listenSocket = WebRTCUDPSocket(channel: channel)

        // Compute local address with certhash from the bound socket
        let boundAddress = channel.localAddress
        let certhash = certificate.fingerprint.multihash
        let localAddress: Multiaddr
        if let bound = boundAddress?.toWebRTCDirectMultiaddr(certhash: certhash) {
            localAddress = bound
        } else {
            localAddress = Multiaddr.webrtcDirect(
                host: host,
                port: UInt16(boundAddress?.port ?? Int(port)),
                certhash: certhash
            )
        }

        // The secured listener owns the accept pipeline, so it must exist
        // before any datagram can trigger onNewPeer
        let securedListener = WebRTCSecuredListener(
            listener: listener,
            socket: listenSocket,
            localAddress: localAddress,
            localKeyPair: localKeyPair
        )
        securedListener.startAccepting()

        // New peers are handled by the secured listener, which tracks
        // accepted connections for cleanup on failure
        listenSocket.setOnNewPeer { [weak securedListener] remoteAddress in
            securedListener?.handleNewPeer(remoteAddress)
        }

        // Wire the NIO handler to the socket's datagram router.
        // setHandlers flushes any datagrams buffered before this point.
        handler.setHandlers(
            onDatagram: { [weak listenSocket] remoteAddr, data in
                listenSocket?.handleDatagram(from: remoteAddr, data: data)
            },
            onError: { [weak listenSocket] error in
                listenSocket?.handleChannelError(error)
            }
        )

        return securedListener
    }

    // MARK: - Private

    private struct WebRTCAddressComponents {
        let host: String
        let port: UInt16
        let fingerprint: CertificateFingerprint
    }

    private func extractWebRTCComponents(from address: Multiaddr) -> WebRTCAddressComponents? {
        // Port 0 is not a valid dial target; reject rather than silently
        // substituting. `udpPort` is UInt16 so the upper bound is type-enforced.
        guard let ip = address.ipAddress,
              let port = address.udpPort, port > 0 else {
            return nil
        }

        var hasWebRTC = false
        var certhashData: Data?

        for proto in address.protocols {
            switch proto {
            case .webrtcDirect:
                hasWebRTC = true
            case .certhash(let data):
                certhashData = data
            default:
                break
            }
        }

        // certhash is required: without it the DTLS fingerprint cannot be
        // verified, so the address is not dialable
        guard hasWebRTC, let hash = certhashData else { return nil }

        // Multihash format: [hash function code, digest size, ...digest bytes].
        // Only sha2-256 (0x12) with a 32-byte digest is accepted — the DTLS
        // layer compares SHA-256 fingerprints. The digest bytes are already
        // the SHA-256 hash, so use fromDigest to avoid hash-of-hash.
        guard hash.count == 34,
              hash[hash.startIndex] == 0x12,
              hash[hash.startIndex + 1] == 0x20 else {
            return nil
        }
        let digestBytes = Data(hash.dropFirst(2))
        let fingerprint = CertificateFingerprint.fromDigest(digestBytes)

        return WebRTCAddressComponents(host: ip, port: port, fingerprint: fingerprint)
    }
}

// MARK: - Handshake Wait

extension WebRTCConnection {
    /// Waits for the connection to reach `.connected` state (DTLS + SCTP).
    ///
    /// Polls `connection.state` with 10ms intervals. Uses TaskGroup for timeout.
    /// Follows the same pattern as `QUICEndpoint.dial()` and
    /// `QUICSecuredListener.waitForHandshake()`.
    func waitForConnected(timeout: Duration = .seconds(30)) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await Task.sleep(for: timeout)
                throw WebRTCTransportError.handshakeTimeout
            }
            group.addTask {
                while true {
                    switch self.state {
                    case .connected:
                        return
                    case .failed(let reason):
                        throw WebRTCTransportError.dtlsHandshakeFailed(
                            underlying: WebRTCError.connectionFailed(reason)
                        )
                    case .closed:
                        throw WebRTCTransportError.connectionClosed
                    default:
                        try Task.checkCancellation()
                        try await Task.sleep(for: .milliseconds(10))
                    }
                }
            }
            try await group.next()
            group.cancelAll()
        }
    }
}

// MARK: - Errors

/// Errors specific to WebRTC transport operations.
public enum WebRTCTransportError: Error, Sendable {
    case invalidAddress(Multiaddr)
    case dtlsHandshakeFailed(underlying: Error)
    case certificateInvalid(String)
    case peerIDMismatch(expected: PeerID, actual: PeerID)
    case connectionClosed
    case handshakeTimeout
    case socketBindFailed(underlying: Error)
}
