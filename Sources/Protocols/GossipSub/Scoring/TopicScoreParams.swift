/// TopicScoreParams - Per-topic scoring parameters following GossipSub v1.1 spec.
///
/// Each topic can have its own set of scoring parameters that control how peers
/// are evaluated within that topic's mesh. The overall peer score includes a
/// weighted sum of per-topic scores.
///
/// Reference: https://github.com/libp2p/specs/blob/master/pubsub/gossipsub/gossipsub-v1.1.md#peer-scoring

import Foundation

/// Per-topic scoring parameters following GossipSub v1.1 spec.
public struct TopicScoreParams: Sendable {

    /// Weight of this topic in the overall score.
    public var topicWeight: Double

    // MARK: - P1: Time in Mesh

    /// Weight applied to the time-in-mesh counter.
    /// A positive weight rewards peers for staying in the mesh.
    public var timeInMeshWeight: Double

    /// The time quantum for the time-in-mesh counter.
    /// The counter is incremented by 1 for each quantum spent in the mesh.
    public var timeInMeshQuantum: Duration

    /// Maximum value for the time-in-mesh counter (in quanta).
    /// This caps the bonus a peer can earn from staying in the mesh.
    public var timeInMeshCap: Double

    // MARK: - P2: First Message Deliveries

    /// Weight applied to the first-message-deliveries counter.
    /// A positive weight rewards peers for being the first to deliver messages.
    public var firstMessageDeliveriesWeight: Double

    /// Decay factor for the first-message-deliveries counter.
    /// Applied each decay interval.
    public var firstMessageDeliveriesDecay: Double

    /// Maximum value for the first-message-deliveries counter.
    public var firstMessageDeliveriesCap: Double

    // MARK: - P3: Mesh Message Deliveries

    /// Weight applied to the mesh-message-delivery deficit.
    /// A negative weight penalizes peers that are not delivering enough messages.
    public var meshMessageDeliveriesWeight: Double

    /// Decay factor for the mesh-message-deliveries counter.
    public var meshMessageDeliveriesDecay: Double

    /// Threshold below which the peer is penalized for insufficient deliveries.
    public var meshMessageDeliveriesThreshold: Double

    /// Maximum value for the mesh-message-deliveries counter.
    public var meshMessageDeliveriesCap: Double

    /// Time after joining the mesh before the mesh-message-deliveries penalty is active.
    /// This gives peers time to warm up after joining.
    public var meshMessageDeliveriesActivation: Duration

    /// Window within which mesh-message-deliveries are counted after first seeing a message.
    public var meshMessageDeliveriesWindow: Duration

    // MARK: - P3b: Mesh Failure Penalty

    /// Weight applied to the mesh-failure-penalty counter.
    /// A negative weight penalizes peers that have been pruned while having a deficit.
    public var meshFailurePenaltyWeight: Double

    /// Decay factor for the mesh-failure-penalty counter.
    public var meshFailurePenaltyDecay: Double

    // MARK: - P4: Invalid Messages

    /// Weight applied to the invalid-message-deliveries counter.
    /// A negative weight penalizes peers that deliver invalid messages.
    public var invalidMessageDeliveriesWeight: Double

    /// Decay factor for the invalid-message-deliveries counter.
    public var invalidMessageDeliveriesDecay: Double

    // MARK: - Initialization

    /// Creates per-topic scoring parameters with specified or default values.
    ///
    /// - Parameters:
    ///   - topicWeight: Weight of this topic in the overall score.
    ///   - timeInMeshWeight: Weight for time-in-mesh counter (P1).
    ///   - timeInMeshQuantum: Time quantum for time-in-mesh counter.
    ///   - timeInMeshCap: Maximum value for time-in-mesh counter.
    ///   - firstMessageDeliveriesWeight: Weight for first-message-deliveries counter (P2).
    ///   - firstMessageDeliveriesDecay: Decay for first-message-deliveries counter.
    ///   - firstMessageDeliveriesCap: Cap for first-message-deliveries counter.
    ///   - meshMessageDeliveriesWeight: Weight for mesh-message-deliveries deficit (P3).
    ///   - meshMessageDeliveriesDecay: Decay for mesh-message-deliveries counter.
    ///   - meshMessageDeliveriesThreshold: Threshold for mesh-message-deliveries deficit.
    ///   - meshMessageDeliveriesCap: Cap for mesh-message-deliveries counter.
    ///   - meshMessageDeliveriesActivation: Activation delay for mesh-message-deliveries penalty.
    ///   - meshMessageDeliveriesWindow: Window for counting mesh-message-deliveries.
    ///   - meshFailurePenaltyWeight: Weight for mesh-failure penalty (P3b).
    ///   - meshFailurePenaltyDecay: Decay for mesh-failure penalty.
    ///   - invalidMessageDeliveriesWeight: Weight for invalid-message-deliveries (P4).
    ///   - invalidMessageDeliveriesDecay: Decay for invalid-message-deliveries counter.
    public init(
        topicWeight: Double = 1.0,
        timeInMeshWeight: Double = 0.0027,
        timeInMeshQuantum: Duration = .seconds(1),
        timeInMeshCap: Double = 3600,
        firstMessageDeliveriesWeight: Double = 1.0,
        firstMessageDeliveriesDecay: Double = 0.9997,
        firstMessageDeliveriesCap: Double = 100,
        meshMessageDeliveriesWeight: Double = -1.0,
        meshMessageDeliveriesDecay: Double = 0.997,
        meshMessageDeliveriesThreshold: Double = 20,
        meshMessageDeliveriesCap: Double = 100,
        meshMessageDeliveriesActivation: Duration = .seconds(30),
        meshMessageDeliveriesWindow: Duration = .seconds(5),
        meshFailurePenaltyWeight: Double = -1.0,
        meshFailurePenaltyDecay: Double = 0.997,
        invalidMessageDeliveriesWeight: Double = -99.0,
        invalidMessageDeliveriesDecay: Double = 0.9994
    ) {
        self.topicWeight = topicWeight
        self.timeInMeshWeight = timeInMeshWeight
        self.timeInMeshQuantum = timeInMeshQuantum
        self.timeInMeshCap = timeInMeshCap
        self.firstMessageDeliveriesWeight = firstMessageDeliveriesWeight
        self.firstMessageDeliveriesDecay = firstMessageDeliveriesDecay
        self.firstMessageDeliveriesCap = firstMessageDeliveriesCap
        self.meshMessageDeliveriesWeight = meshMessageDeliveriesWeight
        self.meshMessageDeliveriesDecay = meshMessageDeliveriesDecay
        self.meshMessageDeliveriesThreshold = meshMessageDeliveriesThreshold
        self.meshMessageDeliveriesCap = meshMessageDeliveriesCap
        self.meshMessageDeliveriesActivation = meshMessageDeliveriesActivation
        self.meshMessageDeliveriesWindow = meshMessageDeliveriesWindow
        self.meshFailurePenaltyWeight = meshFailurePenaltyWeight
        self.meshFailurePenaltyDecay = meshFailurePenaltyDecay
        self.invalidMessageDeliveriesWeight = invalidMessageDeliveriesWeight
        self.invalidMessageDeliveriesDecay = invalidMessageDeliveriesDecay
    }

    /// Default per-topic scoring parameters.
    public static let `default` = TopicScoreParams()
}
