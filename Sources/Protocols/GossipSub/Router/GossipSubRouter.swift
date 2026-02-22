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

    /// Per-topic message validators (v1.1).
    private let validators: Mutex<[Topic: any MessageValidator]>

    /// Direct (explicit) peer state (v1.1).
    private let directPeerState: Mutex<[Topic: Set<PeerID>]>

    /// IWANT promise tracking (A5).
    let gossipPromises: GossipPromises

    /// Event channel.
    private let channel = EventChannel<GossipSubEvent>()

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
        self.peerScorer = PeerScorer(
            config: peerScorerConfig,
            topicParams: configuration.topicScoreParams,
            defaultTopicParams: configuration.defaultTopicScoreParams
        )
        self.validators = Mutex([:])
        self.directPeerState = Mutex(configuration.directPeers)
        self.gossipPromises = GossipPromises()
        // Sync protected peers from initial direct peer configuration
        let allDirectPeers = configuration.directPeers.values
            .reduce(into: Set<PeerID>()) { $0.formUnion($1) }
        if !allDirectPeers.isEmpty {
            peerScorer.setProtectedPeers(allDirectPeers)
        }
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
        validators.withLock { $0[topic] = validator }
    }

    /// Unregisters the message validator for a topic.
    ///
    /// - Parameter topic: The topic to remove the validator for
    public func unregisterValidator(for topic: Topic) {
        validators.withLock { _ = $0.removeValue(forKey: topic) }
    }

    // MARK: - Direct Peer Management (v1.1)

    /// Adds a direct peer for a topic.
    ///
    /// Direct peers are unconditionally included in message forwarding and
    /// are protected from pruning, scoring penalties, and backoff enforcement.
    ///
    /// - Parameters:
    ///   - peer: The peer ID to add as direct
    ///   - topic: The topic
    public func addDirectPeer(_ peer: PeerID, for topic: Topic) {
        directPeerState.withLock { state in
            _ = state[topic, default: []].insert(peer)
            peerScorer.addProtectedPeer(peer)
        }
        emit(.directPeerAdded(peer: peer, topic: topic))
    }

    /// Removes a direct peer from a topic.
    ///
    /// - Parameters:
    ///   - peer: The peer ID to remove
    ///   - topic: The topic
    public func removeDirectPeer(_ peer: PeerID, from topic: Topic) {
        let removed = directPeerState.withLock { state -> Bool in
            guard var peers = state[topic] else { return false }
            let removed = peers.remove(peer) != nil
            if peers.isEmpty {
                state.removeValue(forKey: topic)
            } else {
                state[topic] = peers
            }
            if removed {
                let stillDirect = state.values.contains { $0.contains(peer) }
                if !stillDirect {
                    peerScorer.removeProtectedPeer(peer)
                }
            }
            return removed
        }
        if removed {
            emit(.directPeerRemoved(peer: peer, topic: topic))
        }
    }

    /// Returns whether a peer is a direct peer for any topic.
    func isDirectPeer(_ peer: PeerID) -> Bool {
        directPeerState.withLock { state in
            state.values.contains { $0.contains(peer) }
        }
    }

    /// Returns direct peers for a topic.
    func directPeers(for topic: Topic) -> Set<PeerID> {
        directPeerState.withLock { $0[topic] ?? [] }
    }

    // MARK: - Event Stream

    /// Event stream for monitoring router events.
    public var events: AsyncStream<GossipSubEvent> { channel.stream }

    // MARK: - Subscription Management

    /// Subscribes to a topic.
    ///
    /// - Parameter topic: The topic to subscribe to
    /// - Returns: A subscription for receiving messages
    public func subscribe(to topic: Topic) throws -> Subscription {
        // Check subscription filter (A2)
        if let filter = configuration.subscriptionFilter {
            guard filter.canSubscribe(to: topic) else {
                throw GossipSubError.subscriptionNotAllowed(topic)
            }
        }

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

        // Filter incoming subscriptions (A2)
        var filteredSubs = rpc.subscriptions
        if let filter = configuration.subscriptionFilter {
            let currentSubs = peerState.getPeer(peerID)?.subscriptions ?? []
            do {
                filteredSubs = try filter.filterIncomingSubscriptions(
                    rpc.subscriptions,
                    currentlySubscribed: currentSubs
                )
            } catch {
                // Filter rejected entire RPC batch — discard
                return RPCHandleResult()
            }
        }

        // Handle subscriptions
        for sub in filteredSubs {
            handleSubscription(sub, from: peerID)
        }

        // Handle messages and collect forwards
        for message in rpc.messages {
            let forwards = await handleMessage(message, from: peerID)
            forwardMessages.append(contentsOf: forwards)
        }

        // Handle control messages (FloodSub peers do not use control messages)
        if let control = rpc.control {
            // FloodSub backward compatibility: ignore control messages from FloodSub peers
            // FloodSub does not support mesh management (GRAFT/PRUNE/IHAVE/IWANT)
            let peerVersion = peerState.getPeer(peerID)?.version
            if peerVersion != .floodsub {
                let (controlResponse, iwantMessages) = await handleControl(control, from: peerID)
                if !controlResponse.isEmpty {
                    response.control = controlResponse
                }
                // Include IWANT response messages in the response
                if !iwantMessages.isEmpty {
                    response.messages.append(contentsOf: iwantMessages)
                }
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
                peerScorer.peerLeftMesh(peerID, topic: sub.topic)
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
    ) async -> [(peer: PeerID, rpc: GossipSubRPC)] {
        // Reject messages from graylisted peers
        if peerScorer.isGraylisted(peerID) {
            emit(.peerPenalized(
                peer: peerID,
                reason: .protocolViolation("message from graylisted peer"),
                score: peerScorer.score(for: peerID)
            ))
            return []
        }

        // Recompute message ID if custom function is set (A1)
        let effectiveMessage: GossipSubMessage
        if let idFn = configuration.messageIDFunction {
            let newID = idFn(message)
            if newID != message.id {
                effectiveMessage = GossipSubMessage(
                    id: newID,
                    source: message.source,
                    data: message.data,
                    sequenceNumber: message.sequenceNumber,
                    topic: message.topic,
                    signature: message.signature,
                    key: message.key
                )
            } else {
                effectiveMessage = message
            }
        } else {
            effectiveMessage = message
        }

        // === Dedup Phase ===
        // Check if already seen (before validation to avoid redundant work)
        let isFirstDelivery = seenCache.add(effectiveMessage.id)
        if !isFirstDelivery {
            // Duplicate - record penalty and don't forward
            peerScorer.recordDuplicateMessage(from: peerID)
            return []
        }

        // Resolve IWANT promises (A5)
        gossipPromises.messageDelivered(effectiveMessage.id)

        // === Validation Phase ===
        // Validate message structure
        guard effectiveMessage.validateStructure() else {
            // Invalid message structure - record penalty
            peerScorer.recordInvalidMessage(from: peerID)
            peerScorer.recordInvalidMessageDelivery(from: peerID, topic: effectiveMessage.topic)
            emit(.messageValidated(messageID: effectiveMessage.id, result: .reject))
            return []
        }

        // Determine effective validation mode (A6)
        let effectiveValidationMode: GossipSubConfiguration.ValidationMode
        if let mode = configuration.validationMode {
            effectiveValidationMode = mode
        } else if configuration.validateSignatures {
            effectiveValidationMode = configuration.strictSignatureVerification ? .strict : .permissive
        } else {
            effectiveValidationMode = .none
        }

        // Validate based on mode (A6)
        switch effectiveValidationMode {
        case .strict:
            guard effectiveMessage.signature != nil, effectiveMessage.source != nil, !effectiveMessage.sequenceNumber.isEmpty else {
                peerScorer.recordInvalidMessage(from: peerID)
                peerScorer.recordInvalidMessageDelivery(from: peerID, topic: effectiveMessage.topic)
                emit(.messageValidated(messageID: effectiveMessage.id, result: .reject))
                return []
            }
            guard effectiveMessage.verifySignature() else {
                peerScorer.recordInvalidMessage(from: peerID)
                peerScorer.recordInvalidMessageDelivery(from: peerID, topic: effectiveMessage.topic)
                emit(.messageValidated(messageID: effectiveMessage.id, result: .reject))
                return []
            }

        case .permissive:
            if effectiveMessage.signature != nil {
                guard effectiveMessage.verifySignature() else {
                    peerScorer.recordInvalidMessage(from: peerID)
                    peerScorer.recordInvalidMessageDelivery(from: peerID, topic: effectiveMessage.topic)
                    emit(.messageValidated(messageID: effectiveMessage.id, result: .reject))
                    return []
                }
            }

        case .anonymous:
            // Reject messages that have source, seqno, or signature
            guard effectiveMessage.source == nil else {
                peerScorer.recordInvalidMessage(from: peerID)
                emit(.messageValidated(messageID: effectiveMessage.id, result: .reject))
                return []
            }
            guard effectiveMessage.sequenceNumber.isEmpty else {
                peerScorer.recordInvalidMessage(from: peerID)
                emit(.messageValidated(messageID: effectiveMessage.id, result: .reject))
                return []
            }
            guard effectiveMessage.signature == nil else {
                peerScorer.recordInvalidMessage(from: peerID)
                emit(.messageValidated(messageID: effectiveMessage.id, result: .reject))
                return []
            }

        case .none:
            break
        }

        // === Application Validation Phase (v1.1 Extended Validators) ===
        let validator = validators.withLock { $0[effectiveMessage.topic] }
        if let validator = validator {
            let result = await validator.validate(message: effectiveMessage, from: peerID)
            switch result {
            case .accept:
                break  // Continue to delivery
            case .reject:
                peerScorer.recordInvalidMessage(from: peerID)
                peerScorer.recordInvalidMessageDelivery(from: peerID, topic: effectiveMessage.topic)
                emit(.messageValidated(messageID: effectiveMessage.id, result: .reject))
                return []
            case .ignore:
                emit(.messageValidated(messageID: effectiveMessage.id, result: .ignore))
                return []  // No penalty, no forward
            }
        }

        // === Scoring Phase ===
        // Track message delivery AFTER validation succeeds
        // This prevents attackers from gaining first-delivery bonus with invalid messages
        peerScorer.recordMessageDelivery(from: peerID, isFirst: true)

        // Per-topic scoring: record first message delivery
        peerScorer.recordFirstMessageDelivery(from: peerID, topic: effectiveMessage.topic)

        // Per-topic scoring: record mesh message delivery if peer is in the mesh
        if meshState.meshPeers(for: effectiveMessage.topic).contains(peerID) {
            peerScorer.recordMeshMessageDelivery(from: peerID, topic: effectiveMessage.topic)
        }

        // === Delivery Phase ===
        // Cache the message
        messageCache.put(effectiveMessage)

        // Deliver to local subscribers
        subscriptions.deliver(effectiveMessage)

        // Emit event
        emit(.messageReceived(topic: effectiveMessage.topic, message: effectiveMessage))

        // Forward to mesh peers (except sender)
        var forwards = forwardMessage(effectiveMessage, excluding: peerID)

        // === IDONTWANT Phase (v1.2) ===
        // Send IDONTWANT to mesh peers for large messages
        let threshold = configuration.idontwantThreshold
        if threshold > 0 && effectiveMessage.data.count >= threshold {
            let idontwantForwards = sendIDontWant(for: effectiveMessage, excluding: peerID)
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

    /// Forwards a message to mesh peers, direct peers, and FloodSub peers.
    ///
    /// - Returns: List of (peer, RPC) tuples for forwarding
    private func forwardMessage(
        _ message: GossipSubMessage,
        excluding: PeerID
    ) -> [(peer: PeerID, rpc: GossipSubRPC)] {
        let topic = message.topic
        var targetPeers = meshState.meshPeers(for: topic)
        // Always include direct peers (v1.1)
        targetPeers.formUnion(directPeers(for: topic))

        // FloodSub backward compatibility: include all FloodSub peers subscribed to this topic
        // FloodSub peers do not participate in mesh management and receive all messages for subscribed topics
        let subscribedPeers = peerState.peersSubscribedTo(topic)
        for peer in subscribedPeers {
            if let state = peerState.getPeer(peer), state.version == .floodsub {
                targetPeers.insert(peer)
            }
        }

        var forwards: [(peer: PeerID, rpc: GossipSubRPC)] = []
        let rpc = GossipSubRPC(messages: [message])

        for peer in targetPeers where peer != excluding {
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

        // Record IWANT promises (A5)
        let expiry = ContinuousClock.now + configuration.iwantFollowupTime
        gossipPromises.addPromise(
            peer: peerID,
            messageIDs: Array(wantedIDs),
            expires: expiry
        )

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
            // Direct peers bypass backoff enforcement (v1.1)
            if let state = peerState.getPeer(peerID), state.isBackedOff(for: topic),
               !isDirectPeer(peerID) {
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
                peerScorer.peerJoinedMesh(peerID, topic: topic)
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
        var pxPeersToConnect: [PeerID] = []

        for prune in prunes {
            let topic = prune.topic

            // Remove from mesh
            if meshState.removeFromMesh(peerID, for: topic) {
                peerScorer.peerLeftMesh(peerID, topic: topic)
                emit(.peerLeftMesh(peer: peerID, topic: topic))
            }

            // Set backoff
            if let backoff = prune.backoff {
                peerState.updatePeer(peerID) { state in
                    state.setBackoff(for: topic, duration: .seconds(Int64(backoff)))
                }
            }

            // Handle peer exchange (A3, v1.1+)
            if !prune.peers.isEmpty {
                let senderScore = peerScorer.score(for: peerID)
                if senderScore >= configuration.acceptPXThreshold {
                    let pxCandidates = prune.peers
                        .map(\.peerID)
                        .filter { $0 != localPeerID }
                        .prefix(max(configuration.prunePeers, prune.peers.count))

                    pxPeersToConnect.append(contentsOf: pxCandidates)
                    emit(.peerExchangeReceived(
                        peer: peerID,
                        topic: topic,
                        pxPeerCount: pxCandidates.count
                    ))
                } else {
                    emit(.peerExchangeRejected(
                        peer: peerID,
                        topic: topic,
                        reason: .scoreBelowThreshold(
                            score: senderScore,
                            threshold: configuration.acceptPXThreshold
                        )
                    ))
                }
            }

            emit(.pruned(peer: peerID, topic: topic, backoff: prune.backoff.map { .seconds(Int64($0)) }))
        }

        // Emit PX connect requests for Node integration
        if !pxPeersToConnect.isEmpty {
            emit(.peerExchangeConnect(peers: pxPeersToConnect))
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
        guard data.count <= configuration.maxMessageSize else {
            throw GossipSubError.messageTooLarge(
                size: data.count,
                maxSize: configuration.maxMessageSize
            )
        }

        // Determine effective authenticity mode (A6)
        let authenticity = configuration.messageAuthenticity ?? (configuration.signMessages ? .signed : .author)

        // Build message based on authenticity mode
        let message: GossipSubMessage
        switch authenticity {
        case .signed:
            guard let key = signingKey else {
                throw GossipSubError.signingKeyRequired
            }
            var builder = GossipSubMessage.Builder(data: data, topic: topic)
                .source(localPeerID)
            builder = try builder.sign(with: key)
            message = try builder.build(messageIDFunction: configuration.messageIDFunction)

        case .author:
            let builder = GossipSubMessage.Builder(data: data, topic: topic)
                .source(localPeerID)
                .autoSequenceNumber()
            message = try builder.build(messageIDFunction: configuration.messageIDFunction)

        case .anonymous:
            guard configuration.messageIDFunction != nil else {
                throw GossipSubError.anonymousModeRequiresCustomMessageID
            }
            // No source, no seqno, no signature
            let builder = GossipSubMessage.Builder(data: data, topic: topic)
            message = try builder.build(messageIDFunction: configuration.messageIDFunction)
        }

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

        // Always include direct peers (v1.1)
        peers.formUnion(directPeers(for: topic))

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
            let D_out = configuration.meshOutboundMin

            // Step 1: Need more peers?
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
                    peerScorer.peerJoinedMesh(peer, topic: topic)
                    emit(.peerJoinedMesh(peer: peer, topic: topic))

                    var batch = ControlMessageBatch()
                    batch.grafts.append(ControlMessage.Graft(topic: topic))
                    toSend.append((peer, batch))

                    emit(.grafted(peer: peer, topic: topic))
                }
            }

            // Step 2: Too many peers?
            if meshCount > D_high {
                let directPeersForTopic = directPeers(for: topic)
                let outboundPeers = Set(peerState.outboundPeersSubscribedTo(topic))
                let toPrune = meshState.selectPeersForPrune(
                    topic: topic,
                    count: D,
                    protectOutbound: D_out,
                    outboundPeers: outboundPeers
                ).filter { !directPeersForTopic.contains($0) }  // Protect direct peers

                for peer in toPrune {
                    meshState.removeFromMesh(peer, for: topic)
                    peerScorer.peerLeftMesh(peer, topic: topic)
                    emit(.peerLeftMesh(peer: peer, topic: topic))

                    // Set local backoff so we don't accept GRAFT from this peer
                    peerState.updatePeer(peer) { state in
                        state.setBackoff(for: topic, duration: configuration.pruneBackoff)
                    }

                    // Include PX peers in PRUNE (A3)
                    // rust-libp2p: candidates are all connected peers subscribed to the topic
                    // with score >= 0, not just mesh peers
                    var pxPeers: [ControlMessage.Prune.PeerInfo] = []
                    if configuration.enablePeerExchange && configuration.prunePeers > 0 {
                        let allSubscribed = peerState.peersSubscribedTo(topic)
                        let candidates = allSubscribed
                            .filter { $0 != peer && $0 != localPeerID && peerScorer.score(for: $0) >= 0 }
                            .shuffled()
                            .prefix(configuration.prunePeers)
                        pxPeers = candidates.map { candidate in
                            ControlMessage.Prune.PeerInfo(peerID: candidate, signedPeerRecord: nil)
                        }
                    }

                    var batch = ControlMessageBatch()
                    batch.prunes.append(ControlMessage.Prune(
                        topic: topic,
                        peers: pxPeers,
                        backoff: UInt64(configuration.pruneBackoff.components.seconds)
                    ))
                    toSend.append((peer, batch))
                }
            }

            // Step 3: Outbound quota enforcement (A4)
            // Even if mesh >= D_low, ensure D_out outbound peers are present
            let currentMeshPeers = meshState.meshPeers(for: topic)
            let currentOutbound = currentMeshPeers.filter { peer in
                peerState.getPeer(peer)?.direction == .outbound
            }.count

            if currentOutbound < D_out {
                let needed = D_out - currentOutbound
                let outboundCandidates = peerState.peersNotBackedOff(for: topic)
                    .filter { peer in
                        guard let state = peerState.getPeer(peer) else { return false }
                        return state.direction == .outbound
                            && !currentMeshPeers.contains(peer)
                            && !isDirectPeer(peer)
                            && peerScorer.score(for: peer) >= 0
                    }
                    .shuffled()
                    .prefix(needed)

                for peer in outboundCandidates {
                    meshState.addToMesh(peer, for: topic)
                    peerScorer.peerJoinedMesh(peer, topic: topic)
                    emit(.peerJoinedMesh(peer: peer, topic: topic))

                    var batch = ControlMessageBatch()
                    batch.grafts.append(ControlMessage.Graft(topic: topic))
                    toSend.append((peer, batch))

                    emit(.outboundQuotaGraft(peer: peer, topic: topic, outboundCount: currentOutbound))
                }
            }
        }

        return toSend
    }

    /// Opportunistically grafts high-scoring peers when mesh quality is low (v1.1).
    ///
    /// From GossipSub v1.1 spec: If the median score of mesh peers is below
    /// the threshold, graft the best non-mesh peers to improve mesh quality.
    ///
    /// - Returns: Control messages to send (GRAFT)
    public func opportunisticGraft() -> [(peer: PeerID, control: ControlMessageBatch)] {
        var toSend: [(peer: PeerID, control: ControlMessageBatch)] = []

        for topic in meshState.subscribedTopics {
            let meshPeers = Array(meshState.meshPeers(for: topic))
            guard !meshPeers.isEmpty else { continue }

            // Exclude direct peers from median calculation (v1.1 spec).
            // Protected peers always return score 0.0 which would
            // artificially lower the median and trigger false grafts.
            let scoredMeshPeers = meshPeers.filter { !isDirectPeer($0) }
            guard !scoredMeshPeers.isEmpty else { continue }

            // Calculate median score of non-direct mesh peers
            let scores = scoredMeshPeers.map { peerScorer.computeScore(for: $0) }.sorted()
            let medianScore = scores[scores.count / 2]

            // Only graft if mesh quality is low
            guard medianScore < configuration.opportunisticGraftThreshold else { continue }

            // Find high-scoring non-mesh peers subscribed to this topic
            // Also exclude direct peers from candidates (they are already forwarded to)
            let allSubscribed = peerState.peersSubscribedTo(topic)
            let meshSet = meshState.meshPeers(for: topic)
            let nonMesh = allSubscribed.filter { !meshSet.contains($0) && !isDirectPeer($0) }
            let candidates = peerScorer.selectBestPeers(
                from: nonMesh,
                count: configuration.opportunisticGraftPeers
            )

            for peer in candidates {
                // Only graft peers with score above the median
                let peerScore = peerScorer.computeScore(for: peer)
                guard peerScore > medianScore else { continue }

                meshState.addToMesh(peer, for: topic)
                peerScorer.peerJoinedMesh(peer, topic: topic)
                emit(.peerJoinedMesh(peer: peer, topic: topic))

                var batch = ControlMessageBatch()
                batch.grafts.append(ControlMessage.Graft(topic: topic))
                toSend.append((peer, batch))

                emit(.opportunisticGraft(peer: peer, topic: topic, medianScore: medianScore))
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

    /// Checks for broken IWANT promises and applies penalties (A5).
    ///
    /// - Returns: Dictionary of peers with broken promise counts
    public func checkBrokenPromises() -> [PeerID: Int] {
        let broken = gossipPromises.getBrokenPromises()
        for (peer, count) in broken {
            peerScorer.applyBehaviourPenalty(to: peer, count: count)
            emit(.brokenPromisesDetected(peer: peer, count: count))
        }
        return broken
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
        channel.yield(event)
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
    public func shutdown() async {
        subscriptions.cancelAll()
        peerState.clear()
        meshState.clear()
        messageCache.clear()
        seenCache.clear()
        peerScorer.clear()
        gossipPromises.clear()
        validators.withLock { $0.removeAll() }
        directPeerState.withLock { $0.removeAll() }

        channel.finish()
    }
}
