/// IdentifyInfo - Data exchanged during Identify protocol
import Foundation
import P2PCore

/// Information exchanged during the Identify protocol.
///
/// Contains peer metadata including supported protocols, listen addresses,
/// and version information.
public struct IdentifyInfo: Sendable, Equatable {
    /// The peer's public key.
    public let publicKey: PublicKey?

    /// Addresses the peer is listening on.
    public let listenAddresses: [Multiaddr]

    /// Protocols the peer supports.
    public let protocols: [String]

    /// The address we were observed at by this peer.
    ///
    /// This is useful for NAT detection and hole punching.
    public let observedAddress: Multiaddr?

    /// Protocol version (e.g., "ipfs/0.1.0").
    public let protocolVersion: String?

    /// Agent version (e.g., "swift-libp2p/0.1.0").
    public let agentVersion: String?

    /// Signed peer record (optional, for authenticated addresses).
    public let signedPeerRecord: Envelope?

    /// Creates a new IdentifyInfo.
    public init(
        publicKey: PublicKey? = nil,
        listenAddresses: [Multiaddr] = [],
        protocols: [String] = [],
        observedAddress: Multiaddr? = nil,
        protocolVersion: String? = nil,
        agentVersion: String? = nil,
        signedPeerRecord: Envelope? = nil
    ) {
        self.publicKey = publicKey
        self.listenAddresses = listenAddresses
        self.protocols = protocols
        self.observedAddress = observedAddress
        self.protocolVersion = protocolVersion
        self.agentVersion = agentVersion
        self.signedPeerRecord = signedPeerRecord
    }

    /// Extracts the peer ID from the public key.
    public var peerID: PeerID? {
        publicKey.map { PeerID(publicKey: $0) }
    }
}
