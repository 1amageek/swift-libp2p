/// Events emitted by DCUtR service.

import Foundation
import P2PCore

/// Events emitted by the DCUtR service.
public enum DCUtREvent: Sendable {
    /// A hole punch attempt has started.
    case holePunchAttemptStarted(peer: PeerID, attempt: Int = 1)

    /// A single hole punch attempt failed (will retry if attempts remain).
    case holePunchAttemptFailed(peer: PeerID, attempt: Int, maxAttempts: Int, reason: String)

    /// A direct connection was successfully established.
    case directConnectionEstablished(peer: PeerID, address: Multiaddr)

    /// All hole punch attempts failed.
    case holePunchFailed(peer: PeerID, reason: String)

    /// Address exchange completed with a peer.
    case addressExchangeCompleted(peer: PeerID, theirAddresses: [Multiaddr])
}
