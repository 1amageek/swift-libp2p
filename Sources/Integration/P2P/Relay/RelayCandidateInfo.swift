/// RelayCandidateInfo - Metadata about a relay candidate.

import Foundation
import P2PCore

/// Metadata about a relay candidate, provided as input to the selector.
public struct RelayCandidateInfo: Sendable {
    /// The candidate's peer ID.
    public let peer: PeerID

    /// Known addresses for the candidate.
    public let addresses: [Multiaddr]

    /// Measured round-trip time (nil if unknown).
    public let rtt: Duration?

    /// Number of recent failures when reserving on this candidate.
    public let recentFailures: Int

    /// Whether the candidate supports relay protocol.
    public let supportsRelay: Bool

    public init(
        peer: PeerID,
        addresses: [Multiaddr],
        rtt: Duration?,
        recentFailures: Int,
        supportsRelay: Bool
    ) {
        self.peer = peer
        self.addresses = addresses
        self.rtt = rtt
        self.recentFailures = recentFailures
        self.supportsRelay = supportsRelay
    }
}
