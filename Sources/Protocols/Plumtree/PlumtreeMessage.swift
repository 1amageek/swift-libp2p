/// PlumtreeMessage - Message types for the Plumtree protocol
import Foundation
import P2PCore

/// The Plumtree protocol identifier.
public let plumtreeProtocolID = "/plumtree/1.0.0"

// MARK: - Message ID

/// A unique identifier for a Plumtree message.
///
/// Computed from the source PeerID and a sequence number to ensure
/// deterministic deduplication across the network.
public struct PlumtreeMessageID: Hashable, Sendable, CustomStringConvertible {
    /// The raw bytes of the message ID.
    public let bytes: Data

    /// Creates a message ID from raw bytes.
    public init(bytes: Data) {
        self.bytes = bytes
    }

    /// Computes a message ID from source peer and sequence number.
    public static func compute(source: PeerID, sequenceNumber: UInt64) -> PlumtreeMessageID {
        var data = source.bytes
        withUnsafeBytes(of: sequenceNumber.bigEndian) { data.append(contentsOf: $0) }
        return PlumtreeMessageID(bytes: data)
    }

    public var description: String {
        bytes.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Gossip Payload

/// A full message payload sent via eager push.
public struct PlumtreeGossip: Sendable {
    /// The unique message identifier.
    public let messageID: PlumtreeMessageID

    /// The topic this message belongs to.
    public let topic: String

    /// The message payload data.
    public let data: Data

    /// The original publisher's peer ID.
    public let source: PeerID

    /// Number of hops from the original publisher.
    public let hopCount: UInt32

    /// Creates a new gossip payload.
    public init(
        messageID: PlumtreeMessageID,
        topic: String,
        data: Data,
        source: PeerID,
        hopCount: UInt32
    ) {
        self.messageID = messageID
        self.topic = topic
        self.data = data
        self.source = source
        self.hopCount = hopCount
    }
}

// MARK: - IHave Entry

/// A lazy push notification indicating availability of a message.
public struct PlumtreeIHaveEntry: Sendable, Hashable {
    /// The message ID being advertised.
    public let messageID: PlumtreeMessageID

    /// The topic of the advertised message.
    public let topic: String

    /// Creates a new IHave entry.
    public init(messageID: PlumtreeMessageID, topic: String) {
        self.messageID = messageID
        self.topic = topic
    }
}

// MARK: - Graft Request

/// A request to promote the sender to the eager set.
///
/// Sent when an IHave timeout fires, requesting the peer to
/// start forwarding full messages and optionally re-send a specific message.
public struct PlumtreeGraftRequest: Sendable {
    /// The topic to graft for.
    public let topic: String

    /// An optional message ID to request re-send of.
    public let messageID: PlumtreeMessageID?

    /// Creates a new graft request.
    public init(topic: String, messageID: PlumtreeMessageID? = nil) {
        self.topic = topic
        self.messageID = messageID
    }
}

// MARK: - Prune Request

/// A request to demote the sender to the lazy set.
///
/// Sent when a duplicate message is received from a peer,
/// indicating the tree link should be removed.
public struct PlumtreePruneRequest: Sendable {
    /// The topic to prune for.
    public let topic: String

    /// Creates a new prune request.
    public init(topic: String) {
        self.topic = topic
    }
}

// MARK: - RPC Envelope

/// A batched wire message containing multiple Plumtree operations.
///
/// Similar to GossipSub's RPC, this envelope allows batching multiple
/// operations in a single network message.
public struct PlumtreeRPC: Sendable {
    /// Full messages for eager push.
    public var gossipMessages: [PlumtreeGossip]

    /// IHave notifications for lazy push.
    public var ihaveEntries: [PlumtreeIHaveEntry]

    /// Graft requests (promote to eager).
    public var graftRequests: [PlumtreeGraftRequest]

    /// Prune requests (demote to lazy).
    public var pruneRequests: [PlumtreePruneRequest]

    /// Whether this RPC is empty.
    public var isEmpty: Bool {
        gossipMessages.isEmpty && ihaveEntries.isEmpty &&
        graftRequests.isEmpty && pruneRequests.isEmpty
    }

    /// Creates an empty RPC.
    public init(
        gossipMessages: [PlumtreeGossip] = [],
        ihaveEntries: [PlumtreeIHaveEntry] = [],
        graftRequests: [PlumtreeGraftRequest] = [],
        pruneRequests: [PlumtreePruneRequest] = []
    ) {
        self.gossipMessages = gossipMessages
        self.ihaveEntries = ihaveEntries
        self.graftRequests = graftRequests
        self.pruneRequests = pruneRequests
    }
}
