/// PlumtreeService - Main service implementation for Plumtree protocol
import Foundation
import P2PCore
import P2PMux
import P2PProtocols
import Synchronization
import Logging

private let logger = Logger(label: "p2p.plumtree")

/// The main Plumtree service implementing the ProtocolService interface.
///
/// Provides epidemic broadcast tree messaging with eager and lazy push
/// strategies for efficient message dissemination.
///
/// ## Usage
///
/// ```swift
/// let plumtree = PlumtreeService(
///     localPeerID: myPeerID,
///     configuration: .default
/// )
///
/// // Register handler and start
/// await plumtree.registerHandler(registry: node)
/// plumtree.start()
///
/// // Subscribe and receive messages
/// let messages = plumtree.subscribe(to: "my-topic")
/// for await gossip in messages {
///     print("Received: \(gossip.data)")
/// }
///
/// // Publish
/// try plumtree.publish(data: myData, to: "my-topic")
/// ```
public final class PlumtreeService: ProtocolService, Sendable {

    // MARK: - ProtocolService

    public var protocolIDs: [String] { [plumtreeProtocolID] }

    // MARK: - Properties

    /// The local peer ID.
    public let localPeerID: PeerID

    /// Configuration.
    public let configuration: PlumtreeConfiguration

    /// The core router.
    private let router: PlumtreeRouter

    /// The lazy push buffer.
    private let lazyBuffer: LazyPushBuffer

    /// Event broadcaster (multi-consumer).
    private let eventBroadcaster = EventBroadcaster<PlumtreeEvent>()

    /// Message broadcaster for subscription delivery.
    private let messageBroadcaster = EventBroadcaster<PlumtreeGossip>()

    /// Internal mutable state.
    private let serviceState: Mutex<ServiceState>

    private struct ServiceState: Sendable {
        var isStarted: Bool = false
        var peerStreams: [PeerID: MuxedStream] = [:]
        var sequenceNumber: UInt64 = 0
        var flushTask: Task<Void, Never>?
        var cleanupTask: Task<Void, Never>?
    }

    // MARK: - Initialization

    /// Creates a new Plumtree service.
    ///
    /// - Parameters:
    ///   - localPeerID: The local peer ID
    ///   - configuration: Configuration parameters
    public init(
        localPeerID: PeerID,
        configuration: PlumtreeConfiguration = .default
    ) {
        self.localPeerID = localPeerID
        self.configuration = configuration
        self.router = PlumtreeRouter(
            localPeerID: localPeerID,
            configuration: configuration
        )
        self.lazyBuffer = LazyPushBuffer(maxBatchSize: configuration.maxIHaveBatchSize)
        self.serviceState = Mutex(ServiceState())
    }

    // MARK: - Lifecycle

    /// Starts the Plumtree service.
    ///
    /// Begins the lazy push flush loop and cleanup tasks.
    public func start() {
        serviceState.withLock { s in
            guard !s.isStarted else { return }
            s.isStarted = true

            s.flushTask = Task { [weak self] in
                await self?.lazyPushFlushLoop()
            }
            s.cleanupTask = Task { [weak self] in
                await self?.cleanupLoop()
            }
        }
        logger.info("Plumtree started")
    }

    /// Stops the Plumtree service.
    public func stop() {
        let (flushTask, cleanupTask) = serviceState.withLock { s -> (Task<Void, Never>?, Task<Void, Never>?) in
            s.isStarted = false
            let ft = s.flushTask
            let ct = s.cleanupTask
            s.flushTask = nil
            s.cleanupTask = nil
            s.peerStreams.removeAll()
            return (ft, ct)
        }
        flushTask?.cancel()
        cleanupTask?.cancel()
        router.shutdown()
        lazyBuffer.clear()
        eventBroadcaster.shutdown()
        messageBroadcaster.shutdown()
        logger.info("Plumtree stopped")
    }

    /// Whether the service is started.
    public var isStarted: Bool {
        serviceState.withLock { $0.isStarted }
    }

    // MARK: - Handler Registration

    /// Registers the Plumtree protocol handler.
    ///
    /// - Parameter registry: The handler registry to register with
    public func registerHandler(registry: any HandlerRegistry) async {
        await registry.handle(plumtreeProtocolID) { [weak self] context in
            await self?.handleIncomingStream(context: context)
        }
    }

    // MARK: - Event Stream

    /// Event stream for monitoring Plumtree protocol events.
    public var events: AsyncStream<PlumtreeEvent> {
        eventBroadcaster.subscribe()
    }

    // MARK: - Subscription API

    /// Subscribes to a topic.
    ///
    /// - Parameter topic: The topic to subscribe to
    /// - Returns: An async stream of gossip messages for this topic
    public func subscribe(to topic: String) -> AsyncStream<PlumtreeGossip> {
        let events = router.subscribe(to: topic)
        emitEvents(events)

        let stream = messageBroadcaster.subscribe()
        return AsyncStream { continuation in
            let task = Task {
                for await gossip in stream {
                    if gossip.topic == topic {
                        continuation.yield(gossip)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// Unsubscribes from a topic.
    ///
    /// - Parameter topic: The topic to unsubscribe from
    public func unsubscribe(from topic: String) {
        router.unsubscribe(from: topic)
    }

    /// Returns all subscribed topics.
    public var subscribedTopics: Set<String> {
        router.subscribedTopics
    }

    // MARK: - Publishing API

    /// Publishes data to a topic.
    ///
    /// - Parameters:
    ///   - data: The message payload
    ///   - topic: The topic to publish to
    /// - Returns: The message ID of the published message
    @discardableResult
    public func publish(data: Data, to topic: String) throws -> PlumtreeMessageID {
        guard serviceState.withLock({ $0.isStarted }) else {
            throw PlumtreeError.notStarted
        }
        guard data.count <= configuration.maxMessageSize else {
            throw PlumtreeError.messageTooLarge(
                size: data.count,
                maxSize: configuration.maxMessageSize
            )
        }
        guard router.isSubscribed(to: topic) else {
            throw PlumtreeError.notSubscribed(topic)
        }

        // Generate message ID
        let seqNo = serviceState.withLock { s -> UInt64 in
            s.sequenceNumber += 1
            return s.sequenceNumber
        }
        let messageID = PlumtreeMessageID.compute(
            source: localPeerID,
            sequenceNumber: seqNo
        )

        let gossip = PlumtreeGossip(
            messageID: messageID,
            topic: topic,
            data: data,
            source: localPeerID,
            hopCount: 0
        )

        // Register with router (marks as seen, stores)
        let (eagerPeers, lazyPeers) = router.registerPublished(gossip)

        // Send to eager peers
        let gossipRPC = PlumtreeRPC(gossipMessages: [gossip])
        for peer in eagerPeers {
            Task { await sendRPC(gossipRPC, to: peer) }
        }

        // Buffer IHave for lazy peers
        let ihaveEntry = PlumtreeIHaveEntry(messageID: messageID, topic: topic)
        lazyBuffer.add(ihaveEntry, for: lazyPeers)

        // Deliver to local subscribers
        messageBroadcaster.emit(gossip)

        emitEvents([.messagePublished(topic: topic, messageID: messageID)])

        return messageID
    }

    // MARK: - Peer Management

    /// Handles a new peer connection.
    ///
    /// - Parameters:
    ///   - peerID: The connected peer
    ///   - stream: The muxed stream for communication
    public func handlePeerConnected(_ peerID: PeerID, stream: MuxedStream) {
        serviceState.withLock { $0.peerStreams[peerID] = stream }
        let events = router.handlePeerConnected(peerID)
        emitEvents(events)

        // Start reading RPCs from the peer
        Task { await processIncomingRPCs(from: peerID, stream: stream) }
    }

    /// Handles a peer disconnection.
    ///
    /// - Parameter peerID: The disconnected peer
    public func handlePeerDisconnected(_ peerID: PeerID) {
        serviceState.withLock { _ = $0.peerStreams.removeValue(forKey: peerID) }
        lazyBuffer.remove(peer: peerID)
        let events = router.handlePeerDisconnected(peerID)
        emitEvents(events)
    }

    /// Returns the connected peer count.
    public var connectedPeerCount: Int {
        router.connectedPeers.count
    }

    // MARK: - Private: Incoming Stream Handling

    private func handleIncomingStream(context: StreamContext) async {
        let peerID = context.remotePeer
        let stream = context.stream

        // Register peer if not already known
        let isNew = serviceState.withLock { s -> Bool in
            guard s.peerStreams[peerID] == nil else { return false }
            s.peerStreams[peerID] = stream
            return true
        }

        if isNew {
            let events = router.handlePeerConnected(peerID)
            emitEvents(events)
        }

        await processIncomingRPCs(from: peerID, stream: stream)
    }

    private func processIncomingRPCs(from peerID: PeerID, stream: MuxedStream) async {
        do {
            while !Task.isCancelled {
                let data = try await stream.readLengthPrefixedMessage(
                    maxSize: UInt64(configuration.maxMessageSize) + 4096
                )
                let rpc = try PlumtreeProtobuf.decode(Data(buffer: data))
                await processRPC(rpc, from: peerID)
            }
        } catch {
            logger.debug("Plumtree stream ended for \(peerID): \(error)")
        }

        handlePeerDisconnected(peerID)
        try? await stream.close()
    }

    private func processRPC(_ rpc: PlumtreeRPC, from peerID: PeerID) async {
        // Handle gossip messages
        for gossip in rpc.gossipMessages {
            let result = router.handleGossip(gossip, from: peerID)
            emitEvents(result.events)

            // Deliver to local subscribers
            if let deliver = result.deliverToSubscribers {
                messageBroadcaster.emit(deliver)
            }

            // Forward to eager peers
            if !result.forwardTo.isEmpty {
                let forwardGossip = PlumtreeGossip(
                    messageID: gossip.messageID,
                    topic: gossip.topic,
                    data: gossip.data,
                    source: gossip.source,
                    hopCount: gossip.hopCount + 1
                )
                let forwardRPC = PlumtreeRPC(gossipMessages: [forwardGossip])
                for peer in result.forwardTo {
                    await sendRPC(forwardRPC, to: peer)
                }
            }

            // Buffer IHave for lazy peers
            if !result.lazyNotify.isEmpty {
                let entry = PlumtreeIHaveEntry(
                    messageID: gossip.messageID,
                    topic: gossip.topic
                )
                lazyBuffer.add(entry, for: result.lazyNotify)
            }

            // Send PRUNE if duplicate
            if result.pruneSender {
                let pruneRPC = PlumtreeRPC(
                    pruneRequests: [PlumtreePruneRequest(topic: gossip.topic)]
                )
                await sendRPC(pruneRPC, to: peerID)
                emitEvents([.pruneSent(peer: peerID, topic: gossip.topic)])
            }
        }

        // Handle IHave entries
        if !rpc.ihaveEntries.isEmpty {
            let result = router.handleIHave(rpc.ihaveEntries, from: peerID)
            emitEvents(result.events)

            for timer in result.startTimers {
                startIHaveTimer(
                    messageID: timer.messageID,
                    peer: timer.peer,
                    topic: timer.topic
                )
            }
        }

        // Handle GRAFT requests
        for graft in rpc.graftRequests {
            let result = router.handleGraft(graft, from: peerID)
            emitEvents(result.events)

            // Re-send requested messages
            if !result.reSendMessages.isEmpty {
                let resendRPC = PlumtreeRPC(gossipMessages: result.reSendMessages)
                await sendRPC(resendRPC, to: peerID)
            }
        }

        // Handle PRUNE requests
        for prune in rpc.pruneRequests {
            let result = router.handlePrune(prune, from: peerID)
            emitEvents(result.events)
        }
    }

    // MARK: - Private: IHave Timeout

    private func startIHaveTimer(messageID: PlumtreeMessageID, peer: PeerID, topic: String) {
        Task {
            do {
                try await Task.sleep(for: configuration.ihaveTimeout)
            } catch {
                return // Cancelled
            }

            guard let result = router.handleIHaveTimeout(messageID) else {
                return // Message was already received
            }

            emitEvents(result.events)

            // Send GRAFT to the peer
            let graftRPC = PlumtreeRPC(graftRequests: [
                PlumtreeGraftRequest(
                    topic: result.graftTopic,
                    messageID: result.graftMessageID
                )
            ])
            await sendRPC(graftRPC, to: result.graftPeer)
            emitEvents([.graftSent(
                peer: result.graftPeer,
                topic: result.graftTopic,
                messageID: result.graftMessageID
            )])
        }
    }

    // MARK: - Private: Lazy Push Flush

    private func lazyPushFlushLoop() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: configuration.lazyPushDelay)
            } catch {
                break
            }

            let batches = lazyBuffer.flush()
            for (peer, entries) in batches {
                let rpc = PlumtreeRPC(ihaveEntries: entries)
                await sendRPC(rpc, to: peer)
            }
        }
    }

    // MARK: - Private: Cleanup Loop

    private func cleanupLoop() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                break
            }
            router.cleanup()
        }
    }

    // MARK: - Private: Sending

    private func sendRPC(_ rpc: PlumtreeRPC, to peerID: PeerID) async {
        guard let stream = serviceState.withLock({ $0.peerStreams[peerID] }) else {
            return
        }

        do {
            let encoded = PlumtreeProtobuf.encode(rpc)
            try await stream.writeLengthPrefixedMessage(ByteBuffer(bytes: encoded))
        } catch {
            logger.debug("Plumtree sendRPC failed to \(peerID): \(error)")
        }
    }

    // MARK: - Private: Event Emission

    private func emitEvents(_ events: [PlumtreeEvent]) {
        for event in events {
            eventBroadcaster.emit(event)
        }
    }
}

// MARK: - LibP2PProtocol Extension

extension LibP2PProtocol {
    /// Plumtree protocol ID.
    public static let plumtree = plumtreeProtocolID
}
