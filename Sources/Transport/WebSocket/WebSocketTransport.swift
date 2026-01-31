/// P2PTransportWebSocket - WebSocket transport implementation
import Foundation
import P2PCore
import P2PTransport
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOWebSocket
import os

/// Debug logger for WebSocket transport
private let wsTransportLogger = Logger(subsystem: "swift-libp2p", category: "WebSocketTransport")

/// WebSocket upgrade result for client-side typed upgrade.
enum WebSocketUpgradeResult: Sendable {
    case websocket(Channel, WebSocketFrameHandler)
    case notUpgraded
}

/// Errors specific to WebSocket transport.
enum WebSocketTransportError: Error {
    case upgradeFailed
}

/// Maximum WebSocket frame size (1MB), matching the read buffer limit.
let wsMaxFrameSize = 1024 * 1024

/// WebSocket transport using SwiftNIO.
///
/// Implements the `Transport` protocol (like TCP), returning `RawConnection`
/// for the standard libp2p upgrade pipeline (Security → Mux).
///
/// Multiaddr format: `/ip4/<host>/tcp/<port>/ws`
public final class WebSocketTransport: Transport, Sendable {

    private let group: EventLoopGroup
    private let ownsGroup: Bool

    /// The protocols this transport supports.
    public var protocols: [[String]] {
        [["ip4", "tcp", "ws"], ["ip6", "tcp", "ws"]]
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
        guard let (host, port) = extractHostPort(from: address) else {
            throw TransportError.unsupportedAddress(address)
        }

        wsTransportLogger.debug("dial(): Connecting to \(host):\(port)")

        let upgradeResult: EventLoopFuture<WebSocketUpgradeResult> = try await ClientBootstrap(group: group)
            .channelOption(.socketOption(.so_reuseaddr), value: 1)
            .connect(host: host, port: Int(port)) { channel in
                channel.eventLoop.makeCompletedFuture {
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
            }

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
        guard let (host, port) = extractHostPort(from: address) else {
            throw TransportError.unsupportedAddress(address)
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

    private func extractHostPort(from address: Multiaddr) -> (String, UInt16)? {
        guard let ip = address.ipAddress,
              let port = address.tcpPort,
              address.protocols.contains(where: { if case .ws = $0 { return true } else { return false } })
        else { return nil }
        return (ip, port)
    }
}
