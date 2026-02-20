import Foundation
import P2PCore

/// Wire payload for Discovery announcements over Plumtree gossip.
public struct PlumtreeDiscoveryAnnouncement: Sendable, Codable, Equatable {
    /// Announced peer ID string.
    public let peerID: String

    /// Announced listen addresses as multiaddr strings.
    public let addresses: [String]

    /// Sender-side unix timestamp in seconds.
    public let timestamp: UInt64

    /// Monotonic sender-side sequence number.
    public let sequenceNumber: UInt64

    public init(
        peerID: String,
        addresses: [String],
        timestamp: UInt64,
        sequenceNumber: UInt64
    ) {
        self.peerID = peerID
        self.addresses = addresses
        self.timestamp = timestamp
        self.sequenceNumber = sequenceNumber
    }

    public init(
        peerID: PeerID,
        addresses: [Multiaddr],
        timestamp: UInt64,
        sequenceNumber: UInt64
    ) {
        self.peerID = peerID.description
        self.addresses = addresses.map(\.description)
        self.timestamp = timestamp
        self.sequenceNumber = sequenceNumber
    }

    public func encode() throws -> Data {
        try JSONEncoder().encode(self)
    }

    public static func decode(_ data: Data) throws -> PlumtreeDiscoveryAnnouncement {
        try JSONDecoder().decode(PlumtreeDiscoveryAnnouncement.self, from: data)
    }
}
