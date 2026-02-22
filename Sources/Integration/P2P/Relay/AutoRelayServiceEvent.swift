/// AutoRelayServiceEvent - Events emitted by AutoRelayService.

import P2PCore

/// Events emitted by `AutoRelayService`.
public enum AutoRelayServiceEvent: Sendable {
    /// Monitoring started (NAT detected as private).
    case activated

    /// Monitoring stopped (NAT detected as public or shutdown).
    case deactivated

    /// A relay reservation was successfully established.
    case relayReserved(relay: PeerID, addresses: [Multiaddr])

    /// A relay was lost (disconnected or reservation expired).
    case relayLost(relay: PeerID)

    /// A reservation attempt failed.
    case reservationFailed(relay: PeerID, error: String)

    /// The set of relay addresses changed.
    case relayAddressesUpdated([Multiaddr])

    /// A candidate relay was added.
    case candidateAdded(PeerID)
}
