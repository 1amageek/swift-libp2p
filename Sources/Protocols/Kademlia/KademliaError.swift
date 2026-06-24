/// KademliaError - Error types for Kademlia DHT.

import Foundation
import P2PCore

/// Errors that can occur during Kademlia operations.
public enum KademliaError: Error, Sendable, Equatable {
    /// Protocol violation (unexpected message format or sequence).
    case protocolViolation(String)

    /// Query timeout.
    case timeout

    /// No peers available for query.
    case noPeersAvailable

    /// Record not found.
    case recordNotFound

    /// Invalid record (failed validation).
    case invalidRecord(String)

    /// Query failed.
    case queryFailed(String)

    /// Routing table is empty.
    case emptyRoutingTable

    /// Maximum query depth exceeded.
    case maxDepthExceeded

    /// Peer not found.
    case peerNotFound(PeerID)

    /// Provider not found.
    case providerNotFound

    /// Encoding error.
    case encodingError(String)

    /// A storage backend is full and cannot accept a new entry.
    case storeFull(String)

    /// A storage backend operation failed.
    case storeFailed(String)

    /// A record's value exceeds the storage backend's per-value byte cap.
    /// Self-defending bound against an attacker-supplied oversized DHT value
    /// exhausting memory/disk.
    case recordTooLarge(valueBytes: Int, limit: Int)
}
