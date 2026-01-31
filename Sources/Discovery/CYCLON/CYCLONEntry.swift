/// A single entry in the CYCLON partial view.

import P2PCore

/// Represents a peer known to the CYCLON protocol with age tracking.
public struct CYCLONEntry: Sendable, Hashable {

    /// The peer identifier.
    public let peerID: PeerID

    /// Known addresses for this peer.
    public let addresses: [Multiaddr]

    /// Age of this entry in shuffle cycles. Older entries are replaced first.
    public var age: UInt64

    public init(peerID: PeerID, addresses: [Multiaddr], age: UInt64 = 0) {
        self.peerID = peerID
        self.addresses = addresses
        self.age = age
    }

    public static func == (lhs: CYCLONEntry, rhs: CYCLONEntry) -> Bool {
        lhs.peerID == rhs.peerID
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(peerID)
    }
}
