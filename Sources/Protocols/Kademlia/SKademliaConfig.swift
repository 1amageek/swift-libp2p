/// SKademliaConfig - S/Kademlia (Secure Kademlia) configuration
///
/// S/Kademlia extends standard Kademlia with security features to resist
/// Sybil and Eclipse attacks:
/// - Cryptographic node ID validation
/// - Sibling broadcast for redundancy
/// - Disjoint paths for query robustness

import Foundation
import P2PCore

/// S/Kademlia security configuration.
public struct SKademliaConfig: Sendable {
    /// Whether to enable S/Kademlia security features.
    public var enabled: Bool

    /// Whether to validate that node IDs are cryptographically derived from public keys.
    ///
    /// When enabled, peers must provide a public key, and the peer ID must match
    /// the cryptographic hash of that key. This prevents attackers from choosing
    /// arbitrary node IDs to position themselves strategically in the DHT.
    public var validateNodeIDs: Bool

    /// Whether to use sibling broadcast.
    ///
    /// Sibling broadcast sends queries to multiple peers in the same k-bucket,
    /// providing redundancy against malicious nodes and improving query success rate.
    public var useSiblingBroadcast: Bool

    /// Number of siblings to query in parallel (only used if `useSiblingBroadcast` is true).
    ///
    /// Typical values: 1-3. Higher values provide more redundancy but increase bandwidth.
    public var siblingCount: Int

    /// Whether to use disjoint paths for queries.
    ///
    /// Disjoint paths execute queries along multiple independent routes through the DHT,
    /// making it harder for an attacker to intercept or manipulate query results.
    public var useDisjointPaths: Bool

    /// Number of disjoint paths to use (only used if `useDisjointPaths` is true).
    ///
    /// Typical values: 2-4. More paths provide better Eclipse attack resistance
    /// but increase query overhead.
    public var disjointPathCount: Int

    /// Creates a new S/Kademlia configuration.
    ///
    /// - Parameters:
    ///   - enabled: Whether S/Kademlia features are enabled (default: false for backward compatibility)
    ///   - validateNodeIDs: Whether to validate node ID cryptographic derivation (default: true when enabled)
    ///   - useSiblingBroadcast: Whether to use sibling broadcast (default: true when enabled)
    ///   - siblingCount: Number of siblings to query (default: 2)
    ///   - useDisjointPaths: Whether to use disjoint paths (default: true when enabled)
    ///   - disjointPathCount: Number of disjoint paths (default: 2)
    public init(
        enabled: Bool = false,
        validateNodeIDs: Bool = true,
        useSiblingBroadcast: Bool = true,
        siblingCount: Int = 2,
        useDisjointPaths: Bool = true,
        disjointPathCount: Int = 2
    ) {
        self.enabled = enabled
        self.validateNodeIDs = validateNodeIDs && enabled
        self.useSiblingBroadcast = useSiblingBroadcast && enabled
        self.siblingCount = max(1, siblingCount)
        self.useDisjointPaths = useDisjointPaths && enabled
        self.disjointPathCount = max(2, disjointPathCount)
    }

    /// Standard S/Kademlia configuration (all security features enabled).
    public static let standard = SKademliaConfig(enabled: true)

    /// Disabled S/Kademlia (standard Kademlia behavior).
    public static let disabled = SKademliaConfig(enabled: false)
}

/// Node ID validation utilities for S/Kademlia.
public enum SKademliaValidator {
    /// Validates that a peer ID is cryptographically derived from a public key.
    ///
    /// - Parameters:
    ///   - peerID: The peer ID to validate
    ///   - publicKey: The public key to validate against
    /// - Returns: true if the peer ID matches the key's hash, false otherwise
    public static func validateNodeID(_ peerID: PeerID, publicKey: PublicKey) -> Bool {
        // PeerID should match the public key
        return peerID == publicKey.peerID
    }

    /// Checks if a peer ID appears to be cryptographically secure.
    ///
    /// This is a heuristic check when the public key is not available.
    /// In S/Kademlia, all node IDs should be derived from public keys.
    ///
    /// - Parameter peerID: The peer ID to check
    /// - Returns: true if the peer ID format suggests cryptographic derivation
    public static func isSecureNodeID(_ peerID: PeerID) -> Bool {
        // libp2p peer IDs derived from public keys start with specific multihash prefixes
        // For now, we assume all peer IDs are potentially secure
        // A more robust check would verify the multihash header
        return true
    }
}
