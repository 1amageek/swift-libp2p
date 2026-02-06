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

/// Errors specific to WebSocket transport.
public enum WebSocketTransportError: Error {
    case upgradeFailed
    case tlsConfigurationFailed(String)
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
/// - `/ip4/<host>/tcp/<port>/wss` - Secure WebSocket (TLS)
/// - `/ip4/<host>/tcp/<port>/tls/ws` - TLS + WebSocket (alternative format)
public final class WebSocketTransport: Transport, Sendable {

    private let group: EventLoopGroup
    private let ownsGroup: Bool

    /// The protocols this transport supports.
    ///
    /// Note: `/tls/ws` format is NOT supported because `tls` is not a valid
    /// Multiaddr protocol. Use `/wss` format instead.
    public var protocols: [[String]] {
        [
            ["ip4", "tcp", "ws"],
            ["ip6", "tcp", "ws"],
            ["ip4", "tcp", "wss"],
            ["ip6", "tcp", "wss"],
        ]
    }

    /// Creates a WebSocketTransport with a new EventLoopGroup.
    public init() {
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        self.ownsGroup = true
    }

    /// Creates a WebSocketTransport with an existing EventLoopGroup.
    public init(group: EventLoopGroup) {
        self.group = group
        self.ownsGroup = false
    }

    deinit {
        if ownsGroup {
            do {
                try group.syncShutdownGracefully()
            } catch {
                wsTransportLogger.error("EventLoopGroup shutdown failed: \(error)")
            }
        }
    }

    public func dial(_ address: Multiaddr) async throws -> any RawConnection {
        guard let (host, port, isSecure) = extractHostPort(from: address) else {
            throw TransportError.unsupportedAddress(address)
        }

        if isSecure {
            return try await dialSecure(host: host, port: port, address: address)
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

        return try await completeUpgrade(upgradeResult: upgradeResult, address: address)
    }

    /// Dial secure WebSocket (wss://)
    private func dialSecure(host: String, port: UInt16, address: Multiaddr) async throws -> any RawConnection {
        wsTransportLogger.debug("dial(): Connecting to wss://\(host):\(port)")

        // Configure TLS
        var tlsConfig = TLSConfiguration.makeClientConfiguration()
        tlsConfig.certificateVerification = .none  // For interop testing; production should verify
        let sslContext: NIOSSLContext
        do {
            sslContext = try NIOSSLContext(configuration: tlsConfig)
        } catch {
            throw WebSocketTransportError.tlsConfigurationFailed(String(describing: error))
        }

        // Check if host is an IP address (SNI doesn't work with IP addresses)
        let isIPAddress = host.contains(":") || host.split(separator: ".").allSatisfy { Int($0) != nil }

        let upgradeResult: EventLoopFuture<WebSocketUpgradeResult> = try await ClientBootstrap(group: group)
            .channelOption(.socketOption(.so_reuseaddr), value: 1)
            .connect(host: host, port: Int(port)) { channel in
                channel.eventLoop.makeCompletedFuture {
                    // Add TLS handler first
                    let sslHandler: NIOSSLClientHandler
                    do {
                        if isIPAddress {
                            // IP addresses cannot use SNI
                            sslHandler = try NIOSSLClientHandler(context: sslContext, serverHostname: nil)
                        } else {
                            sslHandler = try NIOSSLClientHandler(context: sslContext, serverHostname: host)
                        }
                    } catch {
                        throw WebSocketTransportError.tlsConfigurationFailed(String(describing: error))
                    }
                    try channel.pipeline.syncOperations.addHandler(sslHandler)

                    // Then configure WebSocket upgrade
                    return try self.configureWebSocketUpgrade(channel: channel, host: host, port: port)
                }
            }

        return try await completeUpgrade(upgradeResult: upgradeResult, address: address)
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
        address: Multiaddr
    ) async throws -> any RawConnection {
        switch try await upgradeResult.get() {
        case .websocket(let channel, let handler):
            let localAddr = channel.localAddress?.toWebSocketMultiaddr()
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
            throw WebSocketTransportError.upgradeFailed
        }
    }

    public func listen(_ address: Multiaddr) async throws -> any Listener {
        guard let (host, port, isSecure) = extractHostPort(from: address) else {
            throw TransportError.unsupportedAddress(address)
        }

        // WSS listener requires certificate configuration
        if isSecure {
            wsTransportLogger.warning("WSS listener not yet implemented, using insecure WS")
        }

        let listener = try await WebSocketListener.bind(
            host: host,
            port: port,
            group: group
        )

        return listener
    }

    public func canDial(_ address: Multiaddr) -> Bool {
        extractHostPort(from: address) != nil
    }

    public func canListen(_ address: Multiaddr) -> Bool {
        extractHostPort(from: address) != nil
    }

    // MARK: - Private helpers

    /// Extract host, port, and security flag from multiaddr.
    /// Returns (host, port, isSecure) or nil if not a valid WebSocket address.
    ///
    /// Supported formats:
    /// - `/ip4/<host>/tcp/<port>/ws` - insecure
    /// - `/ip4/<host>/tcp/<port>/wss` - secure (TLS)
    ///
    /// Note: `/tls/ws` format is NOT supported because `tls` is not a valid
    /// Multiaddr protocol.
    private func extractHostPort(from address: Multiaddr) -> (String, UInt16, Bool)? {
        guard let ip = address.ipAddress,
              let port = address.tcpPort
        else { return nil }

        let hasWS = address.protocols.contains { if case .ws = $0 { return true } else { return false } }
        let hasWSS = address.protocols.contains { if case .wss = $0 { return true } else { return false } }

        if hasWSS {
            return (ip, port, true)
        } else if hasWS {
            return (ip, port, false)
        }

        return nil
    }
}
