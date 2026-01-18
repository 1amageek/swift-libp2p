/// AutoNATEvent - Events emitted by the AutoNAT service.

import Foundation
import P2PCore

/// Events emitted by the AutoNAT service.
public enum AutoNATEvent: Sendable {
    /// NAT status changed.
    case statusChanged(NATStatus)

    /// A probe was completed.
    case probeCompleted(server: PeerID, result: ProbeResult)

    /// A probe was started.
    case probeStarted(server: PeerID)

    /// A dial-back request was received (server role).
    case dialBackRequested(from: PeerID, addresses: [Multiaddr])

    /// A dial-back was completed (server role).
    case dialBackCompleted(to: PeerID, result: AutoNATResponseStatus)

    /// An error occurred.
    case error(String)
}
