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

    /// A dial-back request was rejected due to rate limiting or validation failure.
    case dialRequestRejected(from: PeerID, reason: RequestRejectionReason)

    /// Rate limit state changed (for monitoring).
    case rateLimitStateChanged(globalConcurrent: Int, globalRequests: Int)

    /// An error occurred.
    case error(String)
}

/// Reasons for rejecting a dial request.
public enum RequestRejectionReason: Sendable, Equatable {
    /// Rate limit exceeded.
    case rateLimited(RateLimitReason)

    /// Peer ID mismatch (request peer ID doesn't match remote peer).
    case peerIDMismatch

    /// Port not allowed for dial-back.
    case portNotAllowed(UInt16)

    /// No valid addresses after filtering.
    case noValidAddresses
}
