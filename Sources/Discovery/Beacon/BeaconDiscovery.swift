import Foundation
import Synchronization
import P2PCore
import P2PDiscovery

/// Beacon-based peer discovery service for proximity-aware networking.
///
/// Integrates tiered beacon encoding (Tier 1/2/3), TESLA authentication,
/// Bayesian presence estimation, and Sybil detection into a unified
/// `DiscoveryService` implementation.
///
/// Uses `Class + Mutex` pattern (not Actor) per project conventions.
/// Uses `EventBroadcaster` for multi-consumer observation streams (Discovery layer convention).
/// Lifecycle: `func shutdown() async` (Discovery layer convention).
public final class BeaconDiscovery: DiscoveryService, Sendable {

    // MARK: - Properties

    private let configuration: BeaconDiscoveryConfiguration
    private let localPeerID: PeerID
    private let addressCodec: BeaconAddressCodec

    private let encoder: BeaconEncoderService
    private let filter: BeaconFilter
    private let coordinator: ScanCoordinator
    private let ingest: AggregationIngest
    private let ephIDGenerator: EphIDGenerator

    private let tesla: MicroTESLA
    private let broadcaster: EventBroadcaster<PeerObservation>
    private let startTime: ContinuousClock.Instant
    private let state: Mutex<ServiceState>

    private struct ServiceState: Sendable {
        var isRunning: Bool = false
        var beaconSeqNumber: UInt64 = 0
        var observationSeqNumber: UInt64 = 0
        var forwardTask: Task<Void, Never>?
        var announcedAddresses: [Multiaddr] = []
    }

    // MARK: - Initialization

    /// Creates a new BeaconDiscovery service.
    ///
    /// - Parameter configuration: Configuration for the service.
    public init(configuration: BeaconDiscoveryConfiguration) {
        self.configuration = configuration
        self.localPeerID = configuration.keyPair.peerID
        self.addressCodec = BeaconAddressCodec()
        self.encoder = BeaconEncoderService()
        self.filter = BeaconFilter(
            sybilThreshold: configuration.sybilThreshold,
            sybilWindow: configuration.sybilWindow
        )
        self.coordinator = ScanCoordinator()
        self.ingest = AggregationIngest(store: configuration.store)
        self.ephIDGenerator = EphIDGenerator(
            keyPair: configuration.keyPair,
            rotationInterval: configuration.ephIDRotationInterval
        )
        self.tesla = MicroTESLA(seed: configuration.keyPair.privateKey.rawBytes)
        self.broadcaster = EventBroadcaster<PeerObservation>()
        self.startTime = ContinuousClock.now
        self.state = Mutex(ServiceState())
    }

    // MARK: - Service Management

    /// Starts the beacon discovery service and begins forwarding aggregation events.
    public func start() {
        let shouldStart = state.withLock { s -> Bool in
            guard !s.isRunning else { return false }
            s.isRunning = true
            return true
        }
        guard shouldStart else { return }

        let forwardTask = Task { [weak self] in
            guard let self else { return }
            await self.forwardAggregationEvents()
        }

        state.withLock { s in
            s.forwardTask = forwardTask
        }
    }

    /// Shuts down the beacon discovery service and releases operational resources.
    ///
    /// After calling `shutdown()`, the service will not emit new observations.
    /// This method is idempotent and safe to call multiple times.
    public func shutdown() async {
        let task = state.withLock { s -> Task<Void, Never>? in
            guard s.isRunning else { return nil }
            s.isRunning = false
            let task = s.forwardTask
            s.forwardTask = nil
            return task
        }

        task?.cancel()
        ingest.shutdown()
        broadcaster.shutdown()
    }

    // MARK: - DiscoveryService Protocol

    /// Announces our own reachability with the given addresses.
    ///
    /// Stores addresses for inclusion in Tier 3 beacons.
    public func announce(addresses: [Multiaddr]) async throws {
        state.withLock { s in
            s.announcedAddresses = addresses
        }
    }

    /// Finds candidates for a given peer.
    ///
    /// Searches the confirmed peer store for records matching the requested peer.
    public func find(peer: PeerID) async throws -> [ScoredCandidate] {
        guard let record = configuration.store.get(peer) else {
            return []
        }

        let multiaddrs = addressCodec.toMultiaddrs(record.addresses)
        return [ScoredCandidate(
            peerID: record.peerID,
            addresses: multiaddrs,
            score: record.presenceScore
        )]
    }

    /// Subscribes to observations about a specific peer.
    ///
    /// Returns a filtered stream that only emits observations where the subject
    /// matches the requested peer.
    public func subscribe(to peer: PeerID) -> AsyncStream<PeerObservation> {
        let targetPeer = peer
        let observationStream = self.observations

        let (stream, continuation) = AsyncStream<PeerObservation>.makeStream()
        let task = Task {
            for await observation in observationStream {
                if observation.subject == targetPeer {
                    continuation.yield(observation)
                }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in
            task.cancel()
        }
        return stream
    }

    /// Returns all known confirmed peers.
    public func knownPeers() async -> [PeerID] {
        configuration.store.allConfirmed().map(\.peerID)
            .filter { $0 != localPeerID }
    }

    /// Returns an independent stream of all observations.
    /// Each call returns a new stream (multi-consumer safe via EventBroadcaster).
    public var observations: AsyncStream<PeerObservation> {
        broadcaster.subscribe()
    }

    // MARK: - Beacon Processing

    /// Processes a raw discovery event from a transport adapter.
    ///
    /// This is the primary entry point for beacon data received from transport media.
    /// The method decodes the beacon, applies filtering, and routes the event
    /// through the aggregation pipeline.
    ///
    /// - Parameter discovery: The raw discovery event from the transport layer.
    public func processDiscovery(_ discovery: RawDiscovery) {
        guard let decoded = encoder.decode(payload: discovery.payload) else {
            return
        }

        guard filter.accept(discovery, beacon: decoded, minInterval: configuration.beaconRateLimit) else {
            return
        }

        let trust = TrustCalculator.directObservationTrust(
            rssi: discovery.rssi,
            medium: discovery.mediumID
        )

        let event = BeaconDiscoveryEvent(
            tier: decoded.tier,
            truncID: decoded.truncID,
            fullPeerID: decoded.fullID,
            source: discovery.sourceAddress,
            rssi: discovery.rssi,
            physicalFingerprint: discovery.physicalFingerprint,
            timestamp: discovery.timestamp,
            directObservationTrust: trust,
            envelope: decoded.envelope
        )

        ingest.ingest(event)
    }

    /// Encodes a beacon payload suitable for the given maximum size.
    ///
    /// - Parameter maxSize: Maximum payload size in bytes (determined by the transport medium).
    /// - Returns: Encoded beacon payload data.
    /// - Throws: `BeaconEncodingError` if encoding fails.
    public func encodeBeacon(maxSize: Int) throws -> Data {
        guard let tier = encoder.selectTier(maxBeaconSize: maxSize) else {
            throw BeaconEncodingError.payloadTooSmall(
                maxSize: maxSize,
                minimumRequired: BeaconTier.tier1.minimumSize
            )
        }

        let truncID = ephIDGenerator.truncID()
        let nonce = ephIDGenerator.nonce()

        switch tier {
        case .tier1:
            return encoder.encodeTier1(
                truncID: truncID,
                nonce: nonce,
                difficulty: configuration.powDifficulty
            )

        case .tier2:
            let result = encoder.encodeTier2(
                truncID: truncID,
                nonce: nonce,
                tesla: tesla,
                capBloom: configuration.capabilityBloom,
                difficulty: configuration.powDifficulty
            )
            tesla.advanceEpoch()
            return result

        case .tier3:
            let opaqueAddresses = state.withLock { s in
                addressCodec.toOpaqueAddresses(s.announcedAddresses)
            }
            let seq = state.withLock { s -> UInt64 in
                s.beaconSeqNumber += 1
                return s.beaconSeqNumber
            }
            return try encoder.encodeTier3(
                keyPair: configuration.keyPair,
                nonce: nonce,
                addresses: opaqueAddresses,
                sequenceNumber: seq
            )
        }
    }

    /// Registers a transport medium for scan coordination.
    ///
    /// - Parameters:
    ///   - mediumID: Unique identifier for the medium (e.g., "ble", "wifi-direct").
    ///   - imin: Minimum Trickle interval for this medium.
    ///   - imax: Maximum Trickle interval for this medium.
    ///   - k: Redundancy constant for this medium's Trickle timer.
    public func registerMedium(_ mediumID: String, imin: Duration, imax: Duration, k: Int) {
        coordinator.registerMedium(mediumID, imin: imin, imax: imax, k: k)
    }

    /// Determines whether the caller should transmit on the specified medium.
    ///
    /// - Parameter mediumID: The medium identifier.
    /// - Returns: `true` if the caller should transmit.
    public func shouldTransmit(on mediumID: String) -> Bool {
        coordinator.shouldTransmit(medium: mediumID)
    }

    // MARK: - Private

    /// Forwards aggregation events to the broadcaster as P2PDiscovery.PeerObservation values.
    private func forwardAggregationEvents() async {
        let events = ingest.aggregationEvents

        for await event in events {
            let pendingObservation = convertToObservation(event)
            if let observation = pendingObservation {
                broadcaster.emit(observation)
            }
        }
    }

    /// Returns a monotonic timestamp suitable for Observation.
    private func currentTimestamp() -> UInt64 {
        let now = ContinuousClock.now
        let elapsed = now - startTime
        let seconds = elapsed.components.seconds
        return UInt64(max(0, seconds))
    }

    /// Converts an AggregationResult into a P2PDiscovery.PeerObservation.
    private func convertToObservation(_ result: AggregationResult) -> PeerObservation? {
        let seq = state.withLock { s -> UInt64 in
            s.observationSeqNumber += 1
            return s.observationSeqNumber
        }
        let ts = currentTimestamp()

        switch result {
        case .newConfirmed(let record):
            return PeerObservation(
                subject: record.peerID,
                observer: localPeerID,
                kind: .announcement,
                hints: addressCodec.toMultiaddrs(record.addresses),
                timestamp: ts,
                sequenceNumber: seq
            )

        case .confirmedUpdated(let peerID, _):
            guard let record = configuration.store.get(peerID) else { return nil }
            return PeerObservation(
                subject: peerID,
                observer: localPeerID,
                kind: .reachable,
                hints: addressCodec.toMultiaddrs(record.addresses),
                timestamp: ts,
                sequenceNumber: seq
            )

        case .promoted(_, let record):
            return PeerObservation(
                subject: record.peerID,
                observer: localPeerID,
                kind: .announcement,
                hints: addressCodec.toMultiaddrs(record.addresses),
                timestamp: ts,
                sequenceNumber: seq
            )

        case .newSighting, .sightingUpdated:
            // Unconfirmed sightings are not emitted as observations
            return nil
        }
    }
}
