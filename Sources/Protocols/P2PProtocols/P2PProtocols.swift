/// P2PProtocols - Protocol service abstractions for swift-libp2p
///
/// Provides the base protocol for implementing libp2p application protocols.

import P2PCore
import P2PMux
import P2PDiscovery

// MARK: - LifecycleService

/// Lifecycle interface for runtime-managed services.
///
/// Shutdown is a separate role from stream handling, peer observation, or
/// listen-address contribution. Services opt into lifecycle management
/// explicitly instead of inheriting it through unrelated capability protocols.
public protocol LifecycleService: Sendable {
    func shutdown() async throws
}

// MARK: - StreamService (Inbound Stream Handling)

/// A service that handles inbound streams for specific protocol IDs.
///
/// Streams negotiated with any of the declared `protocolIDs` are
/// automatically routed to this service by Node.
public protocol StreamService: Sendable {
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

/// A service that contributes additional listen addresses to Node.
///
/// This is used for features such as relays that can advertise derived or
/// externally reachable addresses in addition to the underlying transport
/// listener addresses.
public protocol ListenAddressContributor: Sendable {
    func setListenAddressCallback(
        _ callback: @escaping @Sendable ([Multiaddr]) async -> Void
    )
}

/// Identity information exposed to services.
public protocol NodeIdentityContext: Sendable {
    /// ローカルピアの ID。
    var localPeer: PeerID { get }

    /// ローカルピアの鍵ペア。
    var localKeyPair: KeyPair { get }
}

/// Listen address access exposed to services.
public protocol ListenAddressContext: Sendable {
    /// 現在のリッスンアドレス（解決済み）。
    func listenAddresses() async -> [Multiaddr]
}

/// Supported protocol catalog exposed to services.
public protocol SupportedProtocolsContext: Sendable {
    /// サポートしているプロトコル ID 一覧。
    func supportedProtocols() async -> [String]
}

/// Peer store access exposed to services.
public protocol PeerStoreContext: Sendable {
    /// ピアストア（アドレス管理、観測アドレス更新等）。
    var peerStore: any PeerStore { get async }
}

/// Address dialing capability exposed to services that need direct outbound dials.
public protocol AddressDialer: Sendable {
    func connect(to address: Multiaddr) async throws -> PeerID
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

/// Capability protocol for services that receive stream opening capability at startup.
///
/// This is the pure injection role used by components that need a `StreamOpener`
/// but do not have a distinct activation phase.
public protocol StreamOpeningConsumer: Sendable {
    func attachStreamOpening(_ opener: any StreamOpener) async
}

/// Capability protocol for services that need local identity injected at startup.
public protocol LocalIdentityConsumer: Sendable {
    func attachIdentityContext(_ context: any NodeIdentityContext) async
}

/// Capability protocol for services that need listen addresses injected at startup.
public protocol ListenAddressConsumer: Sendable {
    func attachListenAddressContext(_ context: any ListenAddressContext) async
}

/// Capability protocol for services that need supported protocol metadata at startup.
public protocol SupportedProtocolsConsumer: Sendable {
    func attachSupportedProtocolsContext(_ context: any SupportedProtocolsContext) async
}

/// Capability protocol for services that expose a start-up activation phase.
public protocol ActivatableService: Sendable {
    func activate() async
}

/// Capability protocol for components that need a stream opener at activation time.
///
/// This is more specific than a two-step `attach` + `activate` sequence and lets
/// the composition root express "start this runtime role with stream opening"
/// as a single operation.
public protocol StreamOpeningActivatable: Sendable {
    func activate(using opener: any StreamOpener) async
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
