import P2PCore
import P2PProtocols
import P2PRuntime
import P2PTransport

public protocol TraversalDialCapability: Sendable {
    func canDial(_ address: Multiaddr, via pathKind: TraversalPathKind) -> Bool
}

public struct EmptyTraversalDialCapability: TraversalDialCapability {
    public init() {}

    public func canDial(_ address: Multiaddr, via pathKind: TraversalPathKind) -> Bool {
        false
    }
}

public struct TransportTraversalDialCapability: TraversalDialCapability {
    public let transports: [any Transport]

    public init(transports: [any Transport]) {
        self.transports = transports
    }

    public func canDial(_ address: Multiaddr, via pathKind: TraversalPathKind) -> Bool {
        guard let transportPathKind = pathKind.transportPathKind else {
            return false
        }

        return transports.contains { transport in
            transport.pathKind == transportPathKind && transport.canDial(address)
        }
    }
}

public struct ConnectionProviderTraversalDialCapability: TraversalDialCapability {
    public let providers: [any ConnectionProvider]

    public init(providers: [any ConnectionProvider]) {
        self.providers = providers
    }

    public func canDial(_ address: Multiaddr, via pathKind: TraversalPathKind) -> Bool {
        guard let transportPathKind = pathKind.transportPathKind else {
            return false
        }

        return providers.contains { provider in
            provider.pathKind == transportPathKind && provider.canDial(address)
        }
    }
}

public extension TraversalPathKind {
    var transportPathKind: TransportPathKind? {
        switch self {
        case .local:
            .local
        case .ip, .holePunch:
            .ip
        case .relay:
            .relay
        case .unknown:
            nil
        }
    }
}

/// Runtime context shared across traversal mechanisms.
public struct TraversalContext: Sendable {
    public let localPeer: PeerID
    public let targetPeer: PeerID
    public let knownAddresses: [Multiaddr]
    public let dialCapability: any TraversalDialCapability
    public let connectedPeers: [PeerID]
    public let opener: (any StreamOpener)?
    public let getLocalAddresses: @Sendable () -> [Multiaddr]
    public let isLimitedConnection: @Sendable (PeerID) -> Bool
    public let dialAddress: @Sendable (Multiaddr) async throws -> PeerID

    public init(
        localPeer: PeerID,
        targetPeer: PeerID,
        knownAddresses: [Multiaddr],
        dialCapability: any TraversalDialCapability,
        connectedPeers: [PeerID],
        opener: (any StreamOpener)?,
        getLocalAddresses: @escaping @Sendable () -> [Multiaddr],
        isLimitedConnection: @escaping @Sendable (PeerID) -> Bool,
        dialAddress: @escaping @Sendable (Multiaddr) async throws -> PeerID
    ) {
        self.localPeer = localPeer
        self.targetPeer = targetPeer
        self.knownAddresses = knownAddresses
        self.dialCapability = dialCapability
        self.connectedPeers = connectedPeers
        self.opener = opener
        self.getLocalAddresses = getLocalAddresses
        self.isLimitedConnection = isLimitedConnection
        self.dialAddress = dialAddress
    }
}
