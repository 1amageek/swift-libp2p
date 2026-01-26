/// GossipSubRouter - Core state machine for GossipSub protocol
import Foundation
import P2PCore
import P2PMux
import P2PProtocols
import Synchronization

/// Result of handling an RPC message.
public struct RPCHandleResult: Sendable {
    /// RPC response to send back to the sender (if any).
    public var response: GossipSubRPC?

    /// Messages to forward to other mesh peers.
    public var forwardMessages: [(peer: PeerID, rpc: GossipSubRPC)]

    /// Whether there's anything to send.
    public var isEmpty: Bool {
        response == nil && forwardMessages.isEmpty
    }

    public init(
        response: GossipSubRPC? = nil,
        forwardMessages: [(peer: PeerID, rpc: GossipSubRPC)] = []
    ) {
        self.response = response
        self.forwardMessages = forwardMessages
    }
}

/// The core router for GossipSub protocol.
///
/// Manages mesh state, message routing, and control message handling.
/// Uses class + Mutex pattern for high-frequency operations.
public final class GossipSubRouter: EventEmitting, Sendable {

    // MARK: - Properties

    /// Configuration.
    public let configuration: GossipSubConfiguration

    /// Local peer ID.
    public let localPeerID: PeerID

    /// Signing key for message authentication.
    /// If nil, messages will not be signed.
    private let signingKey: PrivateKey?

    /// Mesh state.
    let meshState: MeshState

    /// Peer states.
    let peerState: PeerStateManager

    /// Message cache for IHAVE/IWANT.
    let messageCache: MessageCache

    /// Seen message cache for deduplication.
    let seenCache: SeenCache

    /// Local subscriptions delivering to user.
    let subscriptions: SubscriptionSet

    /// Peer scorer for tracking peer behavior.
    let peerScorer: PeerScorer

    /// Event state.
    private let eventState: Mutex<EventState>

    private struct EventState: Sendable {
        var continuation: AsyncStream<GossipSubEvent>.Continuation?
        var stream: AsyncStream<GossipSubEvent>?
    }

    // MARK: - Initialization

    /// Creates a new GossipSub router.
    ///
    /// - Parameters:
    ///   - localPeerID: The local peer ID
    ///   - signingKey: Private key for signing messages (nil = no signing)
    ///   - configuration: Configuration parameters
    ///   - peerScorerConfig: Peer scoring configuration (uses defaults if nil)
    public init(
        localPeerID: PeerID,
        signingKey: PrivateKey? = nil,
        configuration: GossipSubConfiguration = .init(),
        peerScorerConfig: PeerScorerConfig = .default
    ) {
        self.localPeerID = localPeerID
        self.signingKey = signingKey
        self.configuration = configuration
        self.meshState = MeshState()
        self.peerState = PeerStateManager()
        self.messageCache = MessageCache(
            windowCount: configuration.messageCacheLength,
            gossipWindowCount: configuration.messageCacheGossipLength
        )
        self.seenCache = SeenCache(
            maxSize: configuration.seenCacheSize,
            ttl: configuration.seenTTL
        )
        self.subscriptions = SubscriptionSet()
        self.peerScorer = PeerScorer(config: peerScorerConfig)
        self.eventState = Mutex(EventState())
    }

    // MARK: - Event Stream

    /// Event stream for monitoring router events.
    public var events: AsyncStream<GossipSubEvent> {
        eventState.withLock { state in
            if let existing = state.stream {
                return existing
            }
            let (stream, continuation) = AsyncStream<GossipSubEvent>.makeStream()
            state.stream = stream
            state.continuation = continuation
            return stream
        }
    }

    // MARK: - Subscription Management

    /// Subscribes to a topic.
    ///
    /// - Parameter topic: The topic to subscribe to
    /// - Returns: A subscription for receiving messages
    public func subscribe(to topic: Topic) throws -> Subscription {
        // Try to subscribe atomically with limit checking
        switch meshState.trySubscribe(to: topic, maxSubscriptions: configuration.maxSubscriptions) {
        case .success:
            break
        case .alreadySubscribed:
            throw GossipSubError.alreadySubscribed(topic)
        case .limitReached(let limit):
            throw GossipSubError.maxSubscriptionsReached(limit: limit)
        }

        // Create subscription for user
        let subscription = Subscription(topic: topic)
        subscriptions.add(subscription)

        // Emit event
        emit(.subscribed(topic: topic))

        return subscription
    }

    /// Unsubscribes from a topic.
    ///
    /// - Parameter topic: The topic to unsubscribe from
    /// - Returns: Mesh peers that were in the mesh (for sending PRUNE)
    @discardableResult
    public func unsubscribe(from topic: Topic) -> Set<PeerID> {
        guard meshState.isSubscribed(to: topic) else { return [] }

        // Unsubscribe and get the peers that were in our mesh
        let meshPeers = meshState.unsubscribe(from: topic)

        // Emit event
        emit(.unsubscribed(topic: topic))

        return meshPeers
    }

    // MARK: - Peer Management

    /// Handles a new peer connection.
    ///
    /// - Parameters:
    ///   - peerID: The connected peer
    ///   - version: The negotiated protocol version
    ///   - direction: Connection direction
    ///   - stream: The muxed stream
    ///   - remoteAddress: The remote peer's address (for IP-based Sybil defense)
    public func handlePeerConnected(
        _ peerID: PeerID,
        version: GossipSubVersion,
        direction: PeerDirection,
        stream: MuxedStream,
        remoteAddress: Multiaddr? = nil
    ) {
        let state = PeerState(
            peerID: peerID,
            version: version,
            direction: direction
        )
        peerState.addPeer(state, stream: stream)

        // Register IP for Sybil defense
        if let address = remoteAddress, let ip = extractIP(from: address) {
            registerPeerIP(peerID, ip: ip)
        }

        emit(.peerConnected(peer: peerID))
    }

    /// Handles a peer disconnection.
    ///
    /// - Parameter peerID: The disconnected peer
    public func handlePeerDisconnected(_ peerID: PeerID) {
        // Remove from all meshes
        meshState.removePeerFromAll(peerID)

        // Remove peer state
        peerState.removePeer(peerID)

        // Clean up scorer entry
        peerScorer.removePeer(peerID)

        emit(.peerDisconnected(peer: peerID))
    }

    /// Registers a peer's IP address for Sybil defense.
    ///
    /// Call this when a peer connects to enable IP-based colocation tracking.
    /// When too many peers connect from the same IP, they receive penalties.
    ///
    /// - Parameters:
    ///   - peerID: The peer ID.
    ///   - ip: The peer's IP address.
    public func registerPeerIP(_ peerID: PeerID, ip: String) {
        let result = peerScorer.registerPeerIP(peerID, ip: ip)
        if result.penaltyApplied {
            emit(.sybilSuspected(ip: result.ipAddress, peerCount: result.peerCount))
            let currentScore = peerScorer.score(for: peerID)
            emit(.peerPenalized(
                peer: peerID,
                reason: .ipColocation(ip: result.ipAddress, peerCount: result.peerCount),
                score: currentScore
            ))
        }
    }

    // MARK: - Message Handling

    /// Handles an incoming RPC message.
    ///
    /// - Parameters:
    ///   - rpc: The RPC message
    ///   - from: The peer that sent it
    /// - Returns: Result containing response RPC and messages to forward
    public func handleRPC(_ rpc: GossipSubRPC, from peerID: PeerID) async -> RPCHandleResult {
        var response = GossipSubRPC()
        var forwardMessages: [(peer: PeerID, rpc: GossipSubRPC)] = []

        // Handle subscriptions
        for sub in rpc.subscriptions {
            handleSubscription(sub, from: peerID)
        }

        // Handle messages and collect forwards
        for message in rpc.messages {
            let forwards = handleMessage(message, from: peerID)
            forwardMessages.append(contentsOf: forwards)
        }

        // Handle control messages
        if let control = rpc.control {
            let (controlResponse, iwantMessages) = await handleControl(control, from: peerID)
            if !controlResponse.isEmpty {
                response.control = controlResponse
            }
            // Include IWANT response messages in the response
            if !iwantMessages.isEmpty {
                response.messages.append(contentsOf: iwantMessages)
            }
        }

        return RPCHandleResult(
            response: response.isEmpty ? nil : response,
            forwardMessages: forwardMessages
        )
    }

    /// Handles a subscription/unsubscription from a peer.
    private func handleSubscription(
        _ sub: GossipSubRPC.SubscriptionOpt,
        from peerID: PeerID
    ) {
        peerState.updatePeer(peerID) { state in
            if sub.subscribe {
                state.subscriptions.insert(sub.topic)
            } else {
                state.subscriptions.remove(sub.topic)
            }
        }

        if sub.subscribe {
            emit(.peerSubscribed(peer: peerID, topic: sub.topic))
        } else {
            // Remove from mesh if present
            if meshState.removeFromMesh(peerID, for: sub.topic) {
                emit(.peerLeftMesh(peer: peerID, topic: sub.topic))
            }
            emit(.peerUnsubscribed(peer: peerID, topic: sub.topic))
        }
    }

    /// Handles an incoming message.
    ///
    /// - Returns: List of (peer, RPC) tuples for forwarding the message
    private func handleMessage(
        _ message: GossipSubMessage,
        from peerID: PeerID
    ) -> [(peer: PeerID, rpc: GossipSubRPC)] {
        // Reject messages from graylisted peers
        if peerScorer.isGraylisted(peerID) {
            emit(.peerPenalized(
                peer: peerID,
                reason: .protocolViolation("message from graylisted peer"),
                score: peerScorer.score(for: peerID)
            ))
            return []
        }

        // === Dedup Phase ===
        // Check if already seen (before validation to avoid redundant work)
        let isFirstDelivery = seenCache.add(message.id)
        if !isFirstDelivery {
            // Duplicate - record penalty and don't forward
            peerScorer.recordDuplicateMessage(from: peerID)
            return []
        }

        // === Validation Phase ===
        // Validate message structure
        guard message.validateStructure() else {
            // Invalid message structure - record penalty
            peerScorer.recordInvalidMessage(from: peerID)
            emit(.messageValidated(messageID: message.id, result: .reject))
            return []
        }

        // Validate message signature if enabled
        if configuration.validateSignatures {
            // Check if message has required signing fields
            if configuration.strictSignatureVerification {
                // Strict mode: require signature
                guard message.signature != nil, message.source != nil else {
                    peerScorer.recordInvalidMessage(from: peerID)
                    emit(.messageValidated(messageID: message.id, result: .reject))
                    return []
                }
            }

            // Verify signature if present
            if message.signature != nil {
                guard message.verifySignature() else {
                    // Invalid signature - record penalty
                    peerScorer.recordInvalidMessage(from: peerID)
                    emit(.messageValidated(messageID: message.id, result: .reject))
                    return []
                }
            }
        }

        // === Scoring Phase ===
        // Track message delivery AFTER validation succeeds
        // This prevents attackers from gaining first-delivery bonus with invalid messages
        peerScorer.recordMessageDelivery(from: peerID, isFirst: true)

        // === Delivery Phase ===
        // Cache the message
        messageCache.put(message)

        // Deliver to local subscribers
        subscriptions.deliver(message)

        // Emit event
        emit(.messageReceived(topic: message.topic, message: message))

        // Forward to mesh peers (except sender)
        var forwards = forwardMessage(message, excluding: peerID)

        // === IDONTWANT Phase (v1.2) ===
        // Send IDONTWANT to mesh peers for large messages
        let threshold = configuration.idontwantThreshold
        if threshold > 0 && message.data.count >= threshold {
            let idontwantForwards = sendIDontWant(for: message, excluding: peerID)
            forwards.append(contentsOf: idontwantForwards)
        }

        return forwards
    }

    /// Sends IDONTWANT to mesh peers for a message (v1.2).
    ///
    /// When we receive a large message, we tell other mesh peers that we don't
    /// need them to forward it to us, reducing duplicate transmissions.
    ///
    /// - Returns: List of (peer, RPC) tuples for sending IDONTWANT
    private func sendIDontWant(
        for message: GossipSubMessage,
        excluding: PeerID
    ) -> [(peer: PeerID, rpc: GossipSubRPC)] {
        let topic = message.topic
        let meshPeers = meshState.meshPeers(for: topic)

        var forwards: [(peer: PeerID, rpc: GossipSubRPC)] = []
        let idontwant = ControlMessage.IDontWant(messageIDs: [message.id])
        var control = ControlMessageBatch()
        control.idontwants.append(idontwant)
        let rpc = GossipSubRPC(control: control)

        for peer in meshPeers where peer != excluding {
            // Only send to peers that support v1.2
            if let state = peerState.getPeer(peer), state.version >= .v12 {
                forwards.append((peer, rpc))
                emit(.idontWantSent(peer: peer, messageCount: 1))
            }
        }

        return forwards
    }

    /// Forwards a message to mesh peers.
    ///
    /// - Returns: List of (peer, RPC) tuples for forwarding
    private func forwardMessage(
        _ message: GossipSubMessage,
        excluding: PeerID
    ) -> [(peer: PeerID, rpc: GossipSubRPC)] {
        let topic = message.topic
        let meshPeers = meshState.meshPeers(for: topic)

        var forwards: [(peer: PeerID, rpc: GossipSubRPC)] = []
        let rpc = GossipSubRPC(messages: [message])

        for peer in meshPeers where peer != excluding {
            // Check IDONTWANT (v1.2): Skip if peer doesn't want this message
            if let state = peerState.getPeer(peer), state.doesntWant(message.id) {
                emit(.messageSkippedByIdontWant(peer: peer, messageID: message.id))
                continue
            }

            forwards.append((peer, rpc))
            emit(.messageForwarded(peer: peer, topic: topic, messageID: message.id))
        }

        return forwards
    }

    /// Handles control messages.
    ///
    /// - Returns: Tuple of (control response, messages from IWANT requests)
    private func handleControl(
        _ control: ControlMessageBatch,
        from peerID: PeerID
    ) async -> (ControlMessageBatch, [GossipSubMessage]) {
        var response = ControlMessageBatch()

        // Handle IHAVEs - respond with IWANTs for messages we don't have
        let iwants = handleIHaves(control.ihaves, from: peerID)
        response.iwants = iwants

        // Handle IWANTs - return the requested messages to include in response
        let iwantMessages = handleIWants(control.iwants, from: peerID)

        // Handle GRAFTs - respond with PRUNEs if we can't accept
        let prunes = handleGrafts(control.grafts, from: peerID)
        response.prunes = prunes

        // Handle PRUNEs
        handlePrunes(control.prunes, from: peerID)

        // Handle IDONTWANTs (v1.2)
        handleIDontWants(control.idontwants, from: peerID)

        return (response, iwantMessages)
    }

    /// Handles IHAVE messages.
    private func handleIHaves(
        _ ihaves: [ControlMessage.IHave],
        from peerID: PeerID
    ) -> [ControlMessage.IWant] {
        // Use Set for deduplication and cap size during collection
        var wantedIDs = Set<MessageID>()
        let maxWant = configuration.maxIWantMessages

        outerLoop: for ihave in ihaves {
            emit(.ihaveReceived(peer: peerID, topic: ihave.topic, messageCount: ihave.messageIDs.count))

            for msgID in ihave.messageIDs {
                // Stop early if we've collected enough
                if wantedIDs.count >= maxWant {
                    break outerLoop
                }

                // Request messages we haven't seen (skip duplicates via Set)
                if !seenCache.contains(msgID) && !messageCache.contains(msgID) {
                    wantedIDs.insert(msgID)
                }
            }
        }

        guard !wantedIDs.isEmpty else { return [] }

        emit(.iwantSent(peer: peerID, messageCount: wantedIDs.count))

        return [ControlMessage.IWant(messageIDs: Array(wantedIDs))]
    }

    /// Handles IWANT messages.
    private func handleIWants(
        _ iwants: [ControlMessage.IWant],
        from peerID: PeerID
    ) -> [GossipSubMessage] {
        // Block graylisted peers immediately
        if peerScorer.isGraylisted(peerID) {
            return []
        }

        var messages: [GossipSubMessage] = []

        for iwant in iwants {
            for msgID in iwant.messageIDs {
                // Track the IWANT request and check for excessive requests
                let result = peerScorer.trackIWantRequest(from: peerID, for: msgID)
                if case .excessive(let count) = result {
                    // Apply penalty for excessive IWANT requests
                    peerScorer.recordExcessiveIWant(from: peerID)
                    let currentScore = peerScorer.score(for: peerID)
                    emit(.peerPenalized(
                        peer: peerID,
                        reason: .excessiveIWant,
                        score: currentScore
                    ))
                    // Log once per excessive detection, not per request
                    if count == configuration.maxIWantMessages {
                        // Only continue processing if score is still acceptable
                        if peerScorer.isGraylisted(peerID) {
                            return messages
                        }
                    }
                }
            }

            // Retrieve requested messages from cache
            let found = messageCache.getMultiple(iwant.messageIDs)
            messages.append(contentsOf: found.values)
        }

        return messages
    }

    /// Handles GRAFT messages.
    private func handleGrafts(
        _ grafts: [ControlMessage.Graft],
        from peerID: PeerID
    ) -> [ControlMessage.Prune] {
        var prunes: [ControlMessage.Prune] = []

        for graft in grafts {
            let topic = graft.topic

            // Check if we're subscribed
            guard meshState.isSubscribed(to: topic) else {
                // Not subscribed - send PRUNE and set backoff
                prunes.append(ControlMessage.Prune(topic: topic))
                peerState.updatePeer(peerID) { state in
                    state.setBackoff(for: topic, duration: configuration.pruneBackoff)
                }
                continue
            }

            // Check if peer is in backoff period (we previously PRUNEd them)
            if let state = peerState.getPeer(peerID), state.isBackedOff(for: topic) {
                // Peer violated backoff - record penalty and send PRUNE again
                peerScorer.recordGraftDuringBackoff(from: peerID)
                let currentScore = peerScorer.score(for: peerID)
                prunes.append(ControlMessage.Prune(
                    topic: topic,
                    backoff: UInt64(configuration.pruneBackoff.components.seconds)
                ))
                emit(.peerPenalized(peer: peerID, reason: .protocolViolation("GRAFT during backoff"), score: currentScore))
                // Backoff already set, no need to update
                continue
            }

            // Check mesh limits
            let currentCount = meshState.meshPeerCount(for: topic)
            if currentCount >= configuration.maxPeersPerTopic {
                // Mesh full - send PRUNE with backoff and set local backoff
                prunes.append(ControlMessage.Prune(
                    topic: topic,
                    backoff: UInt64(configuration.pruneBackoff.components.seconds)
                ))
                peerState.updatePeer(peerID) { state in
                    state.setBackoff(for: topic, duration: configuration.pruneBackoff)
                }
                continue
            }

            // Add to mesh
            if meshState.addToMesh(peerID, for: topic) {
                emit(.peerJoinedMesh(peer: peerID, topic: topic))
            }
        }

        return prunes
    }

    /// Handles PRUNE messages.
    private func handlePrunes(
        _ prunes: [ControlMessage.Prune],
        from peerID: PeerID
    ) {
        for prune in prunes {
            let topic = prune.topic

            // Remove from mesh
            if meshState.removeFromMesh(peerID, for: topic) {
                emit(.peerLeftMesh(peer: peerID, topic: topic))
            }

            // Set backoff
            if let backoff = prune.backoff {
                peerState.updatePeer(peerID) { state in
                    state.setBackoff(for: topic, duration: .seconds(Int64(backoff)))
                }
            }

            // Handle peer exchange (v1.1+)
            // prune.peers could be used to discover new peers

            emit(.pruned(peer: peerID, topic: topic, backoff: prune.backoff.map { .seconds(Int64($0)) }))
        }
    }

    /// Handles IDONTWANT messages (v1.2).
    ///
    /// Peers send IDONTWANT to indicate they don't want to receive certain messages.
    /// This is typically used for large messages to prevent duplicate transmissions.
    private func handleIDontWants(
        _ idontwants: [ControlMessage.IDontWant],
        from peerID: PeerID
    ) {
        guard !idontwants.isEmpty else { return }

        // Check if peer supports v1.2
        guard let state = peerState.getPeer(peerID), state.version >= .v12 else {
            // Ignore IDONTWANT from peers that shouldn't send it
            return
        }

        let ttl = configuration.idontwantTTL
        var totalCount = 0

        peerState.updatePeer(peerID) { state in
            for idontwant in idontwants {
                for msgID in idontwant.messageIDs {
                    state.addDontWant(msgID, ttl: ttl)
                    totalCount += 1
                }
            }
        }

        if totalCount > 0 {
            emit(.idontWantReceived(peer: peerID, messageCount: totalCount))
        }
    }

    // MARK: - Publishing

    /// Publishes a message to a topic.
    ///
    /// - Parameters:
    ///   - data: The message data
    ///   - topic: The topic to publish to
    /// - Returns: The published message
    /// - Throws: `GossipSubError.signingKeyRequired` if signing is enabled but no key provided
    public func publish(_ data: Data, to topic: Topic) throws -> GossipSubMessage {
        // Build message
        var builder = GossipSubMessage.Builder(data: data, topic: topic)
            .source(localPeerID)

        // Sign the message if signing is enabled
        if configuration.signMessages {
            guard let key = signingKey else {
                throw GossipSubError.signingKeyRequired
            }
            builder = try builder.sign(with: key)
        } else {
            builder = builder.autoSequenceNumber()
        }

        let message = try builder.build()

        // Mark as seen
        seenCache.add(message.id)

        // Cache the message
        messageCache.put(message)

        // Update fanout timestamp if not subscribed
        if !meshState.isSubscribed(to: topic) {
            meshState.touchFanout(for: topic)
        }

        emit(.messagePublished(topic: topic, messageID: message.id))

        return message
    }

    /// Returns peers to send a published message to.
    ///
    /// - Parameter topic: The topic
    /// - Returns: Array of peer IDs
    public func peersForPublish(topic: Topic) -> [PeerID] {
        var peers = Set<PeerID>()

        if meshState.isSubscribed(to: topic) {
            // Send to mesh peers
            peers.formUnion(meshState.meshPeers(for: topic))
        } else {
            // Send to fanout peers
            peers.formUnion(meshState.fanoutPeers(for: topic))
        }

        // Flood publish if enabled
        if configuration.floodPublish {
            let allSubscribed = peerState.peersSubscribedTo(topic)
            for peer in allSubscribed.prefix(configuration.floodPublishMaxPeers) {
                peers.insert(peer)
            }
        }

        return Array(peers)
    }

    // MARK: - Heartbeat Support

    /// Performs mesh maintenance (called by heartbeat).
    ///
    /// - Returns: Control messages to send
    public func maintainMesh() -> [(peer: PeerID, control: ControlMessageBatch)] {
        var toSend: [(peer: PeerID, control: ControlMessageBatch)] = []

        for topic in meshState.subscribedTopics {
            let meshPeers = meshState.meshPeers(for: topic)
            let meshCount = meshPeers.count
            let D = configuration.meshDegree
            let D_low = configuration.meshDegreeLow
            let D_high = configuration.meshDegreeHigh

            // Need more peers?
            if meshCount < D_low {
                let needed = D - meshCount
                let rawCandidates = peerState.peersNotBackedOff(for: topic)

                // Use scorer to filter graylisted peers and sort by score
                let scoredCandidates = peerScorer.selectBestPeers(from: rawCandidates, count: rawCandidates.count)

                let toGraft = meshState.selectPeersForGraft(
                    topic: topic,
                    count: needed,
                    candidates: scoredCandidates
                )

                for peer in toGraft {
                    meshState.addToMesh(peer, for: topic)
                    emit(.peerJoinedMesh(peer: peer, topic: topic))

                    var batch = ControlMessageBatch()
                    batch.grafts.append(ControlMessage.Graft(topic: topic))
                    toSend.append((peer, batch))

                    emit(.grafted(peer: peer, topic: topic))
                }
            }

            // Too many peers?
            if meshCount > D_high {
                let outboundPeers = Set(peerState.outboundPeersSubscribedTo(topic))
                let toPrune = meshState.selectPeersForPrune(
                    topic: topic,
                    count: D,
                    protectOutbound: configuration.meshOutboundMin,
                    outboundPeers: outboundPeers
                )

                for peer in toPrune {
                    meshState.removeFromMesh(peer, for: topic)
                    emit(.peerLeftMesh(peer: peer, topic: topic))

                    // Set local backoff so we don't accept GRAFT from this peer
                    peerState.updatePeer(peer) { state in
                        state.setBackoff(for: topic, duration: configuration.pruneBackoff)
                    }

                    var batch = ControlMessageBatch()
                    batch.prunes.append(ControlMessage.Prune(
                        topic: topic,
                        backoff: UInt64(configuration.pruneBackoff.components.seconds)
                    ))
                    toSend.append((peer, batch))
                }
            }
        }

        return toSend
    }

    /// Generates gossip messages (IHAVE).
    ///
    /// - Returns: IHAVE messages to send
    public func generateGossip() -> [(peer: PeerID, ihave: ControlMessage.IHave)] {
        var toSend: [(peer: PeerID, ihave: ControlMessage.IHave)] = []

        for topic in meshState.subscribedTopics {
            let messageIDs = messageCache.getGossipIDs(for: topic)
            guard !messageIDs.isEmpty else { continue }

            // Select peers for gossip (not in mesh)
            let meshPeers = meshState.meshPeers(for: topic)
            let allSubscribed = Set(peerState.peersSubscribedTo(topic))
            let gossipPeers = allSubscribed.subtracting(meshPeers)

            // Random selection
            let selected = gossipPeers.shuffled().prefix(configuration.gossipDegree)

            let ihave = ControlMessage.IHave(
                topic: topic,
                messageIDs: Array(messageIDs.prefix(configuration.maxIHaveMessages))
            )

            for peer in selected {
                toSend.append((peer, ihave))
            }
        }

        return toSend
    }

    /// Shifts message cache (called by heartbeat).
    public func shiftMessageCache() {
        messageCache.shift()
    }

    /// Cleans up fanout entries.
    public func cleanupFanout() {
        meshState.cleanupFanout(ttl: configuration.fanoutTTL)
    }

    /// Cleans up seen cache.
    public func cleanupSeenCache() {
        seenCache.cleanup()
    }

    /// Cleans up expired backoffs for all peers.
    public func cleanupBackoffs() {
        peerState.clearExpiredBackoffs()
    }

    /// Cleans up expired IDONTWANT entries for all peers (v1.2).
    public func cleanupIDontWants() {
        peerState.clearExpiredDontWants()
    }

    /// Applies decay to all peer scores.
    ///
    /// Called periodically (e.g., by heartbeat) to allow peers to recover
    /// from penalties over time.
    public func decayPeerScores() {
        peerScorer.applyDecayToAll()
    }

    /// Performs full scoring maintenance including:
    /// - Score decay
    /// - IWANT tracking cleanup
    /// - Delivery rate penalty application
    ///
    /// Call this during heartbeat for complete scoring maintenance.
    public func performScoringMaintenance() {
        peerScorer.applyDecayToAll()
        peerScorer.cleanupIWantTracking()
        let penalizedPeers = peerScorer.applyDeliveryRatePenalties()

        // Emit events for penalized peers
        for (peer, deliveryRate) in penalizedPeers {
            let currentScore = peerScorer.score(for: peer)
            emit(.peerPenalized(
                peer: peer,
                reason: .protocolViolation("Low delivery rate: \(String(format: "%.1f%%", deliveryRate * 100))"),
                score: currentScore
            ))
        }
    }

    // MARK: - Event Emission

    private func emit(_ event: GossipSubEvent) {
        eventState.withLock { state in
            _ = state.continuation?.yield(event)
        }
    }

    // MARK: - Helper Methods

    /// Extracts IP address from a Multiaddr.
    ///
    /// - Parameter addr: The multiaddr to extract from
    /// - Returns: IP address string if found, nil otherwise
    private func extractIP(from addr: Multiaddr) -> String? {
        for proto in addr.protocols {
            switch proto {
            case .ip4(let ip): return ip
            case .ip6(let ip): return ip
            default: continue
            }
        }
        return nil
    }

    // MARK: - Shutdown

    /// Shuts down the router.
    public func shutdown() {
        subscriptions.cancelAll()
        peerState.clear()
        meshState.clear()
        messageCache.clear()
        seenCache.clear()
        peerScorer.clear()

        eventState.withLock { state in
            state.continuation?.finish()
            state.continuation = nil
            state.stream = nil
        }
    }
}
