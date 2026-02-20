/// P2PTransportTCP - TCP transport implementation
import Foundation
import P2PCore
import P2PTransport
import NIOCore
import NIOPosix
import os

/// Debug logger for TCP transport
private let tcpTransportLogger = Logger(subsystem: "swift-libp2p", category: "TCPTransport")

/// TCP transport using SwiftNIO.
public final class TCPTransport: Transport, Sendable {

    private let group: EventLoopGroup
    private let ownsGroup: Bool

    /// The protocols this transport supports.
    public var protocols: [[String]] {
        [["ip4", "tcp"], ["ip6", "tcp"]]
    }

    public var pathKind: TransportPathKind { .ip }

    /// Creates a TCPTransport with a new EventLoopGroup.
    public init() {
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        self.ownsGroup = true
    }

    /// Creates a TCPTransport with an existing EventLoopGroup.
    public init(group: EventLoopGroup) {
        self.group = group
        self.ownsGroup = false
    }

    deinit {
        if ownsGroup {
            group.shutdownGracefully { error in
                if let error {
                    tcpTransportLogger.error("EventLoopGroup shutdown failed: \(error)")
                }
            }
        }
    }

    public func dial(_ address: Multiaddr) async throws -> any RawConnection {
        guard let (host, port) = extractHostPort(from: address) else {
            throw TransportError.unsupportedAddress(address)
        }

        let bootstrap = ClientBootstrap(group: group)
            .channelOption(.socketOption(.so_reuseaddr), value: 1)
            .channelOption(.socketOption(.tcp_nodelay), value: 1)
            .channelOption(.socketOption(.so_keepalive), value: 1)
            .channelInitializer { channel in
                channel.eventLoop.makeSucceededVoidFuture()
            }

        let channel = try await bootstrap.connect(host: host, port: Int(port)).get()
        let localAddr = channel.localAddress?.toMultiaddr()

        return try await TCPConnection.create(
            channel: channel,
            localAddress: localAddr,
            remoteAddress: address
        )
    }

    public func listen(_ address: Multiaddr) async throws -> any Listener {
        guard let (host, port) = extractHostPort(from: address) else {
            throw TransportError.unsupportedAddress(address)
        }

        let listener = try await TCPListener.bind(
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

    // MARK: - Hole Punch API

    /// Dials from a specific local port for TCP simultaneous open (hole punching).
    ///
    /// Sets `SO_REUSEADDR` and `SO_REUSEPORT` so the same local port can be
    /// shared with an active listener. This enables NAT hole punching by
    /// sending SYN packets from the listener's port to create a NAT mapping.
    ///
    /// - Parameters:
    ///   - address: The remote address to connect to
    ///   - localPort: The local port to bind (typically the listener's port)
    /// - Returns: A raw connection from the specified local port
    /// - Throws: `TransportError.unsupportedAddress` if the address is invalid
    public func dialWithReusePort(
        _ address: Multiaddr,
        fromPort localPort: UInt16
    ) async throws -> any RawConnection {
        guard let (host, port) = extractHostPort(from: address) else {
            throw TransportError.unsupportedAddress(address)
        }

        let reusePortOption = ChannelOptions.Types.SocketOption(
            level: NIOBSDSocket.OptionLevel.socket,
            name: NIOBSDSocket.Option(rawValue: SO_REUSEPORT)
        )

        let bootstrap = ClientBootstrap(group: group)
            .channelOption(.socketOption(.so_reuseaddr), value: 1)
            .channelOption(reusePortOption, value: 1)
            .channelOption(.socketOption(.tcp_nodelay), value: 1)
            .channelOption(.socketOption(.so_keepalive), value: 1)
            .channelInitializer { channel in
                channel.eventLoop.makeSucceededVoidFuture()
            }
            .bind(to: try SocketAddress(ipAddress: "0.0.0.0", port: Int(localPort)))

        let channel = try await bootstrap
            .connect(host: host, port: Int(port))
            .get()

        let localAddr = channel.localAddress?.toMultiaddr()

        return try await TCPConnection.create(
            channel: channel,
            localAddress: localAddr,
            remoteAddress: address
        )
    }

    // MARK: - Private helpers

    private func extractHostPort(from address: Multiaddr) -> (String, UInt16)? {
        guard let ip = address.ipAddress,
              let port = address.tcpPort else {
            return nil
        }
        return (ip, port)
    }
}
