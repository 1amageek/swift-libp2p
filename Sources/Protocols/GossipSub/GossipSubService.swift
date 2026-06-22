/// GossipSubService - Main service implementation for GossipSub protocol
import Foundation
import NIOCore
import P2PCore
import P2PMux
import P2PProtocols
import Synchronization

private let logger = Logger(label: "p2p.gossipsub")

/// The main GossipSub service implementing the StreamService interface.
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
public final class GossipSubService: Sendable {

    // MARK: - StreamService

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
        var opener: (any StreamOpener)?
        /// Tracked unstructured tasks (e.g. subscription sends) so they can be
        /// cancelled on shutdown rather than leaking.
        var pendingTasks: [UUID: Task<Void, Never>] = [:]
    }

    /// Spawns a tracked unstructured task and removes it from tracking on
    /// completion. Tracked tasks are cancelled during `shutdown()`.
    private func trackTask(_ body: @escaping @Sendable () async -> Void) {
        let id = UUID()
        let task = Task { [weak self] in
            await body()
            self?.serviceState.withLock { _ = $0.pendingTasks.removeValue(forKey: id) }
        }
        serviceState.withLock { $0.pendingTasks[id] = task }
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
        configuration: GossipSubConfiguration = .init(),
        opener: (any StreamOpener)? = nil
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
        self.serviceState = Mutex(ServiceState(opener: opener))
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
        configuration: GossipSubConfiguration = .testing,
        opener: (any StreamOpener)? = nil
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
        self.serviceState = Mutex(ServiceState(opener: opener))
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

    /// Shuts down the GossipSub service.
    public func shutdown() async throws {
        let pending = serviceState.withLock { s -> [Task<Void, Never>] in
            s.isStarted = false
            s.opener = nil
            s.peerStreams.removeAll()
            let tasks = Array(s.pendingTasks.values)
            s.pendingTasks.removeAll()
            return tasks
        }
        // Cancel any tracked unstructured tasks (e.g. in-flight subscription sends).
        for task in pending {
            task.cancel()
        }

        heartbeat.withLock { hb in
            hb?.shutdown()
            hb = nil
        }

        try await router.shutdown()
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

        // Send our subscriptions (tracked so it is cancelled on shutdown).
        trackTask { [weak self] in
            await self?.sendSubscriptions(to: peerID)
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

    private func closeStreamBestEffort(_ stream: MuxedStream, context: String) async {
        do {
            try await stream.close()
        } catch {
            logger.debug("GossipSub stream close failed (\(context)): \(error)")
        }
    }

    /// Handles an incoming stream.
    private func handleIncomingStream(context: StreamContext, protocolID: String) async {
        let peerID = context.remotePeer
        let stream = context.stream

        // Determine version
        guard let version = GossipSubVersion(protocolID: protocolID) else {
            await closeStreamBestEffort(stream, context: "unsupported protocol version \(protocolID)")
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
        var buffer = ByteBuffer()

        do {
            readLoop: while true {
                let chunk = try await stream.read()
                if chunk.readableBytes == 0 {
                    break // EOF - normal close
                }
                var mutableChunk = chunk
                buffer.writeBuffer(&mutableChunk)

                // Check buffer size limit to prevent DoS
                if buffer.readableBytes > Self.maxBufferSize {
                    break // Protocol error - buffer overflow
                }

                // Try to parse RPC (length-prefixed)
                parseLoop: while true {
                    do {
                        guard let rpc = try parseLengthPrefixedRPC(from: &buffer) else {
                            break parseLoop // Need more data
                        }

                        // Handle RPC and get result
                        let result = await router.handleRPC(rpc, from: peerID)

                        // Send response back to sender if present
                        if let response = result.response {
                            await sendRPC(response, to: peerID)
                        }

                        // Forward messages to mesh peers (encode once, send to many)
                        await forwardRPCs(result.forwardMessages)
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

        await closeStreamBestEffort(stream, context: "incoming RPC loop ended for peer \(peerID)")
    }

    /// Maximum single RPC message size (4 MB).
    private static let maxRPCSize = 4 * 1024 * 1024

    /// Parses a length-prefixed RPC from data.
    ///
    /// - Returns: RPC or nil if need more data
    /// - Throws: GossipSubError if message is malformed or too large
    private func parseLengthPrefixedRPC(from data: inout ByteBuffer) throws -> GossipSubRPC? {
        guard data.readableBytes > 0 else { return nil }

        // Read varint length prefix - handle partial varints gracefully
        let length: UInt64
        let lengthBytes: Int
        do {
            (length, lengthBytes) = try data.withUnsafeReadableBytes { ptr in
                try Varint.decode(from: UnsafeRawBufferPointer(ptr), at: 0)
            }
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

        guard data.readableBytes >= totalLength else {
            return nil // Need more data for message body
        }

        data.moveReaderIndex(forwardBy: lengthBytes)
        guard let rpcBuffer = data.readSlice(length: messageLength) else {
            throw GossipSubError.malformedMessage("Failed to read RPC payload")
        }
        if data.readerIndex > Self.maxBufferSize {
            data.discardReadBytes()
        }
        return try GossipSubProtobuf.decode(rpcBuffer, limits: configuration.decodingLimits)
    }

    /// Encodes an RPC with length prefix.
    private func encodeRPC(_ rpc: GossipSubRPC) -> ByteBuffer {
        var encoded = ByteBufferAllocator().buffer(capacity: 0)
        GossipSubProtobuf.encode(rpc, into: &encoded)
        var buffer = ByteBufferAllocator().buffer(capacity: encoded.readableBytes + 10)
        Varint.encode(UInt64(encoded.readableBytes), into: &buffer)
        buffer.writeImmutableBuffer(encoded)
        return buffer
    }

    /// Sends an RPC to a peer.
    private func sendRPC(_ rpc: GossipSubRPC, to peerID: PeerID) async {
        await sendEncodedRPC(encodeRPC(rpc), to: peerID)
    }

    /// Sends pre-encoded RPC data to a peer.
    private func sendEncodedRPC(_ data: ByteBuffer, to peerID: PeerID) async {
        guard let stream = serviceState.withLock({ $0.peerStreams[peerID] }) else {
            return
        }

        do {
            try await stream.write(data)
        } catch {
            logger.warning("GossipSub sendRPC failed to \(peerID): \(error)")
            await closeStreamBestEffort(stream, context: "sendRPC failure to peer \(peerID)")
        }
    }

    /// Forwards RPCs to multiple peers, encoding identical RPCs only once.
    ///
    /// The router typically creates the same RPC for all mesh peers in a topic.
    /// This method encodes each unique RPC once and reuses the encoded bytes
    /// for all target peers.
    private func forwardRPCs(_ forwards: [(peer: PeerID, rpc: GossipSubRPC)]) async {
        guard !forwards.isEmpty else { return }

        // Encode the first RPC and track it for deduplication
        var lastEncodedData = encodeRPC(forwards[0].rpc)
        var lastRPCMessages = forwards[0].rpc.messages

        await sendEncodedRPC(lastEncodedData, to: forwards[0].peer)

        for i in 1..<forwards.count {
            let (peer, rpc) = forwards[i]
            // Check if this RPC has the same messages as the last one
            // (forwardMessage produces identical RPCs for all peers in a topic)
            if rpc.messages.count == lastRPCMessages.count,
               rpc.messages.count == 1,
               lastRPCMessages.count == 1,
               rpc.messages[0].id == lastRPCMessages[0].id {
                // Same RPC content - reuse encoded data (ByteBuffer is CoW)
                await sendEncodedRPC(lastEncodedData, to: peer)
            } else {
                // Different RPC - encode fresh
                lastEncodedData = encodeRPC(rpc)
                lastRPCMessages = rpc.messages
                await sendEncodedRPC(lastEncodedData, to: peer)
            }
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

// MARK: - StreamService

extension GossipSubService: LifecycleService, StreamService, PeerObserver, ActivatableService, StreamOpeningActivatable {
    public func handleInboundStream(_ context: StreamContext) async {
        await handleIncomingStream(context: context, protocolID: context.protocolID)
    }

    public func activate(using opener: any StreamOpener) async {
        serviceState.withLock { $0.opener = opener }
        await activate()
    }

    public func activate() async {
        if !serviceState.withLock({ $0.isStarted }) {
            start()
        }
    }

    public func peerConnected(_ peer: PeerID) async {
        guard let opener = serviceState.withLock({ $0.opener }) else { return }
        do {
            let protocolID = protocolIDs[0]
            let stream = try await opener.newStream(to: peer, protocol: protocolID)
            handlePeerConnected(peer, protocolID: protocolID, direction: .outbound, stream: stream)
        } catch {
            router.handlePeerDisconnected(peer)
        }
    }

    public func peerDisconnected(_ peer: PeerID) async {
        handlePeerDisconnected(peer)
    }
}

// MARK: - ProtocolID Extension

extension ProtocolID {
    /// GossipSub protocol IDs.
    public static let gossipsub = GossipSubProtocolID.meshsub11
    public static let gossipsubV12 = GossipSubProtocolID.meshsub12
    public static let floodsub = GossipSubProtocolID.floodsub
}
