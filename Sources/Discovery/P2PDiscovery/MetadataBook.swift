/// P2PDiscovery - MetadataBook
///
/// Per-peer metadata storage. Stores arbitrary typed metadata for each peer,
/// such as protocol version, agent version, latency measurements, etc.

import Foundation
import P2PCore
import Synchronization

// MARK: - Metadata Key

/// A typed key for metadata entries.
///
/// Each key has a string name and an associated value type that must be
/// both `Sendable` and `Codable`. Values are serialized to JSON for storage.
public struct MetadataKey<V: Sendable & Codable>: Sendable, Hashable {
    /// The string identifier for this key.
    public let name: String

    public init(_ name: String) {
        self.name = name
    }

    public static func == (lhs: MetadataKey, rhs: MetadataKey) -> Bool {
        lhs.name == rhs.name
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
    }
}

// MARK: - Well-Known Keys

extension MetadataKey where V == String {
    /// The protocol version reported by Identify.
    public static let protocolVersion = MetadataKey<String>("protocolVersion")
    /// The agent version reported by Identify.
    public static let agentVersion = MetadataKey<String>("agentVersion")
}

extension MetadataKey where V == Double {
    /// Measured latency in seconds.
    public static let latency = MetadataKey<Double>("latency")
}

// MARK: - Metadata Events

/// Events emitted by the MetadataBook.
public enum MetadataBookEvent: Sendable {
    /// Metadata was set for a peer.
    case metadataSet(PeerID, key: String)
    /// Metadata was removed for a peer.
    case metadataRemoved(PeerID, key: String)
    /// All metadata for a peer was removed.
    case peerRemoved(PeerID)
}

// MARK: - MetadataBook Protocol

/// Protocol for storing per-peer metadata.
///
/// MetadataBook provides typed key-value storage for arbitrary per-peer
/// information. Values are accessed through `MetadataKey<V>` which
/// provides compile-time type safety for stored values.
public protocol MetadataBook: Sendable {
    /// Gets a metadata value for a peer.
    ///
    /// - Parameters:
    ///   - key: The typed metadata key.
    ///   - peer: The peer to look up.
    /// - Returns: The stored value, or nil if not found or decoding fails.
    func get<V: Sendable & Codable>(_ key: MetadataKey<V>, for peer: PeerID) -> V?

    /// Sets a metadata value for a peer.
    ///
    /// - Parameters:
    ///   - key: The typed metadata key.
    ///   - value: The value to store.
    ///   - peer: The peer to associate the value with.
    func set<V: Sendable & Codable>(_ key: MetadataKey<V>, value: V, for peer: PeerID)

    /// Removes a specific metadata key for a peer.
    ///
    /// - Parameters:
    ///   - key: The key name to remove.
    ///   - peer: The peer to remove the key from.
    func remove(key: String, for peer: PeerID)

    /// Removes all metadata for a peer.
    ///
    /// - Parameter peer: The peer to remove all metadata for.
    func removePeer(_ peer: PeerID)

    /// Returns all metadata key names for a peer.
    ///
    /// - Parameter peer: The peer to look up.
    /// - Returns: Array of key names, empty if the peer has no metadata.
    func keys(for peer: PeerID) -> [String]

    /// Event stream (multi-consumer).
    ///
    /// Each access returns an independent subscriber stream.
    var events: AsyncStream<MetadataBookEvent> { get }

    /// Shuts down the metadata book, releasing all resources.
    func shutdown()
}
