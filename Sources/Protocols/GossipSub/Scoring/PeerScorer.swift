/// PeerScorer - Peer score tracking for GossipSub protocol.
///
/// Tracks penalties for various peer behaviors and provides score-based
/// peer selection for mesh management.

import Foundation
import Synchronization
import P2PCore

/// Configuration for PeerScorer.
public struct PeerScorerConfig: Sendable {
    /// Penalty for sending invalid messages.
    public var invalidMessagePenalty: Double

    /// Penalty for sending duplicate messages (minor).
    public var duplicateMessagePenalty: Double

    /// Penalty for GRAFT during backoff period.
    public var graftBackoffPenalty: Double

    /// Penalty for broken promise (IHAVE but no message on IWANT).
    public var brokenPromisePenalty: Double

    /// Penalty for excessive IWANT requests.
    public var excessiveIWantPenalty: Double

    /// Penalty for topic mismatch (message sent to wrong topic).
    public var topicMismatchPenalty: Double

    /// Decay factor applied periodically to scores.
    /// Scores are multiplied by this factor each decay interval.
    /// Example: 0.9 means 10% decay per interval.
    public var decayFactor: Double

    /// Interval between score decays.
    public var decayInterval: Duration

    /// Threshold below which a peer is considered graylisted.
    /// Graylisted peers are excluded from mesh selection.
    public var graylistThreshold: Double

    // MARK: - IWANT Tracking

    /// Number of duplicate IWANT requests for the same message before penalty.
    /// When a peer requests the same message this many times, they get penalized.
    public var iwantDuplicateThreshold: Int

    /// Time window for IWANT tracking (requests outside this window are forgotten).
    public var iwantTrackingWindow: Duration

    // MARK: - Delivery Tracking

    /// Bonus for being the first peer to deliver a message.
    public var firstDeliveryBonus: Double

    /// Minimum expected delivery rate for mesh peers.
    /// Peers below this rate receive penalties during heartbeat.
    public var minDeliveryRate: Double

    /// Penalty per unit below minimum delivery rate.
    public var lowDeliveryPenalty: Double

    // MARK: - IP Colocation (Sybil Defense)

    /// Number of peers from the same IP before applying colocation penalty.
    /// Set to 0 to disable IP colocation tracking.
    public var ipColocationThreshold: Int

    /// Penalty per excess peer from the same IP.
    public var ipColocationPenalty: Double

    /// Creates a new configuration with default values.
    public init(
        invalidMessagePenalty: Double = -100.0,
        duplicateMessagePenalty: Double = -1.0,
        graftBackoffPenalty: Double = -10.0,
        brokenPromisePenalty: Double = -50.0,
        excessiveIWantPenalty: Double = -10.0,
        topicMismatchPenalty: Double = -50.0,
        decayFactor: Double = 0.9,
        decayInterval: Duration = .seconds(60),
        graylistThreshold: Double = -1000.0,
        iwantDuplicateThreshold: Int = 3,
        iwantTrackingWindow: Duration = .seconds(60),
        firstDeliveryBonus: Double = 5.0,
        minDeliveryRate: Double = 0.8,
        lowDeliveryPenalty: Double = -20.0,
        ipColocationThreshold: Int = 2,
        ipColocationPenalty: Double = -10.0
    ) {
        self.invalidMessagePenalty = invalidMessagePenalty
        self.duplicateMessagePenalty = duplicateMessagePenalty
        self.graftBackoffPenalty = graftBackoffPenalty
        self.brokenPromisePenalty = brokenPromisePenalty
        self.excessiveIWantPenalty = excessiveIWantPenalty
        self.topicMismatchPenalty = topicMismatchPenalty
        self.decayFactor = decayFactor
        self.decayInterval = decayInterval
        self.graylistThreshold = graylistThreshold
        self.iwantDuplicateThreshold = iwantDuplicateThreshold
        self.iwantTrackingWindow = iwantTrackingWindow
        self.firstDeliveryBonus = firstDeliveryBonus
        self.minDeliveryRate = minDeliveryRate
        self.lowDeliveryPenalty = lowDeliveryPenalty
        self.ipColocationThreshold = ipColocationThreshold
        self.ipColocationPenalty = ipColocationPenalty
    }

    /// Default configuration.
    public static let `default` = PeerScorerConfig()
}

/// Tracks peer scores for GossipSub mesh management.
///
/// Scores are affected by:
/// - Invalid messages: Large penalty
/// - Duplicate messages: Small penalty
/// - Protocol violations (GRAFT during backoff): Medium penalty
/// - Broken promises (IHAVE without message): Medium penalty
/// - Excessive IWANT requests: Medium penalty
/// - Low delivery rate: Penalty based on rate
/// - IP colocation (Sybil defense): Penalty for multiple peers on same IP
/// - Per-topic scoring (v1.1): Time-in-mesh, first deliveries, mesh deliveries, invalid messages
///
/// Scores decay over time, allowing peers to recover from penalties.
/// Peers below the graylist threshold are excluded from mesh selection.
public final class PeerScorer: Sendable {

    // MARK: - Properties

    /// Configuration.
    public let config: PeerScorerConfig

    /// Per-peer score state.
    private let scores: Mutex<[PeerID: PeerScore]>

    /// IWANT request tracking state.
    private let iwantTracking: Mutex<IWantTrackingState>

    /// Delivery tracking state.
    private let deliveryTracking: Mutex<DeliveryTrackingState>

    /// IP colocation tracking state.
    private let ipColocation: Mutex<IPColocationState>

    /// Per-topic per-peer state for v1.1 topic scoring.
    private let topicState: Mutex<[PeerID: [Topic: TopicPeerState]]>

    /// Per-topic scoring parameters (topic -> params).
    private let topicParams: [Topic: TopicScoreParams]

    /// Default topic scoring parameters for topics without explicit config.
    private let defaultTopicParams: TopicScoreParams?

    private struct PeerScore: Sendable {
        var score: Double = 0.0
        var lastDecay: ContinuousClock.Instant = .now
    }

    /// Per-topic state tracked for each peer.
    private struct TopicPeerState: Sendable {
        /// When the peer joined the mesh for this topic (nil if not in mesh).
        var meshJoinedAt: ContinuousClock.Instant?
        /// Counter for first message deliveries in this topic.
        var firstMessageDeliveries: Double = 0
        /// Counter for mesh message deliveries in this topic.
        var meshMessageDeliveries: Double = 0
        /// Accumulated mesh failure penalty for this topic.
        var meshFailurePenalty: Double = 0
        /// Counter for invalid message deliveries in this topic.
        var invalidMessageDeliveries: Double = 0
    }

    /// State for tracking IWANT requests per peer per message.
    private struct IWantTrackingState: Sendable {
        /// Per-peer IWANT request counts: [PeerID: [MessageID: (count, firstRequestTime)]]
        var requests: [PeerID: [MessageID: IWantRequest]] = [:]

        struct IWantRequest: Sendable {
            var count: Int
            var firstRequestTime: ContinuousClock.Instant
        }
    }

    /// State for tracking message delivery per peer.
    private struct DeliveryTrackingState: Sendable {
        /// Per-peer delivery stats: [PeerID: DeliveryStats]
        var stats: [PeerID: DeliveryStats] = [:]

        struct DeliveryStats: Sendable {
            /// Number of messages expected from this peer (while in mesh).
            var messagesExpected: Int = 0
            /// Number of messages actually delivered by this peer.
            var messagesDelivered: Int = 0
            /// Number of first deliveries (peer was first to deliver).
            var firstDeliveries: Int = 0
        }
    }

    /// State for tracking IP colocation.
    private struct IPColocationState: Sendable {
        /// IP address to set of peer IDs.
        var peersByIP: [String: Set<PeerID>] = [:]
        /// Peer ID to IP address (for reverse lookup).
        var ipByPeer: [PeerID: String] = [:]
    }

    /// Result of checking IWANT request.
    public enum IWantCheckResult: Sendable {
        /// Request is acceptable.
        case accepted
        /// Request exceeds threshold (penalty should be applied).
        case excessive(count: Int)
    }

    /// Result of IP colocation check.
    public struct IPColocationCheckResult: Sendable {
        /// Whether a penalty was applied.
        public let penaltyApplied: Bool
        /// Number of peers on the same IP.
        public let peerCount: Int
        /// The IP address (normalized).
        public let ipAddress: String
    }

    // MARK: - Initialization

    /// Creates a new peer scorer.
    ///
    /// - Parameters:
    ///   - config: Scoring configuration.
    ///   - topicParams: Per-topic scoring parameters keyed by topic.
    ///   - defaultTopicParams: Default topic scoring parameters for topics without explicit config.
    public init(
        config: PeerScorerConfig = .default,
        topicParams: [Topic: TopicScoreParams] = [:],
        defaultTopicParams: TopicScoreParams? = nil
    ) {
        self.config = config
        self.topicParams = topicParams
        self.defaultTopicParams = defaultTopicParams
        self.scores = Mutex([:])
        self.iwantTracking = Mutex(IWantTrackingState())
        self.deliveryTracking = Mutex(DeliveryTrackingState())
        self.ipColocation = Mutex(IPColocationState())
        self.topicState = Mutex([:])
    }

    // MARK: - Penalty Recording

    /// Records an invalid message penalty for a peer.
    ///
    /// - Parameter peer: The peer that sent the invalid message.
    public func recordInvalidMessage(from peer: PeerID) {
        applyPenalty(to: peer, amount: config.invalidMessagePenalty)
    }

    /// Records a duplicate message penalty for a peer.
    ///
    /// - Parameter peer: The peer that sent the duplicate.
    public func recordDuplicateMessage(from peer: PeerID) {
        applyPenalty(to: peer, amount: config.duplicateMessagePenalty)
    }

    /// Records a GRAFT-during-backoff penalty for a peer.
    ///
    /// - Parameter peer: The peer that violated backoff.
    public func recordGraftDuringBackoff(from peer: PeerID) {
        applyPenalty(to: peer, amount: config.graftBackoffPenalty)
    }

    /// Records a broken promise penalty (IHAVE without delivering message).
    ///
    /// - Parameter peer: The peer that broke the promise.
    public func recordBrokenPromise(from peer: PeerID) {
        applyPenalty(to: peer, amount: config.brokenPromisePenalty)
    }

    /// Records an excessive IWANT penalty.
    ///
    /// - Parameter peer: The peer sending too many IWANTs.
    public func recordExcessiveIWant(from peer: PeerID) {
        applyPenalty(to: peer, amount: config.excessiveIWantPenalty)
    }

    /// Records a topic mismatch penalty.
    ///
    /// - Parameter peer: The peer that sent a message to the wrong topic.
    public func recordTopicMismatch(from peer: PeerID) {
        applyPenalty(to: peer, amount: config.topicMismatchPenalty)
    }

    /// Applies a custom penalty amount.
    ///
    /// - Parameters:
    ///   - peer: The peer to penalize.
    ///   - amount: The penalty amount (negative for penalties).
    public func applyPenalty(to peer: PeerID, amount: Double) {
        scores.withLock { scores in
            var peerScore = scores[peer] ?? PeerScore()
            peerScore.score += amount
            scores[peer] = peerScore
        }
    }

    // MARK: - IWANT Tracking

    /// Tracks an IWANT request for a specific message from a peer.
    ///
    /// Call this method for each message ID in an IWANT request. If the same
    /// peer requests the same message too many times, this method returns
    /// `.excessive` and the caller should apply a penalty.
    ///
    /// - Parameters:
    ///   - peer: The peer making the IWANT request.
    ///   - messageID: The message ID being requested.
    /// - Returns: Result indicating whether the request is acceptable or excessive.
    public func trackIWantRequest(from peer: PeerID, for messageID: MessageID) -> IWantCheckResult {
        iwantTracking.withLock { state in
            let now = ContinuousClock.now

            // Initialize peer's request map if needed
            if state.requests[peer] == nil {
                state.requests[peer] = [:]
            }

            // Get or create request entry
            if var request = state.requests[peer]?[messageID] {
                // Check if the request is still within tracking window
                if now - request.firstRequestTime < config.iwantTrackingWindow {
                    request.count += 1
                    state.requests[peer]?[messageID] = request

                    if request.count >= config.iwantDuplicateThreshold {
                        return .excessive(count: request.count)
                    }
                } else {
                    // Window expired, reset
                    state.requests[peer]?[messageID] = IWantTrackingState.IWantRequest(
                        count: 1,
                        firstRequestTime: now
                    )
                }
            } else {
                // First request for this message
                state.requests[peer]?[messageID] = IWantTrackingState.IWantRequest(
                    count: 1,
                    firstRequestTime: now
                )
            }

            return .accepted
        }
    }

    /// Cleans up expired IWANT tracking entries.
    ///
    /// Call this periodically (e.g., during heartbeat) to prevent memory leaks.
    public func cleanupIWantTracking() {
        iwantTracking.withLock { state in
            let now = ContinuousClock.now

            for (peer, requests) in state.requests {
                var filteredRequests: [MessageID: IWantTrackingState.IWantRequest] = [:]
                for (msgID, request) in requests {
                    if now - request.firstRequestTime < config.iwantTrackingWindow {
                        filteredRequests[msgID] = request
                    }
                }
                if filteredRequests.isEmpty {
                    state.requests.removeValue(forKey: peer)
                } else {
                    state.requests[peer] = filteredRequests
                }
            }
        }
    }

    // MARK: - Delivery Tracking

    /// Records a message delivery from a peer.
    ///
    /// - Parameters:
    ///   - peer: The peer that delivered the message.
    ///   - isFirst: Whether this peer was the first to deliver this message.
    public func recordMessageDelivery(from peer: PeerID, isFirst: Bool) {
        deliveryTracking.withLock { state in
            var stats = state.stats[peer] ?? DeliveryTrackingState.DeliveryStats()
            stats.messagesDelivered += 1
            if isFirst {
                stats.firstDeliveries += 1
            }
            state.stats[peer] = stats
        }

        // Apply first delivery bonus
        if isFirst {
            applyPenalty(to: peer, amount: config.firstDeliveryBonus)
        }
    }

    /// Records that a message was expected from a mesh peer.
    ///
    /// Call this for each mesh peer when a message is published to a topic.
    /// This is used to calculate delivery rate.
    ///
    /// - Parameter peer: The mesh peer expected to deliver the message.
    public func recordExpectedMessage(from peer: PeerID) {
        deliveryTracking.withLock { state in
            var stats = state.stats[peer] ?? DeliveryTrackingState.DeliveryStats()
            stats.messagesExpected += 1
            state.stats[peer] = stats
        }
    }

    /// Calculates and applies delivery rate penalties for all tracked peers.
    ///
    /// Call this periodically (e.g., during heartbeat) to penalize peers
    /// with low delivery rates.
    ///
    /// - Returns: Dictionary of peers that received penalties with their delivery rates.
    @discardableResult
    public func applyDeliveryRatePenalties() -> [PeerID: Double] {
        var penalizedPeers: [PeerID: Double] = [:]
        var penalties: [(PeerID, Double)] = []

        deliveryTracking.withLock { state in
            for (peer, stats) in state.stats {
                guard stats.messagesExpected > 0 else { continue }

                let deliveryRate = Double(stats.messagesDelivered) / Double(stats.messagesExpected)
                if deliveryRate < config.minDeliveryRate {
                    let deficit = config.minDeliveryRate - deliveryRate
                    let penalty = config.lowDeliveryPenalty * deficit
                    penalizedPeers[peer] = deliveryRate
                    penalties.append((peer, penalty))
                }
            }
        }

        // Apply penalties outside of deliveryTracking lock to avoid nested locks
        if !penalties.isEmpty {
            scores.withLock { scores in
                for (peer, penalty) in penalties {
                    var peerScore = scores[peer] ?? PeerScore()
                    peerScore.score += penalty
                    scores[peer] = peerScore
                }
            }
        }

        return penalizedPeers
    }

    /// Resets delivery tracking statistics for all peers.
    ///
    /// Call this periodically (e.g., at longer intervals) to reset counters.
    public func resetDeliveryTracking() {
        deliveryTracking.withLock { state in
            state.stats.removeAll()
        }
    }

    // MARK: - IP Colocation Tracking

    /// Registers a peer's IP address for colocation tracking.
    ///
    /// This method tracks how many peers share the same IP address. When the
    /// count exceeds the threshold, all peers on that IP receive penalties.
    ///
    /// - Parameters:
    ///   - peer: The peer ID.
    ///   - ip: The peer's IP address.
    /// - Returns: Result of the colocation check.
    @discardableResult
    public func registerPeerIP(_ peer: PeerID, ip: String) -> IPColocationCheckResult {
        // Skip if IP colocation tracking is disabled
        guard config.ipColocationThreshold > 0 else {
            return IPColocationCheckResult(penaltyApplied: false, peerCount: 0, ipAddress: ip)
        }

        let normalizedIP = normalizeIP(ip)

        let (result, pendingPenalties) = ipColocation.withLock { state -> (IPColocationCheckResult, [(PeerID, Double)]?) in
            // Remove from old IP if exists
            if let oldIP = state.ipByPeer[peer] {
                state.peersByIP[oldIP]?.remove(peer)
                if state.peersByIP[oldIP]?.isEmpty == true {
                    state.peersByIP.removeValue(forKey: oldIP)
                }
            }

            // Register new IP
            state.ipByPeer[peer] = normalizedIP
            state.peersByIP[normalizedIP, default: []].insert(peer)

            let peerCount = state.peersByIP[normalizedIP]?.count ?? 0

            // Check threshold
            if peerCount > config.ipColocationThreshold {
                let excessPeers = peerCount - config.ipColocationThreshold
                let penalty = config.ipColocationPenalty * Double(excessPeers)

                // Collect penalties to apply outside of lock
                let affectedPeers = state.peersByIP[normalizedIP] ?? []
                let penalties = affectedPeers.map { ($0, penalty) }

                return (
                    IPColocationCheckResult(
                        penaltyApplied: true,
                        peerCount: peerCount,
                        ipAddress: normalizedIP
                    ),
                    penalties
                )
            }

            return (
                IPColocationCheckResult(
                    penaltyApplied: false,
                    peerCount: peerCount,
                    ipAddress: normalizedIP
                ),
                nil
            )
        }

        // Apply penalties outside of ipColocation lock to avoid nested locks
        if let penalties = pendingPenalties {
            scores.withLock { scores in
                for (affectedPeer, penalty) in penalties {
                    var peerScore = scores[affectedPeer] ?? PeerScore()
                    peerScore.score += penalty
                    scores[affectedPeer] = peerScore
                }
            }
        }

        return result
    }

    /// Returns the number of peers sharing the same IP as the given peer.
    ///
    /// - Parameter peer: The peer ID.
    /// - Returns: Number of peers on the same IP, or 0 if not tracked.
    public func peersOnSameIP(as peer: PeerID) -> Int {
        ipColocation.withLock { state in
            guard let ip = state.ipByPeer[peer] else { return 0 }
            return state.peersByIP[ip]?.count ?? 0
        }
    }

    /// Normalizes an IP address for comparison.
    ///
    /// Handles IPv4 and IPv6 addresses, including IPv4-mapped IPv6 addresses.
    private func normalizeIP(_ ip: String) -> String {
        var normalized = ip.lowercased()

        // Handle IPv4-mapped IPv6 addresses (::ffff:192.0.2.1 → 192.0.2.1)
        if normalized.hasPrefix("::ffff:") {
            normalized = String(normalized.dropFirst(7))
        }

        // Remove zone ID from IPv6 (fe80::1%eth0 → fe80::1)
        if let percentIndex = normalized.firstIndex(of: "%") {
            normalized = String(normalized[..<percentIndex])
        }

        return normalized
    }

    // MARK: - Score Query

    /// Returns the current score for a peer.
    ///
    /// Applies decay if enough time has passed since the last decay.
    ///
    /// - Parameter peer: The peer ID.
    /// - Returns: The peer's current score (0 if no score recorded).
    public func score(for peer: PeerID) -> Double {
        scores.withLock { scores in
            applyDecayIfNeeded(for: peer, in: &scores)
            return scores[peer]?.score ?? 0.0
        }
    }

    /// Returns whether a peer is graylisted (score below threshold).
    ///
    /// Graylisted peers should be excluded from mesh selection.
    ///
    /// - Parameter peer: The peer ID.
    /// - Returns: `true` if the peer is graylisted.
    public func isGraylisted(_ peer: PeerID) -> Bool {
        computeScore(for: peer) < config.graylistThreshold
    }

    /// Returns all peers with their current scores.
    ///
    /// - Returns: Dictionary of peer IDs to scores.
    public func allScores() -> [PeerID: Double] {
        scores.withLock { scores in
            var result: [PeerID: Double] = [:]
            for peer in scores.keys {
                applyDecayIfNeeded(for: peer, in: &scores)
                result[peer] = scores[peer]?.score ?? 0.0
            }
            return result
        }
    }

    // MARK: - Per-Topic Scoring

    /// Records that a peer has joined the mesh for a topic.
    ///
    /// - Parameters:
    ///   - peer: The peer that joined the mesh.
    ///   - topic: The topic the peer joined.
    public func peerJoinedMesh(_ peer: PeerID, topic: Topic) {
        topicState.withLock { states in
            var peerTopics = states[peer] ?? [:]
            var ts = peerTopics[topic] ?? TopicPeerState()
            ts.meshJoinedAt = ContinuousClock.now
            peerTopics[topic] = ts
            states[peer] = peerTopics
        }
    }

    /// Records that a peer has left the mesh for a topic.
    ///
    /// If the peer had a mesh message delivery deficit at the time of leaving,
    /// the deficit is recorded as a mesh failure penalty.
    ///
    /// - Parameters:
    ///   - peer: The peer that left the mesh.
    ///   - topic: The topic the peer left.
    public func peerLeftMesh(_ peer: PeerID, topic: Topic) {
        let params = resolveTopicParams(topic)

        topicState.withLock { states in
            var peerTopics = states[peer] ?? [:]
            var ts = peerTopics[topic] ?? TopicPeerState()

            // Check if we should apply mesh failure penalty (P3b).
            // If the peer had a delivery deficit when leaving, record it.
            if let joinedAt = ts.meshJoinedAt {
                let timeInMesh = ContinuousClock.now - joinedAt
                if timeInMesh >= params.meshMessageDeliveriesActivation {
                    let deficit = params.meshMessageDeliveriesThreshold - ts.meshMessageDeliveries
                    if deficit > 0 {
                        ts.meshFailurePenalty += deficit * deficit
                    }
                }
            }

            ts.meshJoinedAt = nil
            peerTopics[topic] = ts
            states[peer] = peerTopics
        }
    }

    /// Records a first message delivery from a peer in a topic.
    ///
    /// This increments the P2 (first message deliveries) counter for the topic,
    /// capped at the configured maximum.
    ///
    /// - Parameters:
    ///   - peer: The peer that delivered the message first.
    ///   - topic: The topic the message was delivered in.
    public func recordFirstMessageDelivery(from peer: PeerID, topic: Topic) {
        let params = resolveTopicParams(topic)

        topicState.withLock { states in
            var peerTopics = states[peer] ?? [:]
            var ts = peerTopics[topic] ?? TopicPeerState()
            ts.firstMessageDeliveries = min(
                ts.firstMessageDeliveries + 1,
                params.firstMessageDeliveriesCap
            )
            peerTopics[topic] = ts
            states[peer] = peerTopics
        }
    }

    /// Records a mesh message delivery from a peer in a topic.
    ///
    /// This increments the P3 (mesh message deliveries) counter for the topic,
    /// capped at the configured maximum.
    ///
    /// - Parameters:
    ///   - peer: The peer that delivered the message in the mesh.
    ///   - topic: The topic the message was delivered in.
    public func recordMeshMessageDelivery(from peer: PeerID, topic: Topic) {
        let params = resolveTopicParams(topic)

        topicState.withLock { states in
            var peerTopics = states[peer] ?? [:]
            var ts = peerTopics[topic] ?? TopicPeerState()
            ts.meshMessageDeliveries = min(
                ts.meshMessageDeliveries + 1,
                params.meshMessageDeliveriesCap
            )
            peerTopics[topic] = ts
            states[peer] = peerTopics
        }
    }

    /// Records an invalid message delivery from a peer in a topic.
    ///
    /// This increments the P4 (invalid message deliveries) counter for the topic.
    ///
    /// - Parameters:
    ///   - peer: The peer that delivered the invalid message.
    ///   - topic: The topic the invalid message was in.
    public func recordInvalidMessageDelivery(from peer: PeerID, topic: Topic) {
        topicState.withLock { states in
            var peerTopics = states[peer] ?? [:]
            var ts = peerTopics[topic] ?? TopicPeerState()
            ts.invalidMessageDeliveries += 1
            peerTopics[topic] = ts
            states[peer] = peerTopics
        }
    }

    /// Records a mesh failure for a peer in a topic.
    ///
    /// This directly adds to the P3b (mesh failure penalty) counter.
    ///
    /// - Parameters:
    ///   - peer: The peer that had a mesh failure.
    ///   - topic: The topic the failure occurred in.
    public func recordMeshFailure(peer: PeerID, topic: Topic) {
        topicState.withLock { states in
            var peerTopics = states[peer] ?? [:]
            var ts = peerTopics[topic] ?? TopicPeerState()
            ts.meshFailurePenalty += 1
            peerTopics[topic] = ts
            states[peer] = peerTopics
        }
    }

    /// Computes the combined score for a peer (global + per-topic).
    ///
    /// The total score is: globalScore + sum(topicWeight_i * topicScore_i)
    ///
    /// Per-topic score components (per GossipSub v1.1 spec):
    /// - P1: Time in mesh bonus
    /// - P2: First message deliveries bonus
    /// - P3: Mesh message delivery deficit penalty (after activation window)
    /// - P3b: Mesh failure penalty
    /// - P4: Invalid message deliveries penalty
    ///
    /// - Parameter peer: The peer to compute the score for.
    /// - Returns: The combined global and per-topic score.
    public func computeScore(for peer: PeerID) -> Double {
        let globalScore = score(for: peer)
        let now = ContinuousClock.now

        let topicScore = topicState.withLock { states -> Double in
            guard let peerTopics = states[peer] else { return 0.0 }

            var total = 0.0

            for (topic, ts) in peerTopics {
                let params = resolveTopicParams(topic)

                // P1: Time in Mesh
                let p1: Double
                if let joinedAt = ts.meshJoinedAt {
                    let timeInMesh = now - joinedAt
                    let quantumSeconds = Self.durationToSeconds(params.timeInMeshQuantum)
                    let timeInMeshSeconds = Self.durationToSeconds(timeInMesh)
                    let quanta = quantumSeconds > 0 ? timeInMeshSeconds / quantumSeconds : 0
                    p1 = params.timeInMeshWeight * min(quanta, params.timeInMeshCap)
                } else {
                    p1 = 0
                }

                // P2: First Message Deliveries
                let p2 = params.firstMessageDeliveriesWeight * min(
                    ts.firstMessageDeliveries,
                    params.firstMessageDeliveriesCap
                )

                // P3: Mesh Message Delivery Deficit
                let p3: Double
                if let joinedAt = ts.meshJoinedAt {
                    let timeInMesh = now - joinedAt
                    if timeInMesh >= params.meshMessageDeliveriesActivation {
                        let deficit = params.meshMessageDeliveriesThreshold - ts.meshMessageDeliveries
                        if deficit > 0 {
                            p3 = params.meshMessageDeliveriesWeight * deficit * deficit
                        } else {
                            p3 = 0
                        }
                    } else {
                        p3 = 0
                    }
                } else {
                    p3 = 0
                }

                // P3b: Mesh Failure Penalty
                let p3b = params.meshFailurePenaltyWeight * ts.meshFailurePenalty

                // P4: Invalid Messages
                let p4 = params.invalidMessageDeliveriesWeight * ts.invalidMessageDeliveries * ts.invalidMessageDeliveries

                let topicScoreValue = p1 + p2 + p3 + p3b + p4
                total += params.topicWeight * topicScoreValue
            }

            return total
        }

        return globalScore + topicScore
    }

    /// Resolves topic scoring parameters for a given topic.
    ///
    /// Returns the explicit params for the topic if configured,
    /// otherwise the default topic params, otherwise the static default.
    ///
    /// - Parameter topic: The topic to resolve parameters for.
    /// - Returns: The resolved topic scoring parameters.
    private func resolveTopicParams(_ topic: Topic) -> TopicScoreParams {
        topicParams[topic] ?? defaultTopicParams ?? .default
    }

    /// Converts a Duration to seconds as a Double.
    ///
    /// - Parameter duration: The duration to convert.
    /// - Returns: The duration in seconds.
    private static func durationToSeconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }

    // MARK: - Peer Selection

    /// Sorts peers by score (highest first).
    ///
    /// - Parameter peers: The peers to sort.
    /// - Returns: Peers sorted by descending score.
    public func sortByScore(_ peers: [PeerID]) -> [PeerID] {
        let peerScores = peers.map { (peer: $0, score: computeScore(for: $0)) }
        return peerScores.sorted { $0.score > $1.score }.map(\.peer)
    }

    /// Filters out graylisted peers from a list.
    ///
    /// - Parameter peers: The peers to filter.
    /// - Returns: Non-graylisted peers.
    public func filterGraylisted(_ peers: [PeerID]) -> [PeerID] {
        peers.filter { !isGraylisted($0) }
    }

    /// Selects the best peers from a list, excluding graylisted peers.
    ///
    /// - Parameters:
    ///   - peers: The candidate peers.
    ///   - count: Maximum number of peers to select.
    /// - Returns: Up to `count` non-graylisted peers, sorted by score.
    public func selectBestPeers(from peers: [PeerID], count: Int) -> [PeerID] {
        let filtered = filterGraylisted(peers)
        let sorted = sortByScore(filtered)
        return Array(sorted.prefix(count))
    }

    // MARK: - Decay

    /// Applies decay to all peer scores including per-topic counters.
    ///
    /// Called periodically (e.g., by heartbeat) to allow peers to recover.
    public func applyDecayToAll() {
        scores.withLock { scores in
            for peer in scores.keys {
                applyDecayIfNeeded(for: peer, in: &scores)
            }
        }

        // Apply per-topic decay
        topicState.withLock { states in
            for (peer, var peerTopics) in states {
                for (topic, var ts) in peerTopics {
                    let params = resolveTopicParams(topic)
                    ts.firstMessageDeliveries *= params.firstMessageDeliveriesDecay
                    ts.meshMessageDeliveries *= params.meshMessageDeliveriesDecay
                    ts.meshFailurePenalty *= params.meshFailurePenaltyDecay
                    ts.invalidMessageDeliveries *= params.invalidMessageDeliveriesDecay
                    peerTopics[topic] = ts
                }
                states[peer] = peerTopics
            }
        }
    }

    /// Applies decay to a specific peer's score if enough time has passed.
    private func applyDecayIfNeeded(for peer: PeerID, in scores: inout [PeerID: PeerScore]) {
        guard var peerScore = scores[peer] else { return }

        let now = ContinuousClock.now
        let elapsed = now - peerScore.lastDecay

        // Only apply decay if interval has passed
        if elapsed >= config.decayInterval {
            let decayPeriods = Int(elapsed / config.decayInterval)
            peerScore.score *= pow(config.decayFactor, Double(decayPeriods))
            peerScore.lastDecay = now

            // Remove scores that have decayed to near-zero to prevent memory leak
            if abs(peerScore.score) < 0.001 {
                scores.removeValue(forKey: peer)
            } else {
                scores[peer] = peerScore
            }
        }
    }

    // MARK: - Cleanup

    /// Removes all tracking entries for a peer (e.g., when peer disconnects).
    ///
    /// - Parameter peer: The peer to remove.
    public func removePeer(_ peer: PeerID) {
        _ = scores.withLock { scores in
            scores.removeValue(forKey: peer)
        }

        _ = iwantTracking.withLock { state in
            state.requests.removeValue(forKey: peer)
        }

        _ = deliveryTracking.withLock { state in
            state.stats.removeValue(forKey: peer)
        }

        ipColocation.withLock { state in
            if let ip = state.ipByPeer.removeValue(forKey: peer) {
                state.peersByIP[ip]?.remove(peer)
                if state.peersByIP[ip]?.isEmpty == true {
                    state.peersByIP.removeValue(forKey: ip)
                }
            }
        }

        _ = topicState.withLock { states in
            states.removeValue(forKey: peer)
        }
    }

    /// Clears all scores and tracking state.
    public func clear() {
        scores.withLock { scores in
            scores.removeAll()
        }

        iwantTracking.withLock { state in
            state.requests.removeAll()
        }

        deliveryTracking.withLock { state in
            state.stats.removeAll()
        }

        ipColocation.withLock { state in
            state.peersByIP.removeAll()
            state.ipByPeer.removeAll()
        }

        topicState.withLock { states in
            states.removeAll()
        }
    }
}
