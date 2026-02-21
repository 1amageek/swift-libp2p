import Testing
import P2PCore
import P2PDiscovery
@testable import P2PDiscoveryPlumtree

@Suite("PlumtreeDiscovery Tests")
struct PlumtreeDiscoveryTests {
    private func makePeerID() -> PeerID {
        KeyPair.generateEd25519().peerID
    }

    @Test("Announcement encodes and decodes")
    func announcementRoundTrip() throws {
        let peerID = makePeerID()
        let addr1 = try Multiaddr("/ip4/127.0.0.1/tcp/4001")
        let addr2 = try Multiaddr("/ip4/127.0.0.1/udp/4002/quic-v1")

        let announcement = PlumtreeDiscoveryAnnouncement(
            peerID: peerID,
            addresses: [addr1, addr2],
            timestamp: 123,
            sequenceNumber: 7
        )

        let encoded = try announcement.encode()
        let decoded = try PlumtreeDiscoveryAnnouncement.decode(encoded)

        #expect(decoded.peerID == peerID.description)
        #expect(decoded.addresses == [addr1.description, addr2.description])
        #expect(decoded.timestamp == 123)
        #expect(decoded.sequenceNumber == 7)
    }

    @Test("Ingest announcement updates known peers and find")
    func ingestAnnouncement() async throws {
        let localPeer = makePeerID()
        let remotePeer = makePeerID()
        let discovery = PlumtreeDiscovery(
            localPeerID: localPeer,
            configuration: .testing
        )

        let address = try Multiaddr("/ip4/10.0.0.1/tcp/4010")
        let announcement = PlumtreeDiscoveryAnnouncement(
            peerID: remotePeer,
            addresses: [address],
            timestamp: UInt64(Date().timeIntervalSince1970),
            sequenceNumber: 1
        )

        try await discovery.ingestAnnouncement(announcement, source: remotePeer)

        let known = await discovery.knownPeers()
        #expect(known.contains(remotePeer))

        let candidates = try await discovery.find(peer: remotePeer)
        #expect(candidates.count == 1)
        #expect(candidates[0].peerID == remotePeer)
        #expect(candidates[0].addresses == [address])
        #expect(candidates[0].score > 0.0)
    }

    @Test("Older sequence announcements are ignored")
    func staleAnnouncementIgnored() async throws {
        let localPeer = makePeerID()
        let remotePeer = makePeerID()
        let discovery = PlumtreeDiscovery(
            localPeerID: localPeer,
            configuration: .testing
        )

        let newerAddress = try Multiaddr("/ip4/10.0.0.1/tcp/4011")
        let olderAddress = try Multiaddr("/ip4/10.0.0.1/tcp/4012")

        let seq2 = PlumtreeDiscoveryAnnouncement(
            peerID: remotePeer,
            addresses: [newerAddress],
            timestamp: UInt64(Date().timeIntervalSince1970),
            sequenceNumber: 2
        )
        let seq1 = PlumtreeDiscoveryAnnouncement(
            peerID: remotePeer,
            addresses: [olderAddress],
            timestamp: UInt64(Date().timeIntervalSince1970),
            sequenceNumber: 1
        )

        try await discovery.ingestAnnouncement(seq2, source: remotePeer)
        try await discovery.ingestAnnouncement(seq1, source: remotePeer)

        let candidates = try await discovery.find(peer: remotePeer)
        #expect(candidates.count == 1)
        #expect(candidates[0].addresses == [newerAddress])
    }

    @Test("Subscribe emits reachable observation for ingested announcement", .timeLimit(.minutes(1)))
    func subscribeReceivesObservation() async throws {
        let localPeer = makePeerID()
        let remotePeer = makePeerID()
        let discovery = PlumtreeDiscovery(
            localPeerID: localPeer,
            configuration: .testing
        )

        let address = try Multiaddr("/ip4/10.0.0.2/tcp/4020")
        let announcement = PlumtreeDiscoveryAnnouncement(
            peerID: remotePeer,
            addresses: [address],
            timestamp: UInt64(Date().timeIntervalSince1970),
            sequenceNumber: 1
        )

        let stream = discovery.subscribe(to: remotePeer)
        let observationTask = Task { () -> PeerObservation? in
            for await observation in stream {
                return observation
            }
            return nil
        }
        defer { observationTask.cancel() }

        try await discovery.ingestAnnouncement(announcement, source: remotePeer)

        let observation = try await withTimeout(.seconds(1)) {
            await observationTask.value
        }

        #expect(observation?.subject == remotePeer)
        #expect(observation?.observer == localPeer)
        #expect(observation?.kind == .reachable)
        #expect(observation?.hints == [address])
    }

    @Test("Announce before start throws notStarted")
    func announceRequiresStart() async throws {
        let discovery = PlumtreeDiscovery(
            localPeerID: makePeerID(),
            configuration: .testing
        )
        let addr = try Multiaddr("/ip4/127.0.0.1/tcp/4999")

        do {
            try await discovery.announce(addresses: [addr])
            Issue.record("Expected PlumtreeDiscoveryError.notStarted")
        } catch let error as PlumtreeDiscoveryError {
            #expect(error == .notStarted)
        }
    }

}

private enum TimeoutError: Error {
    case timedOut
}

private func withTimeout<T: Sendable>(
    _ duration: Duration,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(for: duration)
            throw TimeoutError.timedOut
        }

        guard let first = try await group.next() else {
            throw TimeoutError.timedOut
        }
        group.cancelAll()
        return first
    }
}
