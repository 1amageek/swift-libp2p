import P2PCore
import P2PRuntime

internal protocol ConnectionResourceAccounting: Sendable {
    func reserveConnection(peer: PeerID, direction: ConnectionDirection) throws
    func releaseConnection(peer: PeerID, direction: ConnectionDirection)
}

internal struct ResourceManagerConnectionAccounting: ConnectionResourceAccounting {
    private let base: any ResourceManager

    init(base: any ResourceManager) {
        self.base = base
    }

    func reserveConnection(peer: PeerID, direction: ConnectionDirection) throws {
        switch direction {
        case .inbound:
            try base.reserveInboundConnection(from: peer)
        case .outbound:
            try base.reserveOutboundConnection(to: peer)
        }
    }

    func releaseConnection(peer: PeerID, direction: ConnectionDirection) {
        base.releaseConnection(peer: peer, direction: direction)
    }
}
