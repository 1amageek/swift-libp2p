import Foundation
import P2PCore
import P2PDiscovery
import P2PMux
import P2PPlumtree
import P2PProtocols

/// Discovery service backed by Plumtree gossip.
///
/// Peers periodically broadcast self-announcements on a configured Plumtree topic.
/// Received announcements are converted into `PeerObservation` values and cached as
/// `ScoredCandidate`s for `find(peer:)`.
public actor PlumtreeDiscovery: DiscoveryService {
    private struct PeerState: Sendable {
        var addresses: [Multiaddr]
        var score: Double
        var lastSeenUnix: TimeInterval
        var lastAnnouncementSequence: UInt64
    }

    public let localPeerID: PeerID
    private let configuration: PlumtreeDiscoveryConfiguration
    private let plumtreeService: PlumtreeService
    private let ownsPlumtreeService: Bool

    private var localAddresses: [Multiaddr] = []
    private var knownPeersByID: [PeerID: PeerState] = [:]
    private var localAnnouncementSequence: UInt64 = 0
    private var observationSequence: UInt64 = 0
    private var forwardTask: Task<Void, Never>?
    private var isStarted: Bool = false
    private var opener: (any StreamOpener)?

    private nonisolated let broadcaster = EventBroadcaster<PeerObservation>()

    public nonisolated var discoveryProtocolID: String {
        plumtreeProtocolID
    }

    public init(
        localPeerID: PeerID,
        configuration: PlumtreeDiscoveryConfiguration = .default,
        plumtreeService: PlumtreeService? = nil
    ) {
        self.localPeerID = localPeerID
        self.configuration = configuration
        if let plumtreeService {
            self.plumtreeService = plumtreeService
            self.ownsPlumtreeService = false
        } else {
            self.plumtreeService = PlumtreeService(
                localPeerID: localPeerID,
                configuration: configuration.plumtreeConfiguration
            )
            self.ownsPlumtreeService = true
        }
    }

    deinit {
        broadcaster.shutdown()
    }

    // MARK: - Lifecycle

    /// Starts the internal forwarding loop.
    /// Prefer `attach(to:)` which also sets the opener for peer stream management.
    private func startForwarding() {
        guard !isStarted else { return }

        if ownsPlumtreeService {
            plumtreeService.start()
        }
        let stream = plumtreeService.subscribe(to: configuration.topic)
        forwardTask = Task { [weak self] in
            guard let self else { return }
            for await gossip in stream {
                await self.handleGossip(gossip)
            }
        }
        isStarted = true
    }

    public func shutdown() async {
        forwardTask?.cancel()
        forwardTask = nil
        opener = nil
        isStarted = false
        knownPeersByID.removeAll()
        localAnnouncementSequence = 0
        observationSequence = 0
        localAddresses.removeAll()

        if ownsPlumtreeService {
            await plumtreeService.shutdown()
        }
        broadcaster.shutdown()
    }

    // MARK: - Plumbing for node integration

    public func handlePeerConnected(_ peerID: PeerID, stream: MuxedStream) async {
        plumtreeService.handlePeerConnected(peerID, stream: stream)
    }

    public func handlePeerDisconnected(_ peerID: PeerID) async {
        plumtreeService.handlePeerDisconnected(peerID)
        if let state = knownPeersByID.removeValue(forKey: peerID) {
            emitObservation(subject: peerID, kind: .unreachable, hints: state.addresses)
        }
    }

    // MARK: - DiscoveryService

    public func announce(addresses: [Multiaddr]) async throws {
        guard isStarted else {
            throw PlumtreeDiscoveryError.notStarted
        }
        localAddresses = addresses
        localAnnouncementSequence += 1

        let announcement = PlumtreeDiscoveryAnnouncement(
            peerID: localPeerID,
            addresses: addresses,
            timestamp: unixNow(),
            sequenceNumber: localAnnouncementSequence
        )
        let payload = try announcement.encode()

        do {
            _ = try plumtreeService.publish(data: payload, to: configuration.topic)
        } catch {
            throw PlumtreeDiscoveryError.publishFailed
        }
    }

    public func find(peer: PeerID) async throws -> [ScoredCandidate] {
        evictExpiredPeers()
        guard let known = knownPeersByID[peer] else {
            return []
        }
        return [ScoredCandidate(peerID: peer, addresses: known.addresses, score: known.score)]
    }

    public func collectKnownPeers() async -> [PeerID] {
        evictExpiredPeers()
        return Array(knownPeersByID.keys)
    }

    public nonisolated var observations: AsyncStream<PeerObservation> {
        broadcaster.subscribe()
    }

    public nonisolated func subscribe(to peer: PeerID) -> AsyncStream<PeerObservation> {
        let stream = broadcaster.subscribe()
        return AsyncStream { continuation in
            let task = Task {
                for await observation in stream where observation.subject == peer {
                    continuation.yield(observation)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: - Internal ingestion

    func ingestAnnouncement(
        _ announcement: PlumtreeDiscoveryAnnouncement,
        source: PeerID
    ) throws {
        let announcedPeerID: PeerID
        do {
            announcedPeerID = try PeerID(string: announcement.peerID)
        } catch {
            throw PlumtreeDiscoveryError.invalidAnnouncement
        }

        guard announcedPeerID == source else {
            throw PlumtreeDiscoveryError.spoofedAnnouncement(expected: source, actual: announcedPeerID)
        }
        guard announcedPeerID != localPeerID else {
            return
        }

        var addresses: [Multiaddr] = []
        var seen = Set<Multiaddr>()
        for addressString in announcement.addresses {
            do {
                let address = try Multiaddr(addressString)
                if seen.insert(address).inserted {
                    addresses.append(address)
                }
            } catch {
                continue
            }
        }

        if configuration.requireAddresses && addresses.isEmpty {
            throw PlumtreeDiscoveryError.invalidAnnouncement
        }

        if let existing = knownPeersByID[announcedPeerID],
           announcement.sequenceNumber <= existing.lastAnnouncementSequence {
            return
        }

        knownPeersByID[announcedPeerID] = PeerState(
            addresses: addresses,
            score: configuration.baseScore,
            lastSeenUnix: Date().timeIntervalSince1970,
            lastAnnouncementSequence: announcement.sequenceNumber
        )

        enforceCapacityLimit()
        emitObservation(subject: announcedPeerID, kind: .reachable, hints: addresses)
    }

    // MARK: - Private

    private func handleGossip(_ gossip: PlumtreeGossip) async {
        guard gossip.topic == configuration.topic else {
            return
        }
        guard gossip.source != localPeerID else {
            return
        }

        do {
            let announcement = try PlumtreeDiscoveryAnnouncement.decode(gossip.data)
            try ingestAnnouncement(announcement, source: gossip.source)
        } catch {
            return
        }
    }

    private func emitObservation(subject: PeerID, kind: PeerObservation.Kind, hints: [Multiaddr]) {
        observationSequence += 1
        let observation = PeerObservation(
            subject: subject,
            observer: localPeerID,
            kind: kind,
            hints: hints,
            timestamp: unixNow(),
            sequenceNumber: observationSequence
        )
        broadcaster.emit(observation)
    }

    private func evictExpiredPeers() {
        let ttl = durationToTimeInterval(configuration.peerTTL)
        guard ttl > 0 else {
            return
        }
        let now = Date().timeIntervalSince1970

        var expiredPeers: [PeerID] = []
        expiredPeers.reserveCapacity(knownPeersByID.count)
        for (peerID, state) in knownPeersByID {
            if now - state.lastSeenUnix > ttl {
                expiredPeers.append(peerID)
            }
        }

        for peerID in expiredPeers {
            if let removed = knownPeersByID.removeValue(forKey: peerID) {
                emitObservation(subject: peerID, kind: .unreachable, hints: removed.addresses)
            }
        }
    }

    private func enforceCapacityLimit() {
        guard knownPeersByID.count > configuration.maxKnownPeers else {
            return
        }
        let overflow = knownPeersByID.count - configuration.maxKnownPeers
        let evictionList = knownPeersByID
            .sorted { $0.value.lastSeenUnix < $1.value.lastSeenUnix }
            .prefix(overflow)
            .map(\.key)

        for peerID in evictionList {
            if let removed = knownPeersByID.removeValue(forKey: peerID) {
                emitObservation(subject: peerID, kind: .unreachable, hints: removed.addresses)
            }
        }
    }

    private func durationToTimeInterval(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        let attosecondsPerSecond = 1_000_000_000_000_000_000.0
        return TimeInterval(components.seconds) + (Double(components.attoseconds) / attosecondsPerSecond)
    }

    private func unixNow() -> UInt64 {
        UInt64(max(0, Date().timeIntervalSince1970 * 1000))
    }
}

// MARK: - DiscoveryBehaviour

extension PlumtreeDiscovery: DiscoveryBehaviour, StreamService, PeerObserver {
    public nonisolated var protocolIDs: [String] {
        [plumtreeProtocolID]
    }

    public func handleInboundStream(_ context: StreamContext) async {
        plumtreeService.handlePeerConnected(context.remotePeer, stream: context.stream)
    }

    public func attach(to context: any NodeContext) async {
        self.opener = context
        startForwarding()
    }

    public func peerConnected(_ peer: PeerID) async {
        guard let opener else { return }
        do {
            let stream = try await opener.newStream(to: peer, protocol: plumtreeProtocolID)
            plumtreeService.handlePeerConnected(peer, stream: stream)
        } catch {
            // Failed to open stream — peer may not support Plumtree
        }
    }

    public func peerDisconnected(_ peer: PeerID) async {
        await handlePeerDisconnected(peer)
    }

    // shutdown(): already defined as async method
}
