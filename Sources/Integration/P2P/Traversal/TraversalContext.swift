import P2PCore
import P2PProtocols
import P2PTransport

/// Runtime context shared across traversal mechanisms.
public struct TraversalContext: Sendable {
    public let localPeer: PeerID
    public let targetPeer: PeerID
    public let knownAddresses: [Multiaddr]
    public let transports: [any Transport]
    public let connectedPeers: [PeerID]
    public let opener: (any StreamOpener)?
    public let getLocalAddresses: @Sendable () -> [Multiaddr]
    public let isLimitedConnection: @Sendable (PeerID) -> Bool
    public let dialAddress: @Sendable (Multiaddr) async throws -> PeerID

    public init(
        localPeer: PeerID,
        targetPeer: PeerID,
        knownAddresses: [Multiaddr],
        transports: [any Transport],
        connectedPeers: [PeerID],
        opener: (any StreamOpener)?,
        getLocalAddresses: @escaping @Sendable () -> [Multiaddr],
        isLimitedConnection: @escaping @Sendable (PeerID) -> Bool,
        dialAddress: @escaping @Sendable (Multiaddr) async throws -> PeerID
    ) {
        self.localPeer = localPeer
        self.targetPeer = targetPeer
        self.knownAddresses = knownAddresses
        self.transports = transports
        self.connectedPeers = connectedPeers
        self.opener = opener
        self.getLocalAddresses = getLocalAddresses
        self.isLimitedConnection = isLimitedConnection
        self.dialAddress = dialAddress
    }
}
