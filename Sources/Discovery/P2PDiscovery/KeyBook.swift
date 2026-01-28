/// P2PDiscovery - KeyBook
///
/// Per-peer public key storage with PeerID verification.
/// Go-compatible: PubKey (with PeerID extraction fallback), AddPubKey (with verification).

import P2PCore

// MARK: - KeyBook Protocol

/// Protocol for storing per-peer public keys.
///
/// KeyBook manages public key storage with PeerID verification.
/// When a key is not explicitly stored, it can be extracted from
/// identity-encoded PeerIDs as a fallback.
public protocol KeyBook: Sendable {

    /// Returns the public key for a peer.
    ///
    /// Attempts extraction from identity-encoded PeerID if not stored.
    ///
    /// - Parameter peer: The peer to look up.
    /// - Returns: The public key, or nil if not available.
    func publicKey(for peer: PeerID) async -> PublicKey?

    /// Stores a public key for a peer.
    ///
    /// Verifies that the key derives to the expected PeerID before storing.
    ///
    /// - Parameters:
    ///   - key: The public key to store.
    ///   - peer: The expected peer ID.
    /// - Throws: `KeyBookError.peerIDMismatch` if the key doesn't match.
    func setPublicKey(_ key: PublicKey, for peer: PeerID) async throws

    /// Removes the stored public key for a peer.
    ///
    /// - Parameter peer: The peer whose key to remove.
    func removePublicKey(for peer: PeerID) async

    /// Removes all key data for a peer.
    ///
    /// - Parameter peer: The peer to remove.
    func removePeer(_ peer: PeerID) async

    /// Returns all peers with stored public keys.
    func peersWithKeys() async -> [PeerID]
}

// MARK: - KeyBookError

/// Errors related to KeyBook operations.
public enum KeyBookError: Error, Sendable, Equatable {

    /// The stored key does not derive to the expected PeerID.
    case peerIDMismatch(expected: PeerID, derived: PeerID)
}
