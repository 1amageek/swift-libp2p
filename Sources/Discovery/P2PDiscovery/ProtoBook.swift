/// P2PDiscovery - ProtoBook
///
/// Per-peer protocol tracking. Stores which protocols each peer supports.
/// Go-compatible: SetProtocols (full replace), AddProtocols (union),
/// RemoveProtocols, SupportsProtocols, FirstSupportedProtocol.

import P2PCore

// MARK: - ProtoBook Protocol

/// Protocol for tracking which protocols each peer supports.
///
/// ProtoBook stores per-peer protocol sets and provides efficient queries
/// for protocol matching and peer lookup.
public protocol ProtoBook: Sendable {

    /// Returns all protocols supported by a peer.
    ///
    /// - Parameter peer: The peer to look up.
    /// - Returns: Array of protocol IDs, may be empty for unknown peers.
    func protocols(for peer: PeerID) async -> [String]

    /// Replaces all protocols for a peer with the given set.
    ///
    /// - Parameters:
    ///   - protocols: The complete set of protocols.
    ///   - peer: The peer to update.
    func setProtocols(_ protocols: [String], for peer: PeerID) async

    /// Adds protocols to a peer's existing set (union).
    ///
    /// - Parameters:
    ///   - protocols: The protocols to add.
    ///   - peer: The peer to update.
    func addProtocols(_ protocols: [String], for peer: PeerID) async

    /// Removes specific protocols from a peer's set.
    ///
    /// - Parameters:
    ///   - protocols: The protocols to remove.
    ///   - peer: The peer to update.
    func removeProtocols(_ protocols: [String], from peer: PeerID) async

    /// Returns the subset of given protocols that the peer supports.
    ///
    /// - Parameters:
    ///   - protocols: The protocols to check.
    ///   - peer: The peer to check against.
    /// - Returns: Protocols from the input that the peer supports.
    func supportsProtocols(_ protocols: [String], for peer: PeerID) async -> [String]

    /// Returns the first protocol from the list that the peer supports.
    ///
    /// - Parameters:
    ///   - protocols: The protocols to check (in priority order).
    ///   - peer: The peer to check against.
    /// - Returns: The first supported protocol, or nil.
    func firstSupportedProtocol(_ protocols: [String], for peer: PeerID) async -> String?

    /// Removes all protocol data for a peer.
    ///
    /// - Parameter peer: The peer to remove.
    func removePeer(_ peer: PeerID) async

    /// Returns all peers that support a given protocol.
    ///
    /// - Parameter protocolID: The protocol to search for.
    /// - Returns: Array of peers supporting that protocol.
    func peers(supporting protocolID: String) async -> [PeerID]
}
