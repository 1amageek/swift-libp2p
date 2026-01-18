/// YamuxMuxer - Yamux multiplexer implementation
import Foundation
import P2PCore
import P2PMux

/// Yamux multiplexer.
///
/// Upgrades a secured connection to a multiplexed connection
/// supporting multiple bidirectional streams.
public final class YamuxMuxer: Muxer, Sendable {

    public var protocolID: String { "/yamux/1.0.0" }

    /// Configuration for this muxer.
    public let configuration: YamuxConfiguration

    /// Creates a Yamux muxer with default configuration.
    public init() {
        self.configuration = .default
    }

    /// Creates a Yamux muxer with custom configuration.
    ///
    /// - Parameter configuration: The configuration to use.
    public init(configuration: YamuxConfiguration) {
        self.configuration = configuration
    }

    public func multiplex(
        _ connection: any SecuredConnection,
        isInitiator: Bool
    ) async throws -> MuxedConnection {
        let yamuxConnection = YamuxConnection(
            underlying: connection,
            localPeer: connection.localPeer,
            remotePeer: connection.remotePeer,
            isInitiator: isInitiator,
            configuration: configuration
        )
        yamuxConnection.start()
        return yamuxConnection
    }
}
