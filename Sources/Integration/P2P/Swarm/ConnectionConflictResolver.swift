import P2PCore
import P2PRuntime

internal protocol ConnectionConflictResolver: Sendable {
    func duplicateConnections(
        from connections: [ManagedConnection],
        localPeerID: PeerID,
        remotePeerID: PeerID
    ) -> [ManagedConnection]
}

internal struct DeterministicConnectionConflictResolver: ConnectionConflictResolver {
    func duplicateConnections(
        from connections: [ManagedConnection],
        localPeerID: PeerID,
        remotePeerID: PeerID
    ) -> [ManagedConnection] {
        guard connections.count >= 2 else { return [] }

        let winningDirection: ConnectionDirection = localPeerID < remotePeerID ? .outbound : .inbound
        var winner: ManagedConnection?
        var losers: [ManagedConnection] = []

        for connection in connections {
            if connection.direction == winningDirection && winner == nil {
                winner = connection
            } else {
                losers.append(connection)
            }
        }

        if winner == nil, !losers.isEmpty {
            losers.sort { ($0.connectedAt ?? .now) < ($1.connectedAt ?? .now) }
            _ = losers.removeFirst()
        }

        return losers
    }
}
