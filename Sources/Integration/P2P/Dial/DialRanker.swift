/// DialRanker - Ranks and groups addresses for Happy Eyeballs style dialing

import P2PCore

/// A group of addresses to dial together, with a delay before the next group.
public struct DialGroup: Sendable {
    /// Addresses in this group (dialed concurrently).
    public let addresses: [Multiaddr]
    /// Delay after the previous group before starting this group.
    public let delay: Duration

    public init(addresses: [Multiaddr], delay: Duration = .zero) {
        self.addresses = addresses
        self.delay = delay
    }
}

/// Protocol for ranking dial addresses.
public protocol DialRanker: Sendable {
    /// Ranks addresses into ordered groups for dialing.
    func rankAddresses(_ addresses: [Multiaddr]) -> [DialGroup]
}
