/// KademliaEvent - Events emitted by the Kademlia DHT service.

import Foundation
import P2PCore

/// Events emitted by the Kademlia DHT service.
public enum KademliaEvent: Sendable {
    // MARK: - Routing Table Events

    /// A peer was added to the routing table.
    case peerAdded(PeerID, bucket: Int)

    /// A peer was removed from the routing table.
    case peerRemoved(PeerID, bucket: Int)

    /// A peer was updated in the routing table.
    case peerUpdated(PeerID)

    /// The routing table was refreshed.
    case routingTableRefreshed(peersAdded: Int, peersRemoved: Int)

    // MARK: - Query Events

    /// A query started.
    case queryStarted(QueryInfo)

    /// A query made progress.
    case queryProgress(QueryInfo, peersQueried: Int, peersFound: Int)

    /// A query completed successfully.
    case querySucceeded(QueryInfo, result: QueryResultInfo)

    /// A query failed.
    case queryFailed(QueryInfo, error: String)

    // MARK: - Record Events

    /// A record was stored locally.
    case recordStored(key: Data)

    /// A record was retrieved.
    case recordRetrieved(key: Data, from: PeerID?)

    /// A record was not found.
    case recordNotFound(key: Data)

    /// A record was republished.
    case recordRepublished(key: Data, toPeers: Int)

    /// A record was rejected by the validator.
    case recordRejected(key: Data, from: PeerID, reason: RecordRejectionReason)

    // MARK: - Provider Events

    /// Became a provider for content.
    case providerAdded(key: Data)

    /// No longer a provider for content.
    case providerRemoved(key: Data)

    /// Provider record was announced.
    case providerAnnounced(key: Data, toPeers: Int)

    /// Providers were found for content.
    case providersFound(key: Data, count: Int)

    // MARK: - Network Events

    /// Received a request from a peer.
    case requestReceived(from: PeerID, type: RequestType)

    /// Sent a response to a peer.
    case responseSent(to: PeerID, type: RequestType)

    /// Mode changed (server/client).
    case modeChanged(KademliaMode)

    /// Service started.
    case started

    /// Service stopped.
    case stopped

    // MARK: - Maintenance Events

    /// Background maintenance completed.
    case maintenanceCompleted(recordsRemoved: Int, providersRemoved: Int)
}

/// Information about a query.
public struct QueryInfo: Sendable, Equatable {
    /// Unique query ID.
    public let id: UUID

    /// The query type.
    public let type: QueryType

    /// The target key (hex string).
    public let targetKey: String

    /// When the query started.
    public let startTime: ContinuousClock.Instant

    /// Creates query info.
    public init(
        id: UUID = UUID(),
        type: QueryType,
        targetKey: KademliaKey
    ) {
        self.id = id
        self.type = type
        self.targetKey = targetKey.description
        self.startTime = .now
    }

    /// Query type.
    public enum QueryType: String, Sendable {
        case findNode = "FIND_NODE"
        case getValue = "GET_VALUE"
        case putValue = "PUT_VALUE"
        case getProviders = "GET_PROVIDERS"
        case addProvider = "ADD_PROVIDER"
    }
}

/// Information about a query result.
public enum QueryResultInfo: Sendable {
    /// Found peers.
    case peers(count: Int)

    /// Found a value.
    case value(from: PeerID)

    /// Value not found.
    case noValue(closestPeers: Int)

    /// Found providers.
    case providers(count: Int, closestPeers: Int)

    /// Successfully stored value.
    case stored(toPeers: Int)

    /// Successfully announced provider.
    case announced(toPeers: Int)
}

/// Type of request received.
public enum RequestType: String, Sendable {
    case findNode = "FIND_NODE"
    case getValue = "GET_VALUE"
    case putValue = "PUT_VALUE"
    case getProviders = "GET_PROVIDERS"
    case addProvider = "ADD_PROVIDER"
}

extension KademliaEvent: CustomStringConvertible {
    public var description: String {
        switch self {
        case .peerAdded(let peer, let bucket):
            return "Peer added: \(peer) to bucket \(bucket)"
        case .peerRemoved(let peer, let bucket):
            return "Peer removed: \(peer) from bucket \(bucket)"
        case .peerUpdated(let peer):
            return "Peer updated: \(peer)"
        case .routingTableRefreshed(let added, let removed):
            return "Routing table refreshed: +\(added) -\(removed)"
        case .queryStarted(let info):
            return "Query started: \(info.type.rawValue) for \(info.targetKey)"
        case .queryProgress(let info, let queried, let found):
            return "Query progress: \(info.type.rawValue) queried=\(queried) found=\(found)"
        case .querySucceeded(let info, let result):
            return "Query succeeded: \(info.type.rawValue) -> \(result)"
        case .queryFailed(let info, let error):
            return "Query failed: \(info.type.rawValue) - \(error)"
        case .recordStored(let key):
            return "Record stored: \(key.prefix(8).map { String(format: "%02x", $0) }.joined())..."
        case .recordRetrieved(let key, let from):
            let keyStr = key.prefix(8).map { String(format: "%02x", $0) }.joined()
            if let peer = from {
                return "Record retrieved: \(keyStr)... from \(peer)"
            }
            return "Record retrieved: \(keyStr)... (local)"
        case .recordNotFound(let key):
            return "Record not found: \(key.prefix(8).map { String(format: "%02x", $0) }.joined())..."
        case .recordRepublished(let key, let peers):
            return "Record republished: \(key.prefix(8).map { String(format: "%02x", $0) }.joined())... to \(peers) peers"
        case .recordRejected(let key, let from, let reason):
            return "Record rejected: \(key.prefix(8).map { String(format: "%02x", $0) }.joined())... from \(from), reason: \(reason)"
        case .providerAdded(let key):
            return "Provider added: \(key.prefix(8).map { String(format: "%02x", $0) }.joined())..."
        case .providerRemoved(let key):
            return "Provider removed: \(key.prefix(8).map { String(format: "%02x", $0) }.joined())..."
        case .providerAnnounced(let key, let peers):
            return "Provider announced: \(key.prefix(8).map { String(format: "%02x", $0) }.joined())... to \(peers) peers"
        case .providersFound(let key, let count):
            return "Providers found: \(count) for \(key.prefix(8).map { String(format: "%02x", $0) }.joined())..."
        case .requestReceived(let from, let type):
            return "Request received: \(type.rawValue) from \(from)"
        case .responseSent(let to, let type):
            return "Response sent: \(type.rawValue) to \(to)"
        case .modeChanged(let mode):
            return "Mode changed: \(mode)"
        case .started:
            return "Kademlia service started"
        case .stopped:
            return "Kademlia service stopped"
        case .maintenanceCompleted(let recordsRemoved, let providersRemoved):
            return "Maintenance completed: \(recordsRemoved) records, \(providersRemoved) providers removed"
        }
    }
}

extension QueryResultInfo: CustomStringConvertible {
    public var description: String {
        switch self {
        case .peers(let count):
            return "found \(count) peers"
        case .value(let from):
            return "found value from \(from)"
        case .noValue(let closestPeers):
            return "no value, \(closestPeers) closest peers"
        case .providers(let count, let closestPeers):
            return "found \(count) providers, \(closestPeers) closest peers"
        case .stored(let toPeers):
            return "stored to \(toPeers) peers"
        case .announced(let toPeers):
            return "announced to \(toPeers) peers"
        }
    }
}
