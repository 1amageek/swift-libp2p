/// P2PTransportWebSocket - WebSocket transport implementation
import Foundation
import P2PCore
import P2PTransport
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOWebSocket
import NIOSSL
import os

/// Debug logger for WebSocket transport
private let wsTransportLogger = Logger(subsystem: "swift-libp2p", category: "WebSocketTransport")

/// WebSocket upgrade result for client-side typed upgrade.
enum WebSocketUpgradeResult: Sendable {
    case websocket(Channel, WebSocketFrameHandler)
    case notUpgraded
}

/// TLS configuration for secure WebSocket (`wss`) transport.
public struct WebSocketTLSConfiguration: Sendable {
    /// Client-side TLS configuration used by `dial(_:)` with `/wss`.
    public var client: TLSConfiguration

    /// Server-side TLS configuration used by `listen(_:)` with `/wss`.
    /// If nil, `listen(.wss(...))` fails with an explicit error.
    public var server: TLSConfiguration?

    /// Creates a TLS configuration for WebSocket transport.
    public init(
        client: TLSConfiguration = WebSocketTLSConfiguration.defaultSecureClientConfiguration(),
        server: TLSConfiguration? = nil
    ) {
        self.client = client
        self.server = server
    }

    /// Secure default for `wss`: certificate chain + hostname verification.
    public static func defaultSecureClientConfiguration() -> TLSConfiguration {
        var config = TLSConfiguration.makeClientConfiguration()
        config.certificateVerification = .fullVerification
        return config
    }
}

/// Internal error for WebSocket failure details.
internal enum WebSocketDetailError: Error, CustomStringConvertible, Sendable {
    case upgradeFailed
    case tlsConfigurationFailed(String)
    var description: String {
        switch self {
        case .upgradeFailed: return "WebSocket upgrade failed"
        case .tlsConfigurationFailed(let msg): return "TLS configuration failed: \(msg)"
        }
    }
}

/// Maximum WebSocket frame size (1MB), matching the read buffer limit.
let wsMaxFrameSize = 1024 * 1024

/// WebSocket transport using SwiftNIO.
///
/// Implements the `Transport` protocol (like TCP), returning `RawConnection`
/// for the standard libp2p upgrade pipeline (Security → Mux).
///
/// Multiaddr formats:
/// - `/ip4/<host>/tcp/<port>/ws` - Insecure WebSocket
/// - `/ip4|ip6|dns|dns4|dns6/<host>/tcp/<port>/ws` - Insecure WebSocket
/// - `/ip4|ip6|dns|dns4|dns6/<host>/tcp/<port>/wss` - Secure WebSocket (TLS)
public final class WebSocketTransport: Transport, Sendable {

    private let group: EventLoopGroup
    private let ownsGroup: Bool
    private let tlsConfiguration: WebSocketTLSConfiguration

    /// The protocols this transport supports.
    ///
    /// Note: `/tls/ws` format is NOT supported because `tls` is not a valid
    /// Multiaddr protocol. Use `/wss` format instead.
    public var protocols: [[String]] {
        [
            ["ip4", "tcp", "ws"],
            ["ip6", "tcp", "ws"],
            ["dns", "tcp", "ws"],
            ["dns4", "tcp", "ws"],
            ["dns6", "tcp", "ws"],
            ["ip4", "tcp", "wss"],
            ["ip6", "tcp", "wss"],
            ["dns", "tcp", "wss"],
            ["dns4", "tcp", "wss"],
            ["dns6", "tcp", "wss"],
        ]
    }

    /// Creates a WebSocketTransport with a new EventLoopGroup.
    public init() {
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        self.ownsGroup = true
        self.tlsConfiguration = WebSocketTLSConfiguration()
    }

    /// Creates a WebSocketTransport with custom TLS configuration.
    public init(tlsConfiguration: WebSocketTLSConfiguration) {
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        self.ownsGroup = true
        self.tlsConfiguration = tlsConfiguration
    }

    /// Creates a WebSocketTransport with an existing EventLoopGroup.
    public init(group: EventLoopGroup) {
        self.group = group
        self.ownsGroup = false
        self.tlsConfiguration = WebSocketTLSConfiguration()
    }

    /// Creates a WebSocketTransport with an existing EventLoopGroup and custom TLS settings.
    public init(group: EventLoopGroup, tlsConfiguration: WebSocketTLSConfiguration) {
        self.group = group
        self.ownsGroup = false
        self.tlsConfiguration = tlsConfiguration
    }

    deinit {
        if ownsGroup {
            group.shutdownGracefully { error in
                if let error {
                    wsTransportLogger.error("EventLoopGroup shutdown failed: \(error)")
                }
            }
        }
    }

    public func dial(_ address: Multiaddr) async throws -> any RawConnection {
        guard let (host, port, isSecure, isIPAddress) = extractHostPort(
            from: address,
            allowDNS: true,
            allowPeerID: true
        ) else {
            throw TransportError.unsupportedAddress(address)
        }

        if isSecure {
            return try await dialSecure(host: host, port: port, isIPAddress: isIPAddress, address: address)
        } else {
            return try await dialInsecure(host: host, port: port, address: address)
        }
    }

    /// Dial insecure WebSocket (ws://)
    private func dialInsecure(host: String, port: UInt16, address: Multiaddr) async throws -> any RawConnection {
        wsTransportLogger.debug("dial(): Connecting to ws://\(host):\(port)")

        let upgradeResult: EventLoopFuture<WebSocketUpgradeResult> = try await ClientBootstrap(group: group)
            .channelOption(.socketOption(.so_reuseaddr), value: 1)
            .connect(host: host, port: Int(port)) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try self.configureWebSocketUpgrade(channel: channel, host: host, port: port)
                }
            }

        return try await completeUpgrade(
            upgradeResult: upgradeResult,
            address: address,
            isSecure: false
        )
    }

    /// Dial secure WebSocket (wss://)
    private func dialSecure(
        host: String,
        port: UInt16,
        isIPAddress: Bool,
        address: Multiaddr
    ) async throws -> any RawConnection {
        wsTransportLogger.debug("dial(): Connecting to wss://\(host):\(port)")

        // Enforce strict certificate + hostname verification for secure WebSocket.
        if case .fullVerification = tlsConfiguration.client.certificateVerification {
            // expected
        } else {
            throw TransportError.unsupportedOperation("WSS requires fullVerification TLS configuration")
        }

        // Hostname verification requires a DNS hostname.
        // IP literals are rejected for secure dial to avoid unverifiable TLS identity.
        if isIPAddress {
            throw TransportError.unsupportedAddress(address)
        }

        // Configure TLS
        let tlsConfig = tlsConfiguration.client
        let sslContext: NIOSSLContext
        do {
            sslContext = try NIOSSLContext(configuration: tlsConfig)
        } catch {
            throw TransportError.connectionFailed(underlying: WebSocketDetailError.tlsConfigurationFailed(String(describing: error)))
        }

        let upgradeResult: EventLoopFuture<WebSocketUpgradeResult> = try await ClientBootstrap(group: group)
            .channelOption(.socketOption(.so_reuseaddr), value: 1)
            .connect(host: host, port: Int(port)) { channel in
                channel.eventLoop.makeCompletedFuture {
                    // Add TLS handler first
                    let sslHandler: NIOSSLClientHandler
                    do {
                        sslHandler = try NIOSSLClientHandler(context: sslContext, serverHostname: host)
                    } catch {
                        throw TransportError.connectionFailed(underlying: WebSocketDetailError.tlsConfigurationFailed(String(describing: error)))
                    }
                    try channel.pipeline.syncOperations.addHandler(sslHandler)

                    // Then configure WebSocket upgrade
                    return try self.configureWebSocketUpgrade(channel: channel, host: host, port: port)
                }
            }

        return try await completeUpgrade(
            upgradeResult: upgradeResult,
            address: address,
            isSecure: true
        )
    }

    /// Configure WebSocket upgrade pipeline
    private func configureWebSocketUpgrade(
        channel: Channel,
        host: String,
        port: UInt16
    ) throws -> EventLoopFuture<WebSocketUpgradeResult> {
        let upgrader = NIOTypedWebSocketClientUpgrader<WebSocketUpgradeResult>(
            maxFrameSize: wsMaxFrameSize,
            upgradePipelineHandler: { channel, _ in
                channel.eventLoop.makeCompletedFuture {
                    let handler = WebSocketFrameHandler(isClient: true)
                    try channel.pipeline.syncOperations.addHandler(handler)
                    return WebSocketUpgradeResult.websocket(channel, handler)
                }
            }
        )

        var headers = HTTPHeaders()
        headers.add(name: "Host", value: "\(host):\(port)")
        headers.add(name: "Content-Length", value: "0")

        let requestHead = HTTPRequestHead(
            version: .http1_1,
            method: .GET,
            uri: "/",
            headers: headers
        )

        let clientUpgradeConfiguration = NIOTypedHTTPClientUpgradeConfiguration(
            upgradeRequestHead: requestHead,
            upgraders: [upgrader],
            notUpgradingCompletionHandler: { channel in
                channel.eventLoop.makeSucceededFuture(.notUpgraded)
            }
        )

        let negotiationResultFuture = try channel.pipeline.syncOperations
            .configureUpgradableHTTPClientPipeline(
                configuration: .init(upgradeConfiguration: clientUpgradeConfiguration)
            )

        return negotiationResultFuture
    }

    /// Complete WebSocket upgrade and return connection
    private func completeUpgrade(
        upgradeResult: EventLoopFuture<WebSocketUpgradeResult>,
        address: Multiaddr,
        isSecure: Bool
    ) async throws -> any RawConnection {
        switch try await upgradeResult.get() {
        case .websocket(let channel, let handler):
            let localAddr = channel.localAddress?.toWebSocketMultiaddr(secure: isSecure)
            let connection = WebSocketConnection(
                channel: channel,
                isClient: true,
                localAddress: localAddr,
                remoteAddress: address
            )
            handler.setConnection(connection)
            wsTransportLogger.debug("dial(): WebSocket upgrade succeeded")
            return connection

        case .notUpgraded:
            wsTransportLogger.error("dial(): WebSocket upgrade failed")
            throw TransportError.connectionFailed(underlying: WebSocketDetailError.upgradeFailed)
        }
    }

    public func listen(_ address: Multiaddr) async throws -> any Listener {
        guard let (host, port, isSecure, _) = extractHostPort(
            from: address,
            allowDNS: false,
            allowPeerID: false
        ) else {
            throw TransportError.unsupportedAddress(address)
        }

        if isSecure {
            guard let serverTLS = tlsConfiguration.server else {
                throw TransportError.unsupportedOperation("WSS listener requires server TLS configuration")
            }

            let sslContext: NIOSSLContext
            do {
                sslContext = try NIOSSLContext(configuration: serverTLS)
            } catch {
                throw TransportError.connectionFailed(underlying: WebSocketDetailError.tlsConfigurationFailed(String(describing: error)))
            }

            return try await WebSocketListener.bind(
                host: host,
                port: port,
                group: group,
                secure: true,
                sslContext: sslContext
            )
        }

        let listener = try await WebSocketListener.bind(
            host: host,
            port: port,
            group: group,
            secure: false,
            sslContext: nil
        )

        return listener
    }

    public func canDial(_ address: Multiaddr) -> Bool {
        guard let (_, _, isSecure, isIPAddress) = extractHostPort(
            from: address,
            allowDNS: true,
            allowPeerID: true
        ) else {
            return false
        }

        if isSecure {
            if isIPAddress {
                return false
            }
            if case .fullVerification = tlsConfiguration.client.certificateVerification {
                // expected
            } else {
                return false
            }
        }

        return true
    }

    public func canListen(_ address: Multiaddr) -> Bool {
        guard let (_, _, isSecure, _) = extractHostPort(
            from: address,
            allowDNS: false,
            allowPeerID: false
        ) else {
            return false
        }

        if isSecure {
            return tlsConfiguration.server != nil
        }

        return true
    }

    // MARK: - Private helpers

    /// Extract host, port, and security flag from multiaddr.
    /// Returns (host, port, isSecure) or nil if not a valid WebSocket address.
    ///
    /// Supported formats:
    /// - `/ip4/<host>/tcp/<port>/ws` - insecure
    /// - `/ip4/<host>/tcp/<port>/wss` - secure (TLS)
    /// - `/dns|dns4|dns6/<host>/tcp/<port>/ws` - insecure (dial only)
    /// - `/dns|dns4|dns6/<host>/tcp/<port>/wss` - secure (dial only)
    /// - `.../p2p/<peer>` suffix is accepted only for dial/canDial.
    ///
    /// Note: `/tls/ws` format is NOT supported because `tls` is not a valid
    /// Multiaddr protocol.
    private func extractHostPort(
        from address: Multiaddr,
        allowDNS: Bool,
        allowPeerID: Bool
    ) -> (host: String, port: UInt16, isSecure: Bool, isIPAddress: Bool)? {
        let protocols = address.protocols
        guard protocols.count >= 3, protocols.count <= 4 else {
            return nil
        }

        if protocols.count == 4 {
            guard allowPeerID else { return nil }
            guard case .p2p = protocols[3] else {
                return nil
            }
        }

        let host: String
        let isIPAddress: Bool
        switch protocols[0] {
        case .ip4(let ip):
            host = ip
            isIPAddress = true
        case .ip6(let ip):
            host = ip
            isIPAddress = true
        case .dns(let domain), .dns4(let domain), .dns6(let domain):
            guard allowDNS else { return nil }
            host = domain
            isIPAddress = false
        default:
            return nil
        }

        guard case .tcp(let port) = protocols[1] else {
            return nil
        }

        let isSecure: Bool
        switch protocols[2] {
        case .ws:
            isSecure = false
        case .wss:
            isSecure = true
        default:
            return nil
        }

        return (host, port, isSecure, isIPAddress)
    }
}
