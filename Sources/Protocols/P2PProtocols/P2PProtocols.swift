/// P2PProtocols - Protocol service abstractions for swift-libp2p
///
/// Provides the base protocol for implementing libp2p application protocols.

import P2PCore
import P2PMux

/// A protocol service that can be attached to a Node.
///
/// Protocol services implement specific libp2p protocols like Identify or Ping.
/// They register handlers with the node and can actively initiate protocol exchanges.
public protocol ProtocolService: Sendable {
    /// The protocol IDs this service handles.
    var protocolIDs: [String] { get }
}

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

    /// Creates a new stream context.
    public init(
        stream: MuxedStream,
        remotePeer: PeerID,
        remoteAddress: Multiaddr,
        localPeer: PeerID,
        localAddress: Multiaddr?
    ) {
        self.stream = stream
        self.remotePeer = remotePeer
        self.remoteAddress = remoteAddress
        self.localPeer = localPeer
        self.localAddress = localAddress
    }
}

/// Type alias for protocol handlers.
public typealias ProtocolHandler = @Sendable (StreamContext) async -> Void

/// Interface for registering protocol handlers.
///
/// This protocol allows services to register handlers without depending on the full Node type.
public protocol HandlerRegistry: Sendable {
    /// Registers a protocol handler.
    ///
    /// - Parameters:
    ///   - protocolID: The protocol identifier
    ///   - handler: The handler function
    func handle(_ protocolID: String, handler: @escaping ProtocolHandler) async
}

/// Optional capability for discovery services that need to register protocol handlers on Node.
public protocol NodeDiscoveryHandlerRegistrable: Sendable {
    /// Registers discovery-specific protocol handlers.
    func registerHandler(registry: any HandlerRegistry) async
}

/// Optional capability for discovery services that can be started directly by Node.
public protocol NodeDiscoveryStartable: Sendable {
    /// Starts internal background work required by discovery.
    func start() async
}

/// Optional capability for discovery services that require a stream opener from Node.
public protocol NodeDiscoveryStartableWithOpener: Sendable {
    /// Starts discovery and stores the stream opener for outbound protocol streams.
    func start(using opener: any StreamOpener) async
}

/// Optional capability for discovery services that maintain a per-peer protocol stream.
public protocol NodeDiscoveryPeerStreamService: Sendable {
    /// Protocol ID used when Node opens a peer stream for discovery integration.
    var discoveryProtocolID: String { get }

    /// Called when Node established a discovery protocol stream to a connected peer.
    func handlePeerConnected(_ peerID: PeerID, stream: MuxedStream) async

    /// Called when Node considers a peer disconnected from discovery.
    func handlePeerDisconnected(_ peerID: PeerID) async
}

/// Protocol services that receive peer lifecycle notifications from Node.
///
/// Implement this protocol to be notified when peers connect or disconnect.
/// Used by services like IdentifyService for auto-push functionality.
public protocol NodeProtocolPeerObserver: Sendable {
    /// Called when a new peer connection is established.
    func peerConnected(_ peer: PeerID)

    /// Called when a peer connection is closed.
    func peerDisconnected(_ peer: PeerID)
}

/// Common protocol IDs used in libp2p.
public enum LibP2PProtocol {
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
