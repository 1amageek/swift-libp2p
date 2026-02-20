import P2PCore

/// Errors returned by `PlumtreeDiscovery`.
public enum PlumtreeDiscoveryError: Error, Sendable, Equatable {
    /// The service must be started before announcing.
    case notStarted

    /// Gossip payload could not be interpreted as a valid announcement.
    case invalidAnnouncement

    /// Announcement identity does not match the gossip source peer.
    case spoofedAnnouncement(expected: PeerID, actual: PeerID)

    /// Underlying Plumtree publish failed.
    case publishFailed
}
