import Foundation
import Synchronization
import P2PCore

/// Events produced by the aggregation layer when processing discovery events.
public enum AggregationResult: Sendable {
    /// A new unconfirmed sighting was created from a Tier 1/2 beacon.
    case newSighting(UnconfirmedSighting)

    /// An existing sighting's presence score was updated.
    case sightingUpdated(truncID: UInt16, newScore: Double)

    /// A new confirmed peer record was created from a Tier 3 beacon.
    case newConfirmed(ConfirmedPeerRecord)

    /// An existing confirmed record's presence score was updated.
    case confirmedUpdated(PeerID, newScore: Double)

    /// An unconfirmed sighting was promoted to a confirmed record.
    case promoted(from: UInt16, to: ConfirmedPeerRecord)
}

/// A discovery event received from the coordination layer.
public struct BeaconDiscoveryEvent: Sendable {
    /// The beacon tier that produced this event.
    public let tier: BeaconTier

    /// Truncated peer ID (Tier 1/2 only).
    public let truncID: UInt16?

    /// Full peer ID (Tier 3 only).
    public let fullPeerID: PeerID?

    /// The transport address where the beacon was received.
    public let source: OpaqueAddress

    /// Raw RSSI value in dBm, if available.
    public let rssi: Double?

    /// Physical-layer fingerprint for Sybil detection.
    public let physicalFingerprint: PhysicalFingerprint?

    /// When this event was observed.
    public let timestamp: ContinuousClock.Instant

    /// Pre-computed trust value for this direct observation.
    public let directObservationTrust: Double

    /// Signed envelope (Tier 3 only).
    public let envelope: Envelope?

    public init(
        tier: BeaconTier,
        truncID: UInt16? = nil,
        fullPeerID: PeerID? = nil,
        source: OpaqueAddress,
        rssi: Double? = nil,
        physicalFingerprint: PhysicalFingerprint? = nil,
        timestamp: ContinuousClock.Instant = .now,
        directObservationTrust: Double,
        envelope: Envelope? = nil
    ) {
        self.tier = tier
        self.truncID = truncID
        self.fullPeerID = fullPeerID
        self.source = source
        self.rssi = rssi
        self.physicalFingerprint = physicalFingerprint
        self.timestamp = timestamp
        self.directObservationTrust = directObservationTrust
        self.envelope = envelope
    }
}

/// Coordination-to-aggregation pipeline: processes discovery events and routes them
/// to sighting or confirmed storage.
///
/// Handles RSSI smoothing, Bayesian presence estimation, and record management.
/// Produces `AggregationResult` events for downstream consumers.
public final class AggregationIngest: Sendable {

    private let store: any BeaconPeerStore
    private let smoother: RSSISmoother
    private let eventState: Mutex<EventState>

    struct EventState: Sendable {
        var continuation: AsyncStream<AggregationResult>.Continuation?
        var stream: AsyncStream<AggregationResult>?
    }

    /// Creates a new aggregation ingest pipeline.
    ///
    /// - Parameter store: The peer record store to use for persistence.
    public init(store: any BeaconPeerStore) {
        self.store = store
        self.smoother = RSSISmoother()
        self.eventState = Mutex(EventState())
    }

    /// Stream of aggregation results. Lazily created, single consumer.
    public var aggregationEvents: AsyncStream<AggregationResult> {
        eventState.withLock { state in
            if let existing = state.stream {
                return existing
            }
            let (stream, continuation) = AsyncStream<AggregationResult>.makeStream()
            state.stream = stream
            state.continuation = continuation
            return stream
        }
    }

    /// Processes a discovery event from the coordination layer.
    ///
    /// - Tier 1/2 events create or update unconfirmed sightings.
    /// - Tier 3 events verify the envelope signature and create or update confirmed records.
    public func ingest(_ event: BeaconDiscoveryEvent) {
        switch event.tier {
        case .tier1, .tier2:
            ingestUnconfirmed(event)
        case .tier3:
            ingestConfirmed(event)
        }
    }

    /// Shuts down the event stream, finishing the continuation.
    public func shutdown() {
        eventState.withLock { state in
            state.continuation?.finish()
            state.continuation = nil
            state.stream = nil
        }
    }

    // MARK: - Private

    private func ingestUnconfirmed(_ event: BeaconDiscoveryEvent) {
        guard let truncID = event.truncID else { return }

        let smoothedRSSI: Double? = if let rssi = event.rssi {
            smoother.smooth(rawRSSI: rssi, from: event.source)
        } else {
            nil
        }

        let observation = BeaconObservation(
            timestamp: event.timestamp,
            mediumID: event.source.mediumID,
            rssi: smoothedRSSI,
            address: event.source,
            freshnessFunction: freshnessFunction(for: event.source.mediumID)
        )

        let existingSightings = store.sightings(matching: truncID)
        let result: AggregationResult

        if var existing = existingSightings.first {
            if !existing.addresses.contains(event.source) {
                existing.addresses.append(event.source)
            }
            existing.observations.append(observation)
            existing.presenceScore = BayesianPresence.presenceScore(observations: existing.observations)
            store.addSighting(existing)
            result = .sightingUpdated(truncID: truncID, newScore: existing.presenceScore)
        } else {
            var sighting = UnconfirmedSighting(
                truncID: truncID,
                addresses: [event.source],
                observations: [observation],
                presenceScore: 0
            )
            sighting.presenceScore = BayesianPresence.presenceScore(observations: sighting.observations)
            store.addSighting(sighting)
            result = .newSighting(sighting)
        }

        emit(result)
    }

    private func ingestConfirmed(_ event: BeaconDiscoveryEvent) {
        guard let envelope = event.envelope else { return }

        // Verify envelope signature using the BeaconPeerRecord domain
        do {
            let _ = try envelope.open(domain: BeaconPeerRecord.domain)
        } catch {
            return // Invalid signature
        }

        guard let fullPeerID = event.fullPeerID else { return }

        let smoothedRSSI: Double? = if let rssi = event.rssi {
            smoother.smooth(rawRSSI: rssi, from: event.source)
        } else {
            nil
        }

        let observation = BeaconObservation(
            timestamp: event.timestamp,
            mediumID: event.source.mediumID,
            rssi: smoothedRSSI,
            address: event.source,
            freshnessFunction: freshnessFunction(for: event.source.mediumID)
        )

        // Extract sequence number and verify PeerID matches wire identity
        let epoch: UInt64
        do {
            let record = try envelope.record(as: BeaconPeerRecord.self)
            guard record.peerID == fullPeerID else { return }
            epoch = record.seq
        } catch {
            return
        }

        let result: AggregationResult

        if let existing = store.get(fullPeerID) {
            var observations = existing.observations
            observations.append(observation)
            let newScore = BayesianPresence.presenceScore(observations: observations)
            var addresses = existing.addresses
            if !addresses.contains(event.source) {
                addresses.append(event.source)
            }
            let updated = ConfirmedPeerRecord(
                peerID: fullPeerID,
                addresses: addresses,
                observations: observations,
                presenceScore: newScore,
                certificate: envelope,
                epoch: epoch,
                expiresAt: existing.expiresAt
            )
            store.upsert(updated)
            result = .confirmedUpdated(fullPeerID, newScore: newScore)
        } else {
            let newRecord = ConfirmedPeerRecord(
                peerID: fullPeerID,
                addresses: [event.source],
                observations: [observation],
                presenceScore: BayesianPresence.presenceScore(observations: [observation]),
                certificate: envelope,
                epoch: epoch
            )
            store.upsert(newRecord)

            // Check if this confirms a previously unconfirmed sighting
            if let truncID = event.truncID {
                let sightings = store.sightings(matching: truncID)
                if !sightings.isEmpty {
                    store.promoteSighting(truncID: truncID, to: newRecord)
                    result = .promoted(from: truncID, to: newRecord)
                } else {
                    result = .newConfirmed(newRecord)
                }
            } else {
                result = .newConfirmed(newRecord)
            }
        }

        emit(result)
    }

    @discardableResult
    private func emit(_ event: AggregationResult) -> AsyncStream<AggregationResult>.Continuation.YieldResult? {
        eventState.withLock { state in
            state.continuation?.yield(event)
        }
    }

    private func freshnessFunction(for mediumID: String) -> FreshnessFunction {
        switch mediumID {
        case "nfc":
            return .nfc
        case "ble":
            return .ble
        case "wifi-direct":
            return .wifiDirect
        case "lora":
            return .lora
        default:
            return .gossip
        }
    }
}
