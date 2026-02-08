import Testing
@testable import P2PCore

@Suite("BandwidthReporter")
struct BandwidthReporterTests {

    private func makePeerID() -> PeerID {
        PeerID(publicKey: KeyPair.generateEd25519().publicKey)
    }

    @Test("record inbound bytes")
    func recordInbound() {
        let reporter = BandwidthReporter()
        reporter.recordInbound(bytes: 100)
        reporter.recordInbound(bytes: 200)

        let stats = reporter.stats()
        #expect(stats.totalBytesIn == 300)
        #expect(stats.totalBytesOut == 0)
    }

    @Test("record outbound bytes")
    func recordOutbound() {
        let reporter = BandwidthReporter()
        reporter.recordOutbound(bytes: 500)

        let stats = reporter.stats()
        #expect(stats.totalBytesOut == 500)
        #expect(stats.totalBytesIn == 0)
    }

    @Test("per-peer tracking")
    func perPeer() {
        let reporter = BandwidthReporter()
        let peer1 = makePeerID()
        let peer2 = makePeerID()

        reporter.recordInbound(bytes: 100, peer: peer1)
        reporter.recordInbound(bytes: 200, peer: peer2)
        reporter.recordOutbound(bytes: 50, peer: peer1)

        let byPeer = reporter.statsByPeer()
        #expect(byPeer[peer1]?.totalBytesIn == 100)
        #expect(byPeer[peer1]?.totalBytesOut == 50)
        #expect(byPeer[peer2]?.totalBytesIn == 200)
        #expect(byPeer[peer2]?.totalBytesOut == 0)
    }

    @Test("per-protocol tracking")
    func perProtocol() {
        let reporter = BandwidthReporter()

        reporter.recordInbound(bytes: 100, protocol: "/ipfs/ping/1.0.0")
        reporter.recordInbound(bytes: 200, protocol: "/ipfs/id/1.0.0")
        reporter.recordOutbound(bytes: 300, protocol: "/ipfs/ping/1.0.0")

        let byProto = reporter.statsByProtocol()
        #expect(byProto["/ipfs/ping/1.0.0"]?.totalBytesIn == 100)
        #expect(byProto["/ipfs/ping/1.0.0"]?.totalBytesOut == 300)
        #expect(byProto["/ipfs/id/1.0.0"]?.totalBytesIn == 200)
    }

    @Test("reset clears all counters")
    func reset() {
        let reporter = BandwidthReporter()
        reporter.recordInbound(bytes: 100)
        reporter.recordOutbound(bytes: 200)
        reporter.reset()

        let stats = reporter.stats()
        #expect(stats.totalBytesIn == 0)
        #expect(stats.totalBytesOut == 0)
    }

    @Test("concurrent recording is safe", .timeLimit(.minutes(1)))
    func concurrentRecording() async {
        let reporter = BandwidthReporter()
        let peer = makePeerID()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<1000 {
                group.addTask {
                    reporter.recordInbound(bytes: 1, protocol: "/test", peer: peer)
                }
                group.addTask {
                    reporter.recordOutbound(bytes: 1, protocol: "/test", peer: peer)
                }
            }
        }

        let stats = reporter.stats()
        #expect(stats.totalBytesIn == 1000)
        #expect(stats.totalBytesOut == 1000)
    }

    @Test("mixed peer and protocol tracking")
    func mixedTracking() {
        let reporter = BandwidthReporter()
        let peer = makePeerID()

        reporter.recordInbound(bytes: 100, protocol: "/test", peer: peer)

        let stats = reporter.stats()
        let byPeer = reporter.statsByPeer()
        let byProto = reporter.statsByProtocol()

        #expect(stats.totalBytesIn == 100)
        #expect(byPeer[peer]?.totalBytesIn == 100)
        #expect(byProto["/test"]?.totalBytesIn == 100)
    }

    @Test("stats without any recording returns zeros")
    func emptyStats() {
        let reporter = BandwidthReporter()
        let stats = reporter.stats()
        #expect(stats.totalBytesIn == 0)
        #expect(stats.totalBytesOut == 0)
        #expect(stats.rateIn == 0)
        #expect(stats.rateOut == 0)
    }

    @Test("statsByPeer returns empty when no peers recorded")
    func emptyStatsByPeer() {
        let reporter = BandwidthReporter()
        let byPeer = reporter.statsByPeer()
        #expect(byPeer.isEmpty)
    }

    @Test("statsByProtocol returns empty when no protocols recorded")
    func emptyStatsByProtocol() {
        let reporter = BandwidthReporter()
        let byProto = reporter.statsByProtocol()
        #expect(byProto.isEmpty)
    }

    // MARK: - Negative bytes guard

    @Test("negative inbound bytes are ignored")
    func negativeInboundIgnored() {
        let reporter = BandwidthReporter()
        reporter.recordInbound(bytes: 100)
        reporter.recordInbound(bytes: -50)

        let stats = reporter.stats()
        #expect(stats.totalBytesIn == 100)
    }

    @Test("negative outbound bytes are ignored")
    func negativeOutboundIgnored() {
        let reporter = BandwidthReporter()
        reporter.recordOutbound(bytes: 200)
        reporter.recordOutbound(bytes: -100)

        let stats = reporter.stats()
        #expect(stats.totalBytesOut == 200)
    }

    @Test("zero inbound bytes are ignored")
    func zeroInboundIgnored() {
        let reporter = BandwidthReporter()
        reporter.recordInbound(bytes: 0)

        let stats = reporter.stats()
        #expect(stats.totalBytesIn == 0)
    }

    @Test("zero outbound bytes are ignored")
    func zeroOutboundIgnored() {
        let reporter = BandwidthReporter()
        reporter.recordOutbound(bytes: 0)

        let stats = reporter.stats()
        #expect(stats.totalBytesOut == 0)
    }

    @Test("negative bytes do not affect per-peer or per-protocol tracking")
    func negativeBytesPeerProtocol() {
        let reporter = BandwidthReporter()
        let peer = makePeerID()

        reporter.recordInbound(bytes: -10, protocol: "/test", peer: peer)
        reporter.recordOutbound(bytes: -20, protocol: "/test", peer: peer)

        let byPeer = reporter.statsByPeer()
        let byProto = reporter.statsByProtocol()

        #expect(byPeer.isEmpty)
        #expect(byProto.isEmpty)
    }
}
