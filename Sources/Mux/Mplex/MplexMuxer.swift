/// MplexMuxer - Muxer implementation for Mplex
import Foundation
import P2PCore
import P2PMux

/// A muxer that multiplexes connections using the Mplex protocol.
public struct MplexMuxer: Muxer, Sendable {

    public var protocolID: String { mplexProtocolID }

    private let configuration: MplexConfiguration

    /// Creates a Mplex muxer with the given configuration.
    ///
    /// - Parameter configuration: The configuration to use (default: `.default`)
    public init(configuration: MplexConfiguration = .default) {
        self.configuration = configuration
    }

    public func multiplex(
        _ connection: any SecuredConnection,
        isInitiator: Bool
    ) async throws -> MuxedConnection {
        let mplexConnection = MplexConnection(
            underlying: connection,
            localPeer: connection.localPeer,
            remotePeer: connection.remotePeer,
            isInitiator: isInitiator,
            configuration: configuration
        )
        mplexConnection.start()
        return mplexConnection
    }
}
