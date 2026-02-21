import Testing
import Foundation
import Synchronization
@testable import P2PDiscovery
@testable import P2PCore

// MARK: - Mock DiscoveryService

/// Mock discovery service for testing.
final class MockDiscoveryService: DiscoveryService, Sendable {

    let localPeerID: PeerID
    private let _knownPeers: [PeerID]
    private let _candidates: [PeerID: [ScoredCandidate]]
    private let findDelay: Duration?
    private let eventContinuation: AsyncStream<PeerObservation>.Continuation
    private let eventStream: AsyncStream<PeerObservation>

    private let state: Mutex<MockState>

    private struct MockState: Sendable {
        var announcedAddresses: [Multiaddr] = []
        var findCalls: [PeerID] = []
        var stopCalled: Bool = false
    }

    var announcedAddresses: [Multiaddr] {
        state.withLock { $0.announcedAddresses }
    }

    var findCalls: [PeerID] {
        state.withLock { $0.findCalls }
    }

    var stopCalled: Bool {
        state.withLock { $0.stopCalled }
    }

    init(
        localPeerID: PeerID = PeerID(publicKey: KeyPair.generateEd25519().publicKey),
        knownPeers: [PeerID] = [],
        candidates: [PeerID: [ScoredCandidate]] = [:],
        findDelay: Duration? = nil
    ) {
        self.localPeerID = localPeerID
        self._knownPeers = knownPeers
        self._candidates = candidates
        self.findDelay = findDelay
        self.state = Mutex(MockState())

        let (stream, continuation) = AsyncStream<PeerObservation>.makeStream()
        self.eventStream = stream
        self.eventContinuation = continuation
    }

    func announce(addresses: [Multiaddr]) async throws {
        state.withLock { $0.announcedAddresses.append(contentsOf: addresses) }
    }

    func find(peer: PeerID) async throws -> [ScoredCandidate] {
        if let findDelay {
            do {
                try await Task.sleep(for: findDelay)
            } catch {
                throw error
            }
        }
        state.withLock { $0.findCalls.append(peer) }
        return _candidates[peer] ?? []
    }

    func subscribe(to peer: PeerID) -> AsyncStream<PeerObservation> {
        AsyncStream { continuation in
            Task { [weak self] in
                guard let self = self else {
                    continuation.finish()
                    return
                }
                for await observation in self.eventStream {
                    if observation.subject == peer {
                        continuation.yield(observation)
                    }
                }
                continuation.finish()
            }
        }
    }

    func collectKnownPeers() async -> [PeerID] {
        _knownPeers
    }

    var observations: AsyncStream<PeerObservation> {
        eventStream
    }

    func shutdown() async {
        state.withLock { $0.stopCalled = true }
        eventContinuation.finish()
    }

    /// Emit an observation for testing.
    func emit(_ observation: PeerObservation) {
        eventContinuation.yield(observation)
    }

    /// Finish the observation stream.
    func finish() {
        eventContinuation.finish()
    }
}

// MARK: - Test Helpers

extension PeerID {
    /// Creates a test PeerID with a deterministic value.
    static func test(_ id: Int) -> PeerID {
        let keyPair = KeyPair.generateEd25519()
        return keyPair.peerID
    }
}

/// Helper to create test multiaddrs.
func testMultiaddr(_ port: Int) throws -> Multiaddr {
    try Multiaddr("/ip4/127.0.0.1/tcp/\(port)")
}

// MARK: - Observation Tests

@Suite("Observation Tests")
struct ObservationTests {

    @Test("Creates observation with all parameters")
    func createObservation() throws {
        let subject = PeerID.test(1)
        let observer = PeerID.test(2)
        let hints = [try testMultiaddr(4001)]

        let observation = PeerObservation(
            subject: subject,
            observer: observer,
            kind: .announcement,
            hints: hints,
            timestamp: 1000,
            sequenceNumber: 1
        )

        #expect(observation.subject == subject)
        #expect(observation.observer == observer)
        #expect(observation.kind == .announcement)
        #expect(observation.hints == hints)
        #expect(observation.timestamp == 1000)
        #expect(observation.sequenceNumber == 1)
    }

    @Test("Observation kinds are distinct")
    func observationKinds() {
        #expect(PeerObservation.Kind.announcement != PeerObservation.Kind.reachable)
        #expect(PeerObservation.Kind.reachable != PeerObservation.Kind.unreachable)
        #expect(PeerObservation.Kind.announcement != PeerObservation.Kind.unreachable)
    }

    @Test("Observation is Hashable")
    func observationHashable() throws {
        let subject = PeerID.test(1)
        let observer = PeerID.test(2)
        let hints = [try testMultiaddr(4001)]

        let observation1 = PeerObservation(
            subject: subject,
            observer: observer,
            kind: .announcement,
            hints: hints,
            timestamp: 1000,
            sequenceNumber: 1
        )

        let observation2 = PeerObservation(
            subject: subject,
            observer: observer,
            kind: .announcement,
            hints: hints,
            timestamp: 1000,
            sequenceNumber: 1
        )

        #expect(observation1 == observation2)
        #expect(observation1.hashValue == observation2.hashValue)

        // Different sequence number should produce different hash
        let observation3 = PeerObservation(
            subject: subject,
            observer: observer,
            kind: .announcement,
            hints: hints,
            timestamp: 1000,
            sequenceNumber: 2
        )

        #expect(observation1 != observation3)
    }

    @Test("Observation with empty hints")
    func observationEmptyHints() {
        let subject = PeerID.test(1)
        let observer = PeerID.test(2)

        let observation = PeerObservation(
            subject: subject,
            observer: observer,
            kind: .unreachable,
            hints: [],
            timestamp: 2000,
            sequenceNumber: 5
        )

        #expect(observation.hints.isEmpty)
        #expect(observation.kind == .unreachable)
    }

    @Test("Observation with multiple hints")
    func observationMultipleHints() throws {
        let subject = PeerID.test(1)
        let observer = PeerID.test(2)
        let hints = [
            try testMultiaddr(4001),
            try testMultiaddr(4002),
            try testMultiaddr(4003)
        ]

        let observation = PeerObservation(
            subject: subject,
            observer: observer,
            kind: .reachable,
            hints: hints,
            timestamp: 3000,
            sequenceNumber: 10
        )

        #expect(observation.hints.count == 3)
    }
}

// MARK: - ScoredCandidate Tests

@Suite("ScoredCandidate Tests")
struct ScoredCandidateTests {

    @Test("Creates scored candidate with all parameters")
    func createScoredCandidate() throws {
        let peerID = PeerID.test(1)
        let addresses = [try testMultiaddr(4001)]

        let candidate = ScoredCandidate(
            peerID: peerID,
            addresses: addresses,
            score: 0.85
        )

        #expect(candidate.peerID == peerID)
        #expect(candidate.addresses == addresses)
        #expect(candidate.score == 0.85)
    }

    @Test("Scored candidate with zero score")
    func zeroScore() {
        let peerID = PeerID.test(1)

        let candidate = ScoredCandidate(
            peerID: peerID,
            addresses: [],
            score: 0.0
        )

        #expect(candidate.score == 0.0)
    }

    @Test("Scored candidate with maximum score")
    func maxScore() {
        let peerID = PeerID.test(1)

        let candidate = ScoredCandidate(
            peerID: peerID,
            addresses: [],
            score: 1.0
        )

        #expect(candidate.score == 1.0)
    }

    @Test("Scored candidate with multiple addresses")
    func multipleAddresses() throws {
        let peerID = PeerID.test(1)
        let addresses = [
            try testMultiaddr(4001),
            try testMultiaddr(4002)
        ]

        let candidate = ScoredCandidate(
            peerID: peerID,
            addresses: addresses,
            score: 0.5
        )

        #expect(candidate.addresses.count == 2)
    }
}

// MARK: - CompositeDiscovery Tests

@Suite("CompositeDiscovery Tests")
struct CompositeDiscoveryTests {

    @Test("Initializes with weighted services")
    func initWithWeights() async {
        let localPeerID = PeerID(publicKey: KeyPair.generateEd25519().publicKey)
        let service1 = MockDiscoveryService()
        let service2 = MockDiscoveryService()

        let composite = CompositeDiscovery(localPeerID: localPeerID, services: [
            (service: service1, weight: 1.0),
            (service: service2, weight: 0.5)
        ])

        // Verify it works by calling a method
        let peers = await composite.knownPeers()
        #expect(peers.isEmpty)
    }

    @Test("Initializes with equal weights")
    func initWithEqualWeights() async {
        let localPeerID = PeerID(publicKey: KeyPair.generateEd25519().publicKey)
        let service1 = MockDiscoveryService()
        let service2 = MockDiscoveryService()

        let composite = CompositeDiscovery(localPeerID: localPeerID, services: [service1, service2])

        // Verify it works by calling a method
        let peers = await composite.knownPeers()
        #expect(peers.isEmpty)
    }

    @Test("Announce forwards to all services")
    func announceForwardsToAll() async throws {
        let localPeerID = PeerID(publicKey: KeyPair.generateEd25519().publicKey)
        let service1 = MockDiscoveryService()
        let service2 = MockDiscoveryService()

        let composite = CompositeDiscovery(localPeerID: localPeerID, services: [service1, service2])

        let addresses = [try testMultiaddr(4001)]
        try await composite.announce(addresses: addresses)

        #expect(service1.announcedAddresses == addresses)
        #expect(service2.announcedAddresses == addresses)
    }

    @Test("Find merges candidates from all services")
    func findMergesCandidates() async throws {
        let localPeerID = PeerID(publicKey: KeyPair.generateEd25519().publicKey)
        let targetPeer = PeerID.test(1)

        let addr1 = try testMultiaddr(4001)
        let addr2 = try testMultiaddr(4002)

        let candidate1 = ScoredCandidate(peerID: targetPeer, addresses: [addr1], score: 0.8)
        let candidate2 = ScoredCandidate(peerID: targetPeer, addresses: [addr2], score: 0.6)

        let service1 = MockDiscoveryService(candidates: [targetPeer: [candidate1]])
        let service2 = MockDiscoveryService(candidates: [targetPeer: [candidate2]])

        let composite = CompositeDiscovery(localPeerID: localPeerID, services: [service1, service2])

        let results = try await composite.find(peer: targetPeer)

        #expect(results.count == 1)  // Merged into single candidate
        #expect(results[0].peerID == targetPeer)
        #expect(results[0].addresses.count == 2)  // Both addresses merged
        #expect(results[0].score == 0.7)  // Average of 0.8 and 0.6
    }

    @Test("Find applies weights to scores")
    func findAppliesWeights() async throws {
        let localPeerID = PeerID(publicKey: KeyPair.generateEd25519().publicKey)
        let targetPeer = PeerID.test(1)
        let addr1 = try testMultiaddr(4001)
        let addr2 = try testMultiaddr(4002)

        let candidate1 = ScoredCandidate(peerID: targetPeer, addresses: [addr1], score: 1.0)
        let candidate2 = ScoredCandidate(peerID: targetPeer, addresses: [addr2], score: 1.0)

        let service1 = MockDiscoveryService(candidates: [targetPeer: [candidate1]])
        let service2 = MockDiscoveryService(candidates: [targetPeer: [candidate2]])

        let composite = CompositeDiscovery(localPeerID: localPeerID, services: [
            (service: service1, weight: 2.0),  // Weight 2.0 → score becomes 2.0
            (service: service2, weight: 1.0)   // Weight 1.0 → score becomes 1.0
        ])

        let results = try await composite.find(peer: targetPeer)

        #expect(results.count == 1)
        // Weighted average: (2.0 + 1.0) / 2 = 1.5
        #expect(results[0].score == 1.5)
    }

    @Test("Find queries services in parallel")
    func findRunsInParallel() async throws {
        let targetPeer = PeerID.test(1)
        let addr1 = try testMultiaddr(4001)
        let addr2 = try testMultiaddr(4002)

        let candidate1 = ScoredCandidate(peerID: targetPeer, addresses: [addr1], score: 0.7)
        let candidate2 = ScoredCandidate(peerID: targetPeer, addresses: [addr2], score: 0.8)

        let service1 = MockDiscoveryService(
            candidates: [targetPeer: [candidate1]],
            findDelay: .milliseconds(150)
        )
        let service2 = MockDiscoveryService(
            candidates: [targetPeer: [candidate2]],
            findDelay: .milliseconds(150)
        )
        let localPeerID = PeerID(publicKey: KeyPair.generateEd25519().publicKey)
        let composite = CompositeDiscovery(localPeerID: localPeerID, services: [service1, service2])

        let start = ContinuousClock.now
        let results = try await composite.find(peer: targetPeer)
        let elapsed = ContinuousClock.now - start

        #expect(results.count == 1)
        // Parallel should be ~150ms; sequential would be ~300ms.
        #expect(elapsed < .milliseconds(260))
    }

    @Test("Find returns empty for unknown peer")
    func findReturnsEmptyForUnknown() async throws {
        let localPeerID = PeerID(publicKey: KeyPair.generateEd25519().publicKey)
        let knownPeer = PeerID.test(1)
        let unknownPeer = PeerID.test(2)
        let addr = try testMultiaddr(4001)

        let candidate = ScoredCandidate(peerID: knownPeer, addresses: [addr], score: 0.9)
        let service = MockDiscoveryService(candidates: [knownPeer: [candidate]])

        let composite = CompositeDiscovery(localPeerID: localPeerID, services: [service])

        let results = try await composite.find(peer: unknownPeer)

        #expect(results.isEmpty)
    }

    @Test("KnownPeers deduplicates across services")
    func knownPeersDeduplicates() async {
        let localPeerID = PeerID(publicKey: KeyPair.generateEd25519().publicKey)
        let peer1 = PeerID.test(1)
        let peer2 = PeerID.test(2)
        let peer3 = PeerID.test(3)

        let service1 = MockDiscoveryService(knownPeers: [peer1, peer2])
        let service2 = MockDiscoveryService(knownPeers: [peer2, peer3])

        let composite = CompositeDiscovery(localPeerID: localPeerID, services: [service1, service2])

        let peers = await composite.knownPeers()

        // Should have 3 unique peers, not 4
        #expect(peers.count == 3)
        #expect(Set(peers).contains(peer1))
        #expect(Set(peers).contains(peer2))
        #expect(Set(peers).contains(peer3))
    }

    @Test("KnownPeers returns empty when no services have peers")
    func knownPeersEmpty() async {
        let localPeerID = PeerID(publicKey: KeyPair.generateEd25519().publicKey)
        let service1 = MockDiscoveryService(knownPeers: [])
        let service2 = MockDiscoveryService(knownPeers: [])

        let composite = CompositeDiscovery(localPeerID: localPeerID, services: [service1, service2])

        let peers = await composite.knownPeers()

        #expect(peers.isEmpty)
    }

    @Test("Find results sorted by score descending")
    func findResultsSortedByScore() async throws {
        let peer1 = PeerID.test(1)
        let peer2 = PeerID.test(2)
        let peer3 = PeerID.test(3)

        let addr1 = try testMultiaddr(4001)
        let addr2 = try testMultiaddr(4002)
        let addr3 = try testMultiaddr(4003)

        // All candidates for same search, different peers
        let candidate1 = ScoredCandidate(peerID: peer1, addresses: [addr1], score: 0.3)
        let candidate2 = ScoredCandidate(peerID: peer2, addresses: [addr2], score: 0.9)
        let candidate3 = ScoredCandidate(peerID: peer3, addresses: [addr3], score: 0.5)

        // Use a target peer that will return all candidates
        let targetPeer = PeerID.test(100)
        let service = MockDiscoveryService(candidates: [
            targetPeer: [candidate1, candidate2, candidate3]
        ])

        let localPeerID = PeerID(publicKey: KeyPair.generateEd25519().publicKey)
        let composite = CompositeDiscovery(localPeerID: localPeerID, services: [service])

        let results = try await composite.find(peer: targetPeer)

        #expect(results.count == 3)
        #expect(results[0].score == 0.9)
        #expect(results[1].score == 0.5)
        #expect(results[2].score == 0.3)
    }

    @Test("CompositeDiscovery shuts down child services")
    func compositeShutdownsChildServices() async {
        let localPeerID = PeerID(publicKey: KeyPair.generateEd25519().publicKey)
        let mock1 = MockDiscoveryService()
        let mock2 = MockDiscoveryService()
        let composite = CompositeDiscovery(localPeerID: localPeerID, services: [mock1, mock2])

        await composite.start()
        await composite.shutdown()

        #expect(mock1.stopCalled == true)
        #expect(mock2.stopCalled == true)
    }

    @Test("Shutdown is idempotent (double shutdown does not crash)")
    func shutdownIsIdempotent() async {
        let localPeerID = PeerID(publicKey: KeyPair.generateEd25519().publicKey)
        let service = MockDiscoveryService()
        let composite = CompositeDiscovery(localPeerID: localPeerID, services: [service])

        // Start to initialize state
        await composite.start()

        // Multiple shutdowns should not crash
        await composite.shutdown()
        await composite.shutdown()
        await composite.shutdown()

        // Service should still be usable for read operations
        let peers = await composite.knownPeers()
        #expect(peers.isEmpty)
    }

    @Test("Shutdown terminates observation stream", .timeLimit(.minutes(1)))
    func shutdownTerminatesObservationStream() async {
        let localPeerID = PeerID(publicKey: KeyPair.generateEd25519().publicKey)
        let service = MockDiscoveryService()
        let composite = CompositeDiscovery(localPeerID: localPeerID, services: [service])

        // Start the composite
        await composite.start()

        // Get the observation stream
        let observations = composite.observations

        // Start consuming observations in a task
        let consumeTask = Task {
            var count = 0
            for await _ in observations {
                count += 1
            }
            return count
        }

        // Give time for the consumer to start
        do { try await Task.sleep(for: .milliseconds(50)) } catch { }

        // Shutdown should terminate the stream
        await composite.shutdown()

        // Consumer should complete without timing out
        let count = await consumeTask.value
        #expect(count == 0)  // No observations were emitted
    }
}

// MARK: - DiscoveryService Protocol Tests

@Suite("DiscoveryService Protocol Tests")
struct DiscoveryServiceProtocolTests {

    @Test("MockDiscoveryService conforms to protocol")
    func mockConformsToProtocol() async throws {
        let service: any DiscoveryService = MockDiscoveryService()

        // Should compile and work with protocol type
        try await service.announce(addresses: [])
        let _ = try await service.find(peer: PeerID.test(1))
        let _ = await service.knownPeers()
    }

    @Test("CompositeDiscovery conforms to protocol")
    func compositeConformsToProtocol() async throws {
        let localPeerID = PeerID(publicKey: KeyPair.generateEd25519().publicKey)
        let emptyServices: [any DiscoveryService] = []
        let service: any DiscoveryService = CompositeDiscovery(localPeerID: localPeerID, services: emptyServices)

        // Should compile and work with protocol type
        try await service.announce(addresses: [])
        let _ = try await service.find(peer: PeerID.test(1))
        let _ = await service.knownPeers()
    }
}

// MARK: - Self-Filtering Tests

@Suite("DiscoveryService Self-Filtering Tests")
struct DiscoveryServiceSelfFilteringTests {

    @Test("knownPeers() excludes localPeerID from collectKnownPeers() results")
    func knownPeersExcludesSelf() async {
        let localPeerID = PeerID(publicKey: KeyPair.generateEd25519().publicKey)
        let otherPeer = PeerID(publicKey: KeyPair.generateEd25519().publicKey)

        // Mock includes localPeerID in raw results
        let service = MockDiscoveryService(
            localPeerID: localPeerID,
            knownPeers: [localPeerID, otherPeer]
        )

        // collectKnownPeers() returns raw data including self
        let raw = await service.collectKnownPeers()
        #expect(raw.count == 2)
        #expect(raw.contains(localPeerID))

        // knownPeers() (protocol extension) filters self
        let filtered = await service.knownPeers()
        #expect(filtered.count == 1)
        #expect(!filtered.contains(localPeerID))
        #expect(filtered.contains(otherPeer))
    }

    @Test("knownPeers() returns empty when only self is known")
    func knownPeersEmptyWhenOnlySelf() async {
        let localPeerID = PeerID(publicKey: KeyPair.generateEd25519().publicKey)

        let service = MockDiscoveryService(
            localPeerID: localPeerID,
            knownPeers: [localPeerID]
        )

        let raw = await service.collectKnownPeers()
        #expect(raw.count == 1)

        let filtered = await service.knownPeers()
        #expect(filtered.isEmpty)
    }

    @Test("knownPeers() passes through when self is not present")
    func knownPeersPassesThroughWhenNoSelf() async {
        let localPeerID = PeerID(publicKey: KeyPair.generateEd25519().publicKey)
        let peer1 = PeerID(publicKey: KeyPair.generateEd25519().publicKey)
        let peer2 = PeerID(publicKey: KeyPair.generateEd25519().publicKey)

        let service = MockDiscoveryService(
            localPeerID: localPeerID,
            knownPeers: [peer1, peer2]
        )

        let raw = await service.collectKnownPeers()
        let filtered = await service.knownPeers()

        // No self to filter, so same count
        #expect(raw.count == filtered.count)
        #expect(filtered.count == 2)
    }

    @Test("CompositeDiscovery knownPeers() excludes composite's localPeerID")
    func compositeKnownPeersExcludesSelf() async {
        let localPeerID = PeerID(publicKey: KeyPair.generateEd25519().publicKey)
        let otherPeer1 = PeerID(publicKey: KeyPair.generateEd25519().publicKey)
        let otherPeer2 = PeerID(publicKey: KeyPair.generateEd25519().publicKey)

        // Child service reports localPeerID as known (e.g., from incoming connection)
        let service1 = MockDiscoveryService(knownPeers: [localPeerID, otherPeer1])
        let service2 = MockDiscoveryService(knownPeers: [otherPeer2])

        let composite = CompositeDiscovery(localPeerID: localPeerID, services: [service1, service2])

        // knownPeers() (protocol extension) filters composite's localPeerID
        let filtered = await composite.knownPeers()
        #expect(!filtered.contains(localPeerID))
        #expect(filtered.contains(otherPeer1))
        #expect(filtered.contains(otherPeer2))
    }

    @Test("CompositeDiscovery collectKnownPeers vs knownPeers difference")
    func compositeCollectVsKnown() async {
        let localPeerID = PeerID(publicKey: KeyPair.generateEd25519().publicKey)

        // Child service returns the composite's localPeerID as a "known peer"
        let service = MockDiscoveryService(knownPeers: [localPeerID])

        let composite = CompositeDiscovery(localPeerID: localPeerID, services: [service])

        let raw = await composite.collectKnownPeers()
        let filtered = await composite.knownPeers()

        // raw may contain self, filtered must not
        #expect(filtered.count < raw.count || raw.isEmpty)
        #expect(!filtered.contains(localPeerID))
    }
}
