/// GossipSubConfiguration - Configuration parameters for GossipSub
import Foundation
import P2PCore

/// Configuration for the GossipSub protocol.
public struct GossipSubConfiguration: Sendable {

    // MARK: - Mesh Parameters

    /// Target number of peers in mesh (D).
    public var meshDegree: Int

    /// Lower bound of mesh peers before adding (D_low).
    public var meshDegreeLow: Int

    /// Upper bound of mesh peers before pruning (D_high).
    public var meshDegreeHigh: Int

    /// Number of peers for gossip emission (D_lazy).
    public var gossipDegree: Int

    /// Minimum number of outbound mesh peers (D_out).
    public var meshOutboundMin: Int

    // MARK: - Timing Parameters

    /// Interval between heartbeats.
    public var heartbeatInterval: Duration

    /// Time to live for fanout entries.
    public var fanoutTTL: Duration

    /// Time to live for seen message cache.
    public var seenTTL: Duration

    /// Backoff duration after being pruned.
    public var pruneBackoff: Duration

    /// Backoff duration for unsubscribing.
    public var unsubscribeBackoff: Duration

    /// Connection timeout for grafting.
    public var graftFloodThreshold: Duration

    // MARK: - Cache Parameters

    /// Number of heartbeats to keep messages in cache (mcache_len).
    public var messageCacheLength: Int

    /// Number of heartbeats to include in gossip (mcache_gossip).
    public var messageCacheGossipLength: Int

    /// Maximum size of seen message cache.
    public var seenCacheSize: Int

    // MARK: - Message Parameters

    /// Maximum message size in bytes.
    public var maxMessageSize: Int

    /// Whether to validate message signatures.
    ///
    /// When `true`, incoming messages with signatures will be verified.
    /// Combined with `strictSignatureVerification`, this controls message acceptance:
    /// - `validateSignatures=true`, `strictSignatureVerification=true`: Reject unsigned, verify signed
    /// - `validateSignatures=true`, `strictSignatureVerification=false`: Accept unsigned, verify signed
    /// - `validateSignatures=false`: Accept all messages without signature checks
    public var validateSignatures: Bool

    /// Whether to sign outgoing messages.
    public var signMessages: Bool

    /// Whether to reject messages without signatures.
    ///
    /// Always `true` - messages without signatures are rejected.
    /// This implementation does not support legacy (pre-2020) unsigned messages.
    public var strictSignatureVerification: Bool

    // MARK: - Limits

    /// Maximum number of topics to subscribe to.
    public var maxSubscriptions: Int

    /// Maximum number of peers per topic mesh.
    public var maxPeersPerTopic: Int

    /// Maximum pending grafts.
    public var maxPendingGrafts: Int

    /// Maximum IHAVE message IDs per heartbeat.
    public var maxIHaveMessages: Int

    /// Maximum IWANT message IDs per request.
    public var maxIWantMessages: Int

    // MARK: - IDONTWANT (v1.2)

    /// Time to live for IDONTWANT entries.
    ///
    /// After receiving an IDONTWANT, we remember not to forward the specified
    /// messages to that peer for this duration. The spec recommends 3 seconds.
    public var idontwantTTL: Duration

    /// Message size threshold for sending IDONTWANT (v1.2).
    ///
    /// When receiving a message larger than this threshold, we send IDONTWANT
    /// to other mesh peers to prevent them from sending duplicates.
    /// Set to 0 to disable IDONTWANT sending.
    public var idontwantThreshold: Int

    // MARK: - Per-Topic Scoring (v1.1)

    /// Per-topic scoring parameters keyed by topic.
    ///
    /// Topics with explicit parameters will use these for per-topic scoring.
    /// Topics without explicit parameters fall back to `defaultTopicScoreParams`.
    public var topicScoreParams: [Topic: TopicScoreParams]

    /// Default topic scoring parameters for topics without explicit config.
    ///
    /// When a topic does not have an entry in `topicScoreParams`, these
    /// parameters are used. If nil, the static `TopicScoreParams.default` is used.
    public var defaultTopicScoreParams: TopicScoreParams?

    // MARK: - Opportunistic Grafting (v1.1)

    /// Heartbeat ticks between opportunistic graft attempts.
    ///
    /// Set to 0 to disable. Default: 60 (every 60 heartbeats = ~1 min at 1s interval).
    public var opportunisticGraftTicks: Int

    /// Number of peers to opportunistically graft per topic.
    public var opportunisticGraftPeers: Int

    /// Minimum mesh median score threshold for opportunistic grafting.
    ///
    /// Opportunistic graft triggers when the median score of mesh peers
    /// in a topic is below this threshold.
    public var opportunisticGraftThreshold: Double

    // MARK: - Explicit Peering (v1.1)

    /// Direct peers: unconditionally forward messages and maintain mesh connection.
    ///
    /// Direct peers are NOT subject to scoring, pruning, or backoff.
    /// Messages are always forwarded to direct peers regardless of mesh state.
    /// Key: topic, Value: set of peer IDs.
    public var directPeers: [Topic: Set<PeerID>]

    // MARK: - Custom Message ID (A1)

    /// Custom function for computing message IDs.
    /// Receives the full message and returns a MessageID.
    /// Default: nil (uses source_peer_id || sequence_number).
    public var messageIDFunction: (@Sendable (GossipSubMessage) -> MessageID)?

    // MARK: - Subscription Filter (A2)

    /// Subscription filter for topic subscriptions.
    /// When set, controls which topics can be subscribed to locally
    /// and filters incoming remote subscriptions.
    public var subscriptionFilter: (any TopicSubscriptionFilter)?

    // MARK: - Peer Exchange (A3)

    /// Enable peer exchange in PRUNE messages (v1.1).
    public var enablePeerExchange: Bool

    /// Maximum number of PX peers to include in PRUNE.
    public var prunePeers: Int

    /// Minimum score of the pruning peer to accept its PX peers.
    public var acceptPXThreshold: Double

    // MARK: - IWANT Promise Tracking (A5)

    /// Time to wait for a promised message after IWANT.
    public var iwantFollowupTime: Duration

    // MARK: - Validation Mode (A6)

    /// Validation mode for incoming messages.
    public enum ValidationMode: Sendable {
        /// Require source, seqno, and valid signature.
        case strict
        /// Accept messages without source/seqno/signature, but validate if present.
        case permissive
        /// Reject messages that HAVE source, seqno, or signature (privacy mode).
        case anonymous
        /// No validation at all.
        case none
    }

    /// Authenticity mode for outgoing messages.
    public enum MessageAuthenticity: Sendable {
        /// Sign messages with the provided key.
        case signed
        /// Set source peer ID but don't sign.
        case author
        /// No source, no seqno, no signature (requires custom messageIDFunction).
        case anonymous
    }

    /// Validation mode for incoming messages.
    /// When set, overrides `validateSignatures` / `strictSignatureVerification`.
    public var validationMode: ValidationMode?

    /// Authenticity mode for outgoing messages.
    /// When set, overrides `signMessages`.
    public var messageAuthenticity: MessageAuthenticity?

    // MARK: - Flood Publish

    /// Whether to flood publish to all peers (not just mesh).
    public var floodPublish: Bool

    /// Maximum number of peers for flood publishing.
    public var floodPublishMaxPeers: Int

    // MARK: - Initialization

    /// Creates a configuration with default values.
    public init(
        meshDegree: Int = 6,
        meshDegreeLow: Int = 4,
        meshDegreeHigh: Int = 12,
        gossipDegree: Int = 6,
        meshOutboundMin: Int = 2,
        heartbeatInterval: Duration = .seconds(1),
        fanoutTTL: Duration = .seconds(60),
        seenTTL: Duration = .seconds(120),
        pruneBackoff: Duration = .seconds(60),
        unsubscribeBackoff: Duration = .seconds(10),
        graftFloodThreshold: Duration = .seconds(10),
        messageCacheLength: Int = 5,
        messageCacheGossipLength: Int = 3,
        seenCacheSize: Int = 10000,
        maxMessageSize: Int = 1024 * 1024, // 1 MB
        validateSignatures: Bool = true,
        signMessages: Bool = true,
        strictSignatureVerification: Bool = true,  // Secure default: reject unsigned messages
        maxSubscriptions: Int = 100,
        maxPeersPerTopic: Int = 1000,
        maxPendingGrafts: Int = 100,
        maxIHaveMessages: Int = 5000,
        maxIWantMessages: Int = 5000,
        idontwantTTL: Duration = .seconds(3),
        idontwantThreshold: Int = 1024,  // 1KB - send IDONTWANT for messages >= 1KB
        topicScoreParams: [Topic: TopicScoreParams] = [:],
        defaultTopicScoreParams: TopicScoreParams? = nil,
        opportunisticGraftTicks: Int = 60,
        opportunisticGraftPeers: Int = 2,
        opportunisticGraftThreshold: Double = 1.0,
        directPeers: [Topic: Set<PeerID>] = [:],
        messageIDFunction: (@Sendable (GossipSubMessage) -> MessageID)? = nil,
        subscriptionFilter: (any TopicSubscriptionFilter)? = nil,
        enablePeerExchange: Bool = false,
        prunePeers: Int = 0,
        acceptPXThreshold: Double = 10.0,
        iwantFollowupTime: Duration = .seconds(3),
        validationMode: ValidationMode? = nil,
        messageAuthenticity: MessageAuthenticity? = nil,
        floodPublish: Bool = true,
        floodPublishMaxPeers: Int = 25
    ) {
        self.meshDegree = meshDegree
        self.meshDegreeLow = meshDegreeLow
        self.meshDegreeHigh = meshDegreeHigh
        self.gossipDegree = gossipDegree
        self.meshOutboundMin = meshOutboundMin
        self.heartbeatInterval = heartbeatInterval
        self.fanoutTTL = fanoutTTL
        self.seenTTL = seenTTL
        self.pruneBackoff = pruneBackoff
        self.unsubscribeBackoff = unsubscribeBackoff
        self.graftFloodThreshold = graftFloodThreshold
        self.messageCacheLength = messageCacheLength
        self.messageCacheGossipLength = messageCacheGossipLength
        self.seenCacheSize = seenCacheSize
        self.maxMessageSize = maxMessageSize
        self.validateSignatures = validateSignatures
        self.signMessages = signMessages
        self.strictSignatureVerification = strictSignatureVerification
        self.maxSubscriptions = maxSubscriptions
        self.maxPeersPerTopic = maxPeersPerTopic
        self.maxPendingGrafts = maxPendingGrafts
        self.maxIHaveMessages = maxIHaveMessages
        self.maxIWantMessages = maxIWantMessages
        self.idontwantTTL = idontwantTTL
        self.idontwantThreshold = idontwantThreshold
        self.topicScoreParams = topicScoreParams
        self.defaultTopicScoreParams = defaultTopicScoreParams
        self.opportunisticGraftTicks = opportunisticGraftTicks
        self.opportunisticGraftPeers = opportunisticGraftPeers
        self.opportunisticGraftThreshold = opportunisticGraftThreshold
        self.directPeers = directPeers
        self.messageIDFunction = messageIDFunction
        self.subscriptionFilter = subscriptionFilter
        self.enablePeerExchange = enablePeerExchange
        self.prunePeers = prunePeers
        self.acceptPXThreshold = acceptPXThreshold
        self.iwantFollowupTime = iwantFollowupTime
        self.validationMode = validationMode
        self.messageAuthenticity = messageAuthenticity
        self.floodPublish = floodPublish
        self.floodPublishMaxPeers = floodPublishMaxPeers
    }

    /// Validates the configuration.
    ///
    /// - Throws: If the configuration is invalid
    public func validate() throws {
        guard meshDegreeLow <= meshDegree else {
            throw ConfigurationError.invalidMeshDegree("D_low (\(meshDegreeLow)) must be <= D (\(meshDegree))")
        }
        guard meshDegree <= meshDegreeHigh else {
            throw ConfigurationError.invalidMeshDegree("D (\(meshDegree)) must be <= D_high (\(meshDegreeHigh))")
        }
        guard meshOutboundMin <= meshDegreeLow else {
            throw ConfigurationError.invalidMeshDegree("D_out (\(meshOutboundMin)) must be <= D_low (\(meshDegreeLow))")
        }
        // D_out must be <= D/2 (rust-libp2p constraint)
        guard meshOutboundMin <= meshDegree / 2 else {
            throw ConfigurationError.invalidMeshDegree("D_out (\(meshOutboundMin)) must be <= D/2 (\(meshDegree / 2))")
        }
        guard messageCacheGossipLength <= messageCacheLength else {
            throw ConfigurationError.invalidCacheConfig("mcache_gossip (\(messageCacheGossipLength)) must be <= mcache_len (\(messageCacheLength))")
        }
        // Strict validation requires signed authenticity (source + seqno + signature)
        if let mode = validationMode, mode == .strict {
            if let auth = messageAuthenticity, auth != .signed {
                throw ConfigurationError.incompatibleAuthAndValidation(
                    "Strict validation requires signed authenticity (got \(auth))"
                )
            }
        }
        // Anonymous validation requires anonymous authenticity
        if let mode = validationMode, mode == .anonymous {
            if let auth = messageAuthenticity, auth != .anonymous {
                throw ConfigurationError.incompatibleAuthAndValidation(
                    "Anonymous validation requires anonymous authenticity (got \(auth))"
                )
            }
        }
        // Anonymous authenticity requires compatible validation mode
        if let auth = messageAuthenticity, auth == .anonymous {
            if let mode = validationMode, mode == .strict {
                throw ConfigurationError.incompatibleAuthAndValidation(
                    "Anonymous authenticity requires anonymous or permissive validation mode"
                )
            }
        }
        // Anonymous validation requires custom messageIDFunction
        if validationMode == .anonymous && messageIDFunction == nil {
            throw ConfigurationError.anonymousModeRequiresCustomMessageID
        }
    }

    /// Configuration validation errors.
    public enum ConfigurationError: Error, Sendable {
        case invalidMeshDegree(String)
        case invalidCacheConfig(String)
        case incompatibleAuthAndValidation(String)
        case anonymousModeRequiresCustomMessageID
    }
}

// MARK: - MessageValidator

/// Application-level message validator for GossipSub (v1.1).
///
/// Validators are called after structure and signature checks pass.
/// Return `.accept` to continue delivery, `.reject` to penalize the sender,
/// or `.ignore` to drop the message without penalty.
public protocol MessageValidator: Sendable {
    func validate(
        message: GossipSubMessage,
        from peer: PeerID
    ) async -> GossipSubMessage.ValidationResult
}

// MARK: - Presets

extension GossipSubConfiguration {
    /// Configuration for high-throughput scenarios.
    public static var highThroughput: GossipSubConfiguration {
        var config = GossipSubConfiguration()
        config.meshDegree = 8
        config.meshDegreeLow = 6
        config.meshDegreeHigh = 16
        config.gossipDegree = 8
        config.messageCacheLength = 10
        config.messageCacheGossipLength = 5
        return config
    }

    /// Configuration for low-bandwidth scenarios.
    public static var lowBandwidth: GossipSubConfiguration {
        var config = GossipSubConfiguration()
        config.meshDegree = 4
        config.meshDegreeLow = 2
        config.meshDegreeHigh = 8
        config.gossipDegree = 4
        config.messageCacheLength = 3
        config.messageCacheGossipLength = 2
        return config
    }

    /// Configuration for testing (faster heartbeat, lenient signatures).
    public static var testing: GossipSubConfiguration {
        var config = GossipSubConfiguration()
        config.heartbeatInterval = .milliseconds(100)
        config.fanoutTTL = .seconds(5)
        config.seenTTL = .seconds(10)
        config.pruneBackoff = .seconds(5)
        // Lenient for testing scenarios that don't require signing
        config.validateSignatures = false
        config.signMessages = false
        config.strictSignatureVerification = false
        return config
    }
}
