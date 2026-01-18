/// ConnectionGater - Connection filtering protocol
///
/// Provides hooks to accept or reject connections at various stages.

import Foundation
import Synchronization
import P2PCore

/// A protocol for filtering connections at various stages.
///
/// Connection gating allows you to reject connections based on
/// custom criteria at different points in the connection lifecycle.
///
/// ## Gating Stages
///
/// 1. **interceptDial**: Before initiating an outbound connection
/// 2. **interceptAccept**: When receiving an inbound connection (before upgrade)
/// 3. **interceptSecured**: After security handshake completes (peer ID known)
///
/// ## Example
/// ```swift
/// struct MyGater: ConnectionGater {
///     func interceptDial(peer: PeerID?, address: Multiaddr) -> Bool {
///         // Reject connections to certain addresses
///         return !bannedAddresses.contains(address)
///     }
///
///     func interceptAccept(address: Multiaddr) -> Bool { true }
///     func interceptSecured(peer: PeerID, direction: ConnectionDirection) -> Bool { true }
/// }
/// ```
public protocol ConnectionGater: Sendable {

    /// Called before dialing a remote peer.
    ///
    /// - Parameters:
    ///   - peer: The peer ID if known from the address (may be nil)
    ///   - address: The address being dialed
    /// - Returns: `true` to allow the dial, `false` to reject
    func interceptDial(peer: PeerID?, address: Multiaddr) -> Bool

    /// Called when accepting an inbound connection.
    ///
    /// This is called before any upgrade (security, muxer) is performed.
    ///
    /// - Parameter address: The remote address of the incoming connection
    /// - Returns: `true` to accept, `false` to reject
    func interceptAccept(address: Multiaddr) -> Bool

    /// Called after security handshake completes.
    ///
    /// At this point, the remote peer's identity has been verified.
    /// This is the final gating check before the connection is fully established.
    ///
    /// - Parameters:
    ///   - peer: The authenticated peer ID
    ///   - direction: Whether this is an inbound or outbound connection
    /// - Returns: `true` to allow, `false` to reject and close the connection
    func interceptSecured(peer: PeerID, direction: ConnectionDirection) -> Bool
}

// MARK: - AllowAllGater

/// A gater that allows all connections.
///
/// This is the default gater when no custom filtering is needed.
public struct AllowAllGater: ConnectionGater {

    /// Creates a new allow-all gater.
    public init() {}

    public func interceptDial(peer: PeerID?, address: Multiaddr) -> Bool {
        true
    }

    public func interceptAccept(address: Multiaddr) -> Bool {
        true
    }

    public func interceptSecured(peer: PeerID, direction: ConnectionDirection) -> Bool {
        true
    }
}

// MARK: - BlocklistGater

/// A gater that blocks specific peers and addresses.
///
/// Thread-safe implementation using Mutex for concurrent access.
///
/// ## Example
/// ```swift
/// let gater = BlocklistGater()
/// gater.block(peer: maliciousPeerID)
/// gater.block(address: "192.168.1.100")
/// ```
public final class BlocklistGater: ConnectionGater, Sendable {

    /// Blocked peer IDs.
    private let blockedPeers: Mutex<Set<PeerID>>

    /// Blocked address strings (IP addresses or full multiaddr strings).
    private let blockedAddresses: Mutex<Set<String>>

    /// Creates a new blocklist gater.
    public init() {
        self.blockedPeers = Mutex([])
        self.blockedAddresses = Mutex([])
    }

    /// Creates a new blocklist gater with initial blocked items.
    ///
    /// - Parameters:
    ///   - peers: Initial set of blocked peers
    ///   - addresses: Initial set of blocked addresses
    public init(peers: Set<PeerID> = [], addresses: Set<String> = []) {
        self.blockedPeers = Mutex(peers)
        self.blockedAddresses = Mutex(addresses)
    }

    // MARK: - Peer Blocking

    /// Blocks a peer.
    ///
    /// - Parameter peer: The peer to block
    public func block(peer: PeerID) {
        _ = blockedPeers.withLock { $0.insert(peer) }
    }

    /// Unblocks a peer.
    ///
    /// - Parameter peer: The peer to unblock
    public func unblock(peer: PeerID) {
        _ = blockedPeers.withLock { $0.remove(peer) }
    }

    /// Checks if a peer is blocked.
    ///
    /// - Parameter peer: The peer to check
    /// - Returns: `true` if the peer is blocked
    public func isBlocked(peer: PeerID) -> Bool {
        blockedPeers.withLock { $0.contains(peer) }
    }

    // MARK: - Address Blocking

    /// Blocks an address.
    ///
    /// - Parameter address: The address string to block (IP or multiaddr)
    public func block(address: String) {
        _ = blockedAddresses.withLock { $0.insert(address) }
    }

    /// Unblocks an address.
    ///
    /// - Parameter address: The address string to unblock
    public func unblock(address: String) {
        _ = blockedAddresses.withLock { $0.remove(address) }
    }

    /// Checks if an address is blocked.
    ///
    /// - Parameter address: The address string to check
    /// - Returns: `true` if the address is blocked
    public func isBlocked(address: String) -> Bool {
        blockedAddresses.withLock { $0.contains(address) }
    }

    // MARK: - Bulk Operations

    /// Returns all blocked peers.
    public var allBlockedPeers: Set<PeerID> {
        blockedPeers.withLock { $0 }
    }

    /// Returns all blocked addresses.
    public var allBlockedAddresses: Set<String> {
        blockedAddresses.withLock { $0 }
    }

    /// Clears all blocked peers.
    public func clearBlockedPeers() {
        blockedPeers.withLock { $0.removeAll() }
    }

    /// Clears all blocked addresses.
    public func clearBlockedAddresses() {
        blockedAddresses.withLock { $0.removeAll() }
    }

    /// Clears all blocklists.
    public func clearAll() {
        clearBlockedPeers()
        clearBlockedAddresses()
    }

    // MARK: - ConnectionGater

    public func interceptDial(peer: PeerID?, address: Multiaddr) -> Bool {
        // Check peer blocklist
        if let peer = peer {
            if blockedPeers.withLock({ $0.contains(peer) }) {
                return false
            }
        }

        // Check address blocklist
        let addrString = address.description
        return !blockedAddresses.withLock { blocked in
            blocked.contains(addrString) || blocked.contains(where: { addrString.contains($0) })
        }
    }

    public func interceptAccept(address: Multiaddr) -> Bool {
        let addrString = address.description
        return !blockedAddresses.withLock { blocked in
            blocked.contains(addrString) || blocked.contains(where: { addrString.contains($0) })
        }
    }

    public func interceptSecured(peer: PeerID, direction: ConnectionDirection) -> Bool {
        !blockedPeers.withLock { $0.contains(peer) }
    }
}

// MARK: - CompositeGater

/// A gater that combines multiple gaters.
///
/// All gaters must allow a connection for it to be accepted.
public struct CompositeGater: ConnectionGater {

    /// The list of gaters to check.
    private let gaters: [any ConnectionGater]

    /// Creates a composite gater from multiple gaters.
    ///
    /// - Parameter gaters: The gaters to combine (all must allow)
    public init(_ gaters: [any ConnectionGater]) {
        self.gaters = gaters
    }

    /// Creates a composite gater from multiple gaters.
    ///
    /// - Parameter gaters: The gaters to combine (all must allow)
    public init(_ gaters: any ConnectionGater...) {
        self.gaters = gaters
    }

    public func interceptDial(peer: PeerID?, address: Multiaddr) -> Bool {
        gaters.allSatisfy { $0.interceptDial(peer: peer, address: address) }
    }

    public func interceptAccept(address: Multiaddr) -> Bool {
        gaters.allSatisfy { $0.interceptAccept(address: address) }
    }

    public func interceptSecured(peer: PeerID, direction: ConnectionDirection) -> Bool {
        gaters.allSatisfy { $0.interceptSecured(peer: peer, direction: direction) }
    }
}
