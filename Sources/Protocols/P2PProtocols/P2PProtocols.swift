/// P2PProtocols - Protocol service abstractions for swift-libp2p
///
/// Provides the base protocol for implementing libp2p application protocols.

import P2PCore
import P2PMux
import P2PDiscovery

// MARK: - NodeService (Service Lifecycle)

/// Lifecycle interface for services managed by Node.
///
/// Base protocol for all services (protocol handlers, discovery, etc.).
/// Stream handling and peer event observation are separated into dedicated protocols.
public protocol NodeService: Sendable {
    /// Called during Node.start(). Store the NodeContext for later use.
    /// Called after listeners are up and addresses are resolved,
    /// so listenAddresses() returns valid values.
    func attach(to context: any NodeContext) async

    /// Called during Node.shutdown(). Clean up resources.
    /// All implementations must be async.
    func shutdown() async
}

extension NodeService {
    public func attach(to context: any NodeContext) async {}
}

// MARK: - StreamService (Inbound Stream Handling)

/// A service that handles inbound streams for specific protocol IDs.
///
/// Streams negotiated with any of the declared `protocolIDs` are
/// automatically routed to this service by Node.
public protocol StreamService: NodeService {
    /// The protocol IDs this service handles.
    var protocolIDs: [String] { get }

    /// Handles an inbound stream negotiated with one of the protocolIDs.
    func handleInboundStream(_ context: StreamContext) async
}

// MARK: - PeerObserver (Peer Lifecycle Events)

/// Observes peer connection and disconnection events.
///
/// Services that need to react to peer lifecycle events conform to this protocol.
/// Examples: GossipSub mesh management, Identify push notifications.
public protocol PeerObserver: Sendable {
    /// Called when a peer connects (first connection only, duplicates excluded).
    func peerConnected(_ peer: PeerID) async

    /// Called when a peer disconnects (only when no connections remain).
    func peerDisconnected(_ peer: PeerID) async
}

extension PeerObserver {
    public func peerDisconnected(_ peer: PeerID) async {}
}

// MARK: - DiscoveryBehaviour

/// A NodeService with discovery capabilities.
///
/// Node detects DiscoveryBehaviour conformance from the services array
/// and automatically configures auto-connect.
public protocol DiscoveryBehaviour: NodeService, DiscoveryService {}

// MARK: - NodeContext

/// Context provided to services by Node.
///
/// サービスが必要とする Node の機能を抽象化する。
/// IdentifyService が必要とする keyPair/listenAddresses/supportedProtocols も
/// GossipSub が必要とする StreamOpener も、この 1 つのインターフェースで提供する。
public protocol NodeContext: StreamOpener, Sendable {
    /// ローカルピアの ID。
    var localPeer: PeerID { get }

    /// ローカルピアの鍵ペア。
    var localKeyPair: KeyPair { get }

    /// 現在のリッスンアドレス（解決済み）。
    func listenAddresses() async -> [Multiaddr]

    /// サポートしているプロトコル ID 一覧。
    func supportedProtocols() async -> [String]

    /// ピアストア（アドレス管理、観測アドレス更新等）。
    var peerStore: any PeerStore { get async }
}

// MARK: - StreamOpener

/// Interface for opening streams to peers.
///
/// This protocol allows services to open streams without depending on the full Node type.
public protocol StreamOpener: Sendable {
    /// Opens a new stream to a peer with the given protocol.
    ///
    /// - Parameters:
    ///   - peer: The peer to open a stream to
    ///   - protocolID: The protocol to negotiate
    /// - Returns: The negotiated stream
    func newStream(to peer: PeerID, protocol protocolID: String) async throws -> MuxedStream
}

/// Context provided to protocol handlers.
///
/// Contains the stream and connection metadata needed for protocol handling.
public struct StreamContext: Sendable {
    /// The multiplexed stream.
    public let stream: MuxedStream

    /// The remote peer ID.
    public let remotePeer: PeerID

    /// The remote address.
    public let remoteAddress: Multiaddr

    /// The local peer ID.
    public let localPeer: PeerID

    /// The local address (if known).
    public let localAddress: Multiaddr?

    /// The negotiated protocol ID.
    public let protocolID: String

    /// Creates a new stream context.
    public init(
        stream: MuxedStream,
        remotePeer: PeerID,
        remoteAddress: Multiaddr,
        localPeer: PeerID,
        localAddress: Multiaddr?,
        protocolID: String
    ) {
        self.stream = stream
        self.remotePeer = remotePeer
        self.remoteAddress = remoteAddress
        self.localPeer = localPeer
        self.localAddress = localAddress
        self.protocolID = protocolID
    }
}

/// Type alias for protocol handlers.
public typealias ProtocolHandler = @Sendable (StreamContext) async -> Void

// MARK: - Protocol Constants

/// Common protocol IDs used in libp2p.
public enum ProtocolID {
    /// Identify protocol for peer information exchange.
    public static let identify = "/ipfs/id/1.0.0"

    /// Identify push protocol for broadcasting updates.
    public static let identifyPush = "/ipfs/id/push/1.0.0"

    /// Ping protocol for connection liveness checking.
    public static let ping = "/ipfs/ping/1.0.0"

    /// Circuit Relay v2 Hop protocol (client-to-relay).
    public static let circuitRelayHop = "/libp2p/circuit/relay/0.2.0/hop"

    /// Circuit Relay v2 Stop protocol (relay-to-target).
    public static let circuitRelayStop = "/libp2p/circuit/relay/0.2.0/stop"

    /// DCUtR protocol for hole punching coordination.
    public static let dcutr = "/libp2p/dcutr"

    /// AutoNAT protocol for NAT detection.
    public static let autonat = "/libp2p/autonat/1.0.0"

    /// Kademlia DHT protocol.
    public static let kademlia = "/ipfs/kad/1.0.0"
}
