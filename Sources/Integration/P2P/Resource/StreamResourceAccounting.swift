import P2PCore
import P2PRuntime

internal protocol StreamResourceAccounting: Sendable {
    func reserveStream(peer: PeerID, direction: ConnectionDirection) throws
    func reserveStream(protocolID: String, peer: PeerID, direction: ConnectionDirection) throws
    func releaseStream(peer: PeerID, direction: ConnectionDirection)
    func releaseStream(protocolID: String, peer: PeerID, direction: ConnectionDirection)
}

internal struct ResourceManagerStreamAccounting: StreamResourceAccounting {
    private let base: any ResourceManager

    init(base: any ResourceManager) {
        self.base = base
    }

    func reserveStream(peer: PeerID, direction: ConnectionDirection) throws {
        switch direction {
        case .inbound:
            try base.reserveInboundStream(from: peer)
        case .outbound:
            try base.reserveOutboundStream(to: peer)
        }
    }

    func reserveStream(protocolID: String, peer: PeerID, direction: ConnectionDirection) throws {
        try base.reserveStream(protocolID: protocolID, peer: peer, direction: direction)
    }

    func releaseStream(peer: PeerID, direction: ConnectionDirection) {
        base.releaseStream(peer: peer, direction: direction)
    }

    func releaseStream(protocolID: String, peer: PeerID, direction: ConnectionDirection) {
        base.releaseStream(protocolID: protocolID, peer: peer, direction: direction)
    }
}
