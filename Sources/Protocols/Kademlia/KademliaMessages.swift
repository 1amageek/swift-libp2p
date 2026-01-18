/// KademliaMessages - Message types for Kademlia DHT protocol.

import Foundation
import P2PCore

/// Message type for Kademlia protocol.
public enum KademliaMessageType: UInt32, Sendable {
    case putValue = 0
    case getValue = 1
    case addProvider = 2
    case getProviders = 3
    case findNode = 4
    case ping = 5  // Deprecated
}

/// Connection type for a peer.
public enum KademliaPeerConnectionType: UInt32, Sendable {
    case notConnected = 0
    case connected = 1
    case canConnect = 2
    case cannotConnect = 3
}

/// Peer information in Kademlia messages.
public struct KademliaPeer: Sendable, Equatable {
    /// The peer ID.
    public let id: PeerID

    /// The peer's addresses.
    public let addresses: [Multiaddr]

    /// Connection status.
    public let connectionType: KademliaPeerConnectionType

    /// Creates peer info.
    public init(
        id: PeerID,
        addresses: [Multiaddr] = [],
        connectionType: KademliaPeerConnectionType = .notConnected
    ) {
        self.id = id
        self.addresses = addresses
        self.connectionType = connectionType
    }
}

/// A record stored in the DHT.
public struct KademliaRecord: Sendable, Equatable {
    /// The record key.
    public let key: Data

    /// The record value.
    public let value: Data

    /// Timestamp when the record was received (ISO 8601 string).
    public let timeReceived: String?

    /// Creates a record.
    public init(key: Data, value: Data, timeReceived: String? = nil) {
        self.key = key
        self.value = value
        self.timeReceived = timeReceived
    }

    /// Creates a record with current timestamp.
    public static func create(key: Data, value: Data) -> KademliaRecord {
        let formatter = ISO8601DateFormatter()
        let timestamp = formatter.string(from: Date())
        return KademliaRecord(key: key, value: value, timeReceived: timestamp)
    }
}

/// Kademlia DHT message.
public struct KademliaMessage: Sendable {
    /// The message type.
    public let type: KademliaMessageType

    /// The key (for lookups).
    public let key: Data?

    /// The record (for PUT_VALUE/GET_VALUE).
    public let record: KademliaRecord?

    /// Closer peers (in response).
    public let closerPeers: [KademliaPeer]

    /// Provider peers (for provider operations).
    public let providerPeers: [KademliaPeer]

    /// Creates a message.
    private init(
        type: KademliaMessageType,
        key: Data? = nil,
        record: KademliaRecord? = nil,
        closerPeers: [KademliaPeer] = [],
        providerPeers: [KademliaPeer] = []
    ) {
        self.type = type
        self.key = key
        self.record = record
        self.closerPeers = closerPeers
        self.providerPeers = providerPeers
    }

    // MARK: - Factory Methods

    /// Creates a FIND_NODE request.
    public static func findNode(key: Data) -> KademliaMessage {
        KademliaMessage(type: .findNode, key: key)
    }

    /// Creates a FIND_NODE response.
    public static func findNodeResponse(closerPeers: [KademliaPeer]) -> KademliaMessage {
        KademliaMessage(type: .findNode, closerPeers: closerPeers)
    }

    /// Creates a GET_VALUE request.
    public static func getValue(key: Data) -> KademliaMessage {
        KademliaMessage(type: .getValue, key: key)
    }

    /// Creates a GET_VALUE response.
    public static func getValueResponse(
        record: KademliaRecord?,
        closerPeers: [KademliaPeer]
    ) -> KademliaMessage {
        KademliaMessage(type: .getValue, record: record, closerPeers: closerPeers)
    }

    /// Creates a PUT_VALUE request.
    public static func putValue(record: KademliaRecord) -> KademliaMessage {
        KademliaMessage(type: .putValue, key: record.key, record: record)
    }

    /// Creates a PUT_VALUE response (echoes the request).
    public static func putValueResponse(record: KademliaRecord) -> KademliaMessage {
        KademliaMessage(type: .putValue, key: record.key, record: record)
    }

    /// Creates an ADD_PROVIDER request.
    public static func addProvider(key: Data, providers: [KademliaPeer]) -> KademliaMessage {
        KademliaMessage(type: .addProvider, key: key, providerPeers: providers)
    }

    /// Creates a GET_PROVIDERS request.
    public static func getProviders(key: Data) -> KademliaMessage {
        KademliaMessage(type: .getProviders, key: key)
    }

    /// Creates a GET_PROVIDERS response.
    public static func getProvidersResponse(
        providers: [KademliaPeer],
        closerPeers: [KademliaPeer]
    ) -> KademliaMessage {
        KademliaMessage(type: .getProviders, closerPeers: closerPeers, providerPeers: providers)
    }
}
