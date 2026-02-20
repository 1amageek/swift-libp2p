import Foundation
import P2PCore
import P2PTransport
import P2PMux
import P2PTransportQUIC
import QUIC
import NIOUDPTransport

/// A libp2p transport using WebTransport semantics over QUIC.
public final class WebTransportTransport: SecuredTransport, Sendable {
    public let configuration: WebTransportConfiguration

    private let quicConfiguration: QUICConfiguration

    public var protocols: [[String]] {
        [
            ["ip4", "udp", "quic-v1", "webtransport"],
            ["ip6", "udp", "quic-v1", "webtransport"],
            ["dns", "udp", "quic-v1", "webtransport"],
            ["dns4", "udp", "quic-v1", "webtransport"],
            ["dns6", "udp", "quic-v1", "webtransport"],
        ]
    }

    public var pathKind: TransportPathKind { .ip }

    public init(
        configuration: WebTransportConfiguration = .init(),
        quicConfiguration: QUICConfiguration = .libp2p()
    ) {
        self.configuration = configuration
        self.quicConfiguration = quicConfiguration
    }

    // MARK: - Transport

    public func dial(_ address: Multiaddr) async throws -> any RawConnection {
        throw TransportError.unsupportedOperation(
            "WebTransport provides pre-secured connections. Use dialSecured(_:localKeyPair:)."
        )
    }

    public func listen(_ address: Multiaddr) async throws -> any Listener {
        throw TransportError.unsupportedOperation(
            "WebTransport provides pre-secured listeners. Use listenSecured(_:localKeyPair:)."
        )
    }

    public func canDial(_ address: Multiaddr) -> Bool {
        do {
            let components = try WebTransportAddressParser.parse(address, requireCertificateHash: true)
            return components.port != 0
        } catch {
            return false
        }
    }

    public func canListen(_ address: Multiaddr) -> Bool {
        do {
            let components = try WebTransportAddressParser.parse(address, requireCertificateHash: false)
            return components.certificateHashes.isEmpty && !components.host.isDNS
        } catch {
            return false
        }
    }

    // MARK: - SecuredTransport

    public func dialSecured(
        _ address: Multiaddr,
        localKeyPair: KeyPair
    ) async throws -> any MuxedConnection {
        let components = try self.parseDialAddress(address)
        let socketAddress = try self.resolveDialSocketAddress(components)

        var config = quicConfiguration
        config.tlsProviderFactory = { [localKeyPair, expectedPeerID = components.peerID] _ in
            do {
                return try SwiftQUICTLSProvider(
                    localKeyPair: localKeyPair,
                    expectedRemotePeerID: expectedPeerID,
                    alpnProtocols: [WebTransportProtocol.alpn]
                )
            } catch {
                return FailingTLSProvider(error: error)
            }
        }

        let endpoint = QUICEndpoint(configuration: config)
        let quicConnection = try await endpoint.dial(
            address: socketAddress,
            timeout: configuration.connectionTimeout
        )

        do {
            try await WebTransportQUICPeerExtractor.waitForHandshake(
                quicConnection,
                timeout: configuration.connectionTimeout
            )
            let peerInfo = try WebTransportQUICPeerExtractor.extract(from: quicConnection)
            try self.verifyDialCertificateHashes(
                expectedHashes: components.certificateHashes,
                peerCertificates: peerInfo.peerCertificates
            )
            try await WebTransportSessionNegotiator.performClientNegotiation(
                on: quicConnection,
                timeout: configuration.connectionTimeout
            )

            let localAddress = quicConnection.localAddress.map { socketAddress in
                WebTransportAddressBuilder.make(
                    socketAddress: socketAddress,
                    certificateHashes: [],
                    peerID: localKeyPair.peerID
                )
            }

            let connection = WebTransportMuxedConnection(
                quicConnection: quicConnection,
                localPeer: localKeyPair.peerID,
                remotePeer: peerInfo.peerID,
                localAddress: localAddress,
                remoteCertificateHashes: components.certificateHashes,
                onClose: { [endpoint] in
                    await endpoint.shutdown()
                }
            )
            connection.startForwarding()
            return connection
        } catch {
            await quicConnection.close(
                applicationError: 0x100,
                reason: "webtransport dial failed"
            )
            await endpoint.shutdown()
            throw error
        }
    }

    public func listenSecured(
        _ address: Multiaddr,
        localKeyPair: KeyPair
    ) async throws -> any SecuredListener {
        let components = try self.parseListenAddress(address)

        if let peerID = components.peerID, peerID != localKeyPair.peerID {
            throw TransportError.unsupportedAddress(address)
        }

        if !components.certificateHashes.isEmpty {
            throw TransportError.unsupportedAddress(address)
        }

        if components.host.isDNS {
            throw TransportError.unsupportedAddress(address)
        }

        let certificateStore = try WebTransportCertificateStore(
            localKeyPair: localKeyPair,
            rotationInterval: configuration.certRotationInterval
        )

        var config = quicConfiguration
        config.tlsProviderFactory = { [localKeyPair, certificateStore] isClient in
            do {
                if isClient {
                    return try SwiftQUICTLSProvider(
                        localKeyPair: localKeyPair,
                        alpnProtocols: [WebTransportProtocol.alpn]
                    )
                }
                let certificateMaterial = try certificateStore.currentMaterial()
                return try SwiftQUICTLSProvider(
                    localKeyPair: localKeyPair,
                    alpnProtocols: [WebTransportProtocol.alpn],
                    certificateMaterial: certificateMaterial
                )
            } catch {
                return FailingTLSProvider(error: error)
            }
        }

        let udpConfiguration = UDPConfiguration(
            bindAddress: .specific(host: components.hostValue, port: Int(components.port)),
            reuseAddress: true
        )
        let socket = NIOQUICSocket(configuration: udpConfiguration)
        let (endpoint, endpointTask) = try await QUICEndpoint.serve(
            socket: socket,
            configuration: config
        )

        let actualSocketAddress = await endpoint.localAddress ?? components.socketAddress
        let advertisedHashes = try certificateStore.advertisedHashes()
        let localAddress = WebTransportAddressBuilder.make(
            socketAddress: actualSocketAddress,
            certificateHashes: advertisedHashes,
            peerID: localKeyPair.peerID
        )

        let listener = WebTransportSecuredListener(
            endpoint: endpoint,
            endpointTask: endpointTask,
            localSocketAddress: actualSocketAddress,
            localAddress: localAddress,
            localKeyPair: localKeyPair,
            configuration: configuration,
            certificateStore: certificateStore
        )
        listener.startAccepting()
        return listener
    }

    // MARK: - Utilities

    public func extractCertHashes(from address: Multiaddr) -> [[UInt8]] {
        var hashes: [[UInt8]] = []
        for proto in address.protocols {
            if case .certhash(let hash) = proto {
                hashes.append(Array(hash))
            }
        }
        return hashes
    }

    // MARK: - Private

    private func parseDialAddress(_ address: Multiaddr) throws -> WebTransportAddressComponents {
        do {
            let components = try WebTransportAddressParser.parse(address, requireCertificateHash: true)
            guard components.port != 0 else {
                throw TransportError.unsupportedAddress(address)
            }
            return components
        } catch {
            throw TransportError.unsupportedAddress(address)
        }
    }

    private func parseListenAddress(_ address: Multiaddr) throws -> WebTransportAddressComponents {
        do {
            return try WebTransportAddressParser.parse(address, requireCertificateHash: false)
        } catch {
            throw TransportError.unsupportedAddress(address)
        }
    }

    private func verifyDialCertificateHashes(
        expectedHashes: [Data],
        peerCertificates: [Data]
    ) throws {
        guard let leafCertificateDER = peerCertificates.first else {
            throw WebTransportError.certificateVerificationFailed
        }
        guard WebTransportCertificateHash.matchesAny(
            certificateDER: leafCertificateDER,
            expectedHashes: expectedHashes
        ) else {
            throw WebTransportError.certificateVerificationFailed
        }
    }

    private func resolveDialSocketAddress(
        _ components: WebTransportAddressComponents
    ) throws -> QUIC.SocketAddress {
        do {
            return try WebTransportDialAddressResolver.resolve(components)
        } catch let error as WebTransportError {
            throw TransportError.connectionFailed(underlying: error)
        } catch {
            throw TransportError.connectionFailed(underlying: error)
        }
    }
}
