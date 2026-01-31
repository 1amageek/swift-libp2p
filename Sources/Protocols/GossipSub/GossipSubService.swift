/// GossipSubService - Main service implementation for GossipSub protocol
import Foundation
import P2PCore
import P2PMux
import P2PProtocols
import Synchronization

private let logger = Logger(label: "p2p.gossipsub")

/// The main GossipSub service implementing the ProtocolService interface.
///
/// Provides a high-level API for pub/sub messaging using the GossipSub protocol.
///
/// ## Usage
///
/// ```swift
/// let gossipsub = GossipSubService(
///     localPeerID: myPeerID,
///     configuration: .init()
/// )
///
/// // Register handler with node
/// await gossipsub.registerHandler(registry: node)
///
/// // Subscribe to a topic
/// let subscription = try await gossipsub.subscribe(to: "my-topic")
///
/// // Receive messages
/// for await message in subscription.messages {
///     print("Received: \(message.data)")
/// }
///
/// // Publish a message
/// try await gossipsub.publish(data: myData, to: "my-topic", using: node)
/// ```
public final class GossipSubService: ProtocolService, Sendable {

    // MARK: - ProtocolService

    public var protocolIDs: [String] {
        GossipSubProtocolID.all
    }

    // MARK: - Properties

    /// The local peer ID.
    public let localPeerID: PeerID

    /// Configuration.
    public let configuration: GossipSubConfiguration

    /// The core router.
    private let router: GossipSubRouter

    /// Heartbeat manager.
    private let heartbeat: Mutex<HeartbeatManager?>

    /// Internal state.
    private let serviceState: Mutex<ServiceState>

    private struct ServiceState: Sendable {
        var isStarted: Bool = false
        var peerStreams: [PeerID: MuxedStream] = [:]
    }

    // MARK: - Initialization

    /// Creates a new GossipSub service with message signing support.
    ///
    /// This is the recommended initializer for production use.
    /// Messages will be signed using the provided key pair when `signMessages` is enabled.
    ///
    /// - Parameters:
    ///   - keyPair: The local key pair (provides both PeerID and signing key)
    ///   - configuration: Configuration parameters
    public init(
        keyPair: KeyPair,
        configuration: GossipSubConfiguration = .init()
    ) {
        self.localPeerID = keyPair.peerID
        self.configuration = configuration
        let signingKey = configuration.signMessages ? keyPair.privateKey : nil
        self.router = GossipSubRouter(
            localPeerID: keyPair.peerID,
            signingKey: signingKey,
            configuration: configuration
        )
        self.heartbeat = Mutex(nil)
        self.serviceState = Mutex(ServiceState())
    }

    /// Creates a new GossipSub service without signing support.
    ///
    /// Use this initializer only for testing or when message signing is disabled.
    ///
    /// - Parameters:
    ///   - localPeerID: The local peer ID
    ///   - configuration: Configuration parameters (must have `signMessages = false`)
    /// - Precondition: `configuration.signMessages` must be `false`
    public init(
        localPeerID: PeerID,
        configuration: GossipSubConfiguration = .testing
    ) {
        precondition(
            !configuration.signMessages,
            "signMessages requires KeyPair. Use init(keyPair:configuration:) instead."
        )
        self.localPeerID = localPeerID
        self.configuration = configuration
        self.router = GossipSubRouter(
            localPeerID: localPeerID,
            signingKey: nil,
            configuration: configuration
        )
        self.heartbeat = Mutex(nil)
        self.serviceState = Mutex(ServiceState())
    }

    // MARK: - Handler Registration

    /// Registers the GossipSub protocol handler.
    ///
    /// - Parameter registry: The handler registry to register with
    public func registerHandler(registry: any HandlerRegistry) async {
        // Register handler for all protocol versions
        for protocolID in protocolIDs {
            await registry.handle(protocolID) { [weak self] context in
                await self?.handleIncomingStream(context: context, protocolID: protocolID)
            }
        }
    }

    // MARK: - Lifecycle

    /// Starts the GossipSub service.
    public func start() {
        // Create heartbeat manager
        let hb = HeartbeatManager(
            router: router,
            configuration: configuration,
            sendCallback: { [weak self] peer, rpc in
                await self?.sendRPC(rpc, to: peer)
            }
        )
        heartbeat.withLock { $0 = hb }
        hb.start()

        serviceState.withLock { $0.isStarted = true }
    }

    /// Stops the GossipSub service.
    public func stop() {
        serviceState.withLock { $0.isStarted = false }

        heartbeat.withLock { hb in
            hb?.stop()
            hb = nil
        }

        router.shutdown()
    }

    /// Whether the service is started.
    public var isStarted: Bool {
        serviceState.withLock { $0.isStarted }
    }

    // MARK: - Event Stream

    /// Event stream for monitoring GossipSub events.
    public var events: AsyncStream<GossipSubEvent> {
        router.events
    }

    // MARK: - Subscription API

    /// Subscribes to a topic.
    ///
    /// - Parameter topic: The topic to subscribe to
    /// - Returns: A subscription for receiving messages
    public func subscribe(to topic: Topic) async throws -> Subscription {
        let subscription = try router.subscribe(to: topic)

        // Notify all connected peers about our subscription
        await notifySubscription(topic: topic, subscribe: true)

        return subscription
    }

    /// Subscribes to a topic by string.
    ///
    /// - Parameter topic: The topic string
    /// - Returns: A subscription for receiving messages
    public func subscribe(to topic: String) async throws -> Subscription {
        try await subscribe(to: Topic(topic))
    }

    /// Unsubscribes from a topic.
    ///
    /// - Parameter topic: The topic to unsubscribe from
    public func unsubscribe(from topic: Topic) async {
        // Unsubscribe and get mesh peers atomically
        let meshPeers = router.unsubscribe(from: topic)

        // Send PRUNE to former mesh peers and set local backoff
        for peer in meshPeers {
            // Set local backoff so we don't accept GRAFT from this peer
            router.peerState.updatePeer(peer) { state in
                state.setBackoff(for: topic, duration: configuration.pruneBackoff)
            }

            var rpc = GossipSubRPC()
            var control = ControlMessageBatch()
            control.prunes.append(ControlMessage.Prune(
                topic: topic,
                backoff: UInt64(configuration.pruneBackoff.components.seconds)
            ))
            rpc.control = control
            await sendRPC(rpc, to: peer)
        }

        // Notify all connected peers about our unsubscription
        await notifySubscription(topic: topic, subscribe: false)
    }

    /// Unsubscribes from a topic by string.
    ///
    /// - Parameter topic: The topic string
    public func unsubscribe(from topic: String) async {
        await unsubscribe(from: Topic(topic))
    }

    /// Notifies all connected peers about a subscription change.
    private func notifySubscription(topic: Topic, subscribe: Bool) async {
        var rpc = GossipSubRPC()
        if subscribe {
            rpc.subscriptions.append(.subscribe(to: topic))
        } else {
            rpc.subscriptions.append(.unsubscribe(from: topic))
        }

        // Send to all connected peers
        let peers = router.peerState.allPeers
        for peer in peers {
            await sendRPC(rpc, to: peer)
        }
    }

    /// Returns all subscribed topics.
    public var subscribedTopics: [Topic] {
        router.meshState.subscribedTopics
    }

    // MARK: - Publishing API

    /// Publishes data to a topic.
    ///
    /// - Parameters:
    ///   - data: The data to publish
    ///   - topic: The topic to publish to
    /// - Returns: The published message
    @discardableResult
    public func publish(data: Data, to topic: Topic) async throws -> GossipSubMessage {
        let message = try router.publish(data, to: topic)

        // Get peers to send to
        let peers = router.peersForPublish(topic: topic)

        // Build RPC
        let rpc = GossipSubRPC(messages: [message])

        // Send to all peers
        for peer in peers {
            await sendRPC(rpc, to: peer)
        }

        return message
    }

    /// Publishes data to a topic by string.
    ///
    /// - Parameters:
    ///   - data: The data to publish
    ///   - topic: The topic string
    /// - Returns: The published message
    @discardableResult
    public func publish(data: Data, to topic: String) async throws -> GossipSubMessage {
        try await publish(data: data, to: Topic(topic))
    }

    /// Publishes a string message to a topic.
    ///
    /// - Parameters:
    ///   - message: The string message
    ///   - topic: The topic
    /// - Returns: The published message
    @discardableResult
    public func publish(message: String, to topic: Topic) async throws -> GossipSubMessage {
        try await publish(data: Data(message.utf8), to: topic)
    }

    // MARK: - Validator Registration (v1.1)

    /// Registers an application-level message validator for a topic.
    ///
    /// Only one validator per topic is supported. Setting a new validator
    /// replaces the previous one.
    ///
    /// - Parameters:
    ///   - validator: The message validator
    ///   - topic: The topic to validate messages for
    public func registerValidator(_ validator: any MessageValidator, for topic: Topic) {
        router.registerValidator(validator, for: topic)
    }

    /// Unregisters the message validator for a topic.
    ///
    /// - Parameter topic: The topic to remove the validator for
    public func unregisterValidator(for topic: Topic) {
        router.unregisterValidator(for: topic)
    }

    // MARK: - Direct Peer Management (v1.1)

    /// Adds a direct peer for unconditional message forwarding.
    ///
    /// Direct peers are always included in message forwarding and are
    /// protected from pruning, scoring, and backoff enforcement.
    ///
    /// - Parameters:
    ///   - peer: The peer ID to add as direct
    ///   - topic: The topic
    public func addDirectPeer(_ peer: PeerID, for topic: Topic) {
        router.addDirectPeer(peer, for: topic)
    }

    /// Removes a direct peer.
    ///
    /// - Parameters:
    ///   - peer: The peer ID to remove
    ///   - topic: The topic
    public func removeDirectPeer(_ peer: PeerID, from topic: Topic) {
        router.removeDirectPeer(peer, from: topic)
    }

    // MARK: - Peer Management

    /// Handles a new peer connection.
    ///
    /// Call this when a new peer connects that supports GossipSub.
    ///
    /// - Parameters:
    ///   - peerID: The connected peer
    ///   - protocolID: The negotiated protocol ID
    ///   - direction: Connection direction
    ///   - stream: The muxed stream
    public func handlePeerConnected(
        _ peerID: PeerID,
        protocolID: String,
        direction: PeerDirection,
        stream: MuxedStream
    ) {
        guard let version = GossipSubVersion(protocolID: protocolID) else {
            return
        }

        router.handlePeerConnected(peerID, version: version, direction: direction, stream: stream)

        // Store stream
        serviceState.withLock { $0.peerStreams[peerID] = stream }

        // Send our subscriptions
        Task {
            await sendSubscriptions(to: peerID)
        }
    }

    /// Handles a peer disconnection.
    ///
    /// - Parameter peerID: The disconnected peer
    public func handlePeerDisconnected(_ peerID: PeerID) {
        router.handlePeerDisconnected(peerID)

        serviceState.withLock { _ = $0.peerStreams.removeValue(forKey: peerID) }
    }

    /// Returns connected peer count.
    public var connectedPeerCount: Int {
        router.peerState.peerCount
    }

    /// Returns all connected peers.
    public var connectedPeers: [PeerID] {
        router.peerState.allPeers
    }

    // MARK: - Statistics

    /// Returns mesh statistics.
    public var meshStats: MeshStats {
        router.meshState.stats
    }

    // MARK: - Private Methods

    /// Handles an incoming stream.
    private func handleIncomingStream(context: StreamContext, protocolID: String) async {
        let peerID = context.remotePeer
        let stream = context.stream

        // Determine version
        guard let version = GossipSubVersion(protocolID: protocolID) else {
            try? await stream.close()
            return
        }

        // Register peer if not already known
        let isNewPeer = router.peerState.getPeer(peerID) == nil
        if isNewPeer {
            router.handlePeerConnected(peerID, version: version, direction: .inbound, stream: stream)
            serviceState.withLock { $0.peerStreams[peerID] = stream }

            // Send our subscriptions to new inbound peer
            await sendSubscriptions(to: peerID)
        }

        // Read and process RPC messages
        await processIncomingRPCs(from: peerID, stream: stream)
    }

    /// Maximum buffer size for incoming RPCs (must be >= maxRPCSize).
    private static let maxBufferSize = 5 * 1024 * 1024  // 5 MB

    /// Processes incoming RPCs from a stream.
    private func processIncomingRPCs(from peerID: PeerID, stream: MuxedStream) async {
        var buffer = Data()

        do {
            readLoop: while true {
                let chunk = try await stream.read()
                if chunk.isEmpty {
                    break // EOF - normal close
                }
                buffer.append(chunk)

                // Check buffer size limit to prevent DoS
                if buffer.count > Self.maxBufferSize {
                    break // Protocol error - buffer overflow
                }

                // Try to parse RPC (length-prefixed)
                parseLoop: while true {
                    do {
                        guard let (rpc, consumed) = try parseLengthPrefixedRPC(from: buffer) else {
                            break parseLoop // Need more data
                        }
                        buffer = Data(buffer.dropFirst(consumed))

                        // Handle RPC and get result
                        let result = await router.handleRPC(rpc, from: peerID)

                        // Send response back to sender if present
                        if let response = result.response {
                            await sendRPC(response, to: peerID)
                        }

                        // Forward messages to mesh peers
                        for (peer, forwardRPC) in result.forwardMessages {
                            await sendRPC(forwardRPC, to: peer)
                        }
                    } catch {
                        // Parsing error - malformed data from peer
                        break readLoop
                    }
                }
            }
        } catch {
            logger.warning("GossipSub incoming RPC read error from \(peerID): \(error)")
        }

        // Always clean up peer state when stream ends
        handlePeerDisconnected(peerID)

        try? await stream.close()
    }

    /// Maximum single RPC message size (4 MB).
    private static let maxRPCSize = 4 * 1024 * 1024

    /// Parses a length-prefixed RPC from data.
    ///
    /// - Returns: Tuple of (RPC, consumed bytes) or nil if need more data
    /// - Throws: GossipSubError if message is malformed or too large
    private func parseLengthPrefixedRPC(from data: Data) throws -> (GossipSubRPC, Int)? {
        guard data.count > 0 else { return nil }

        // Read varint length prefix - handle partial varints gracefully
        let length: UInt64
        let lengthBytes: Int
        do {
            (length, lengthBytes) = try Varint.decode(data)
        } catch VarintError.insufficientData {
            return nil // Need more data for varint
        }

        // Validate length bounds to prevent overflow and DoS
        guard length <= UInt64(Self.maxRPCSize) else {
            throw GossipSubError.messageTooLarge(size: Int(min(length, UInt64(Int.max))), maxSize: Self.maxRPCSize)
        }

        let messageLength = Int(length)
        let totalLength = lengthBytes + messageLength

        // Check for integer overflow
        guard totalLength > lengthBytes else {
            throw GossipSubError.malformedMessage("Length prefix overflow")
        }

        guard data.count >= totalLength else {
            return nil // Need more data for message body
        }

        let rpcData = Data(data[lengthBytes..<totalLength])
        let rpc = try GossipSubProtobuf.decode(rpcData)

        return (rpc, totalLength)
    }

    /// Sends an RPC to a peer.
    private func sendRPC(_ rpc: GossipSubRPC, to peerID: PeerID) async {
        guard let stream = serviceState.withLock({ $0.peerStreams[peerID] }) else {
            return
        }

        do {
            // Encode with length prefix
            let encoded = GossipSubProtobuf.encode(rpc)
            var data = Data()
            data.append(contentsOf: Varint.encode(UInt64(encoded.count)))
            data.append(encoded)

            try await stream.write(data)
        } catch {
            logger.warning("GossipSub sendRPC failed to \(peerID): \(error)")
            try? await stream.close()
        }
    }

    /// Sends our subscriptions to a peer.
    private func sendSubscriptions(to peerID: PeerID) async {
        let topics = router.meshState.subscribedTopics

        guard !topics.isEmpty else { return }

        var rpc = GossipSubRPC()
        for topic in topics {
            rpc.subscriptions.append(.subscribe(to: topic))
        }

        await sendRPC(rpc, to: peerID)
    }
}

// MARK: - LibP2PProtocol Extension

extension LibP2PProtocol {
    /// GossipSub protocol IDs.
    public static let gossipsub = GossipSubProtocolID.meshsub11
    public static let gossipsubV12 = GossipSubProtocolID.meshsub12
    public static let floodsub = GossipSubProtocolID.floodsub
}
