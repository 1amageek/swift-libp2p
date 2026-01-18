/// P2PTransportTCP - TCP transport implementation
import Foundation
import P2PCore
import P2PTransport
import NIOCore
import NIOPosix

/// TCP transport using SwiftNIO.
public final class TCPTransport: Transport, Sendable {

    private let group: EventLoopGroup
    private let ownsGroup: Bool

    /// The protocols this transport supports.
    public var protocols: [[String]] {
        [["ip4", "tcp"], ["ip6", "tcp"]]
    }

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
            try? group.syncShutdownGracefully()
        }
    }

    public func dial(_ address: Multiaddr) async throws -> any RawConnection {
        guard let (host, port) = extractHostPort(from: address) else {
            throw TransportError.unsupportedAddress(address)
        }

        let bootstrap = ClientBootstrap(group: group)
            .channelOption(.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                channel.eventLoop.makeSucceededVoidFuture()
            }

        let channel = try await bootstrap.connect(host: host, port: Int(port)).get()
        let localAddr = channel.localAddress?.toMultiaddr()

        return TCPConnection(
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

    // MARK: - Private helpers

    private func extractHostPort(from address: Multiaddr) -> (String, UInt16)? {
        guard let ip = address.ipAddress,
              let port = address.tcpPort else {
            return nil
        }
        return (ip, port)
    }
}
