import Testing
import Foundation
import NIOCore
import Synchronization
@testable import P2P
@testable import P2PCore
@testable import P2PMux

@Suite("ResourceManager Tests")
struct ResourceManagerTests {

    // MARK: - Helpers

    private func makePeer() -> PeerID {
        KeyPair.generateEd25519().peerID
    }

    private func makeManager(
        system: ScopeLimits = .defaultSystem,
        peer: ScopeLimits = .defaultPeer,
        peerOverrides: [PeerID: ScopeLimits] = [:]
    ) -> DefaultResourceManager {
        DefaultResourceManager(
            configuration: ResourceLimitsConfiguration(
                system: system,
                peer: peer,
                peerOverrides: peerOverrides
            )
        )
    }

    // MARK: - Connection Reserve/Release

    @Test("Reserve and release inbound connections")
    func testReserveReleaseInboundConnections() throws {
        let rm = makeManager()
        let peer = makePeer()

        try rm.reserveInboundConnection(from: peer)

        let snap = rm.snapshot()
        #expect(snap.system.inboundConnections == 1)
        #expect(snap.peers[peer]?.inboundConnections == 1)

        rm.releaseConnection(peer: peer, direction: .inbound)

        let snap2 = rm.snapshot()
        #expect(snap2.system.inboundConnections == 0)
        #expect(snap2.peers[peer] == nil) // cleaned up
    }

    @Test("Reserve and release outbound connections")
    func testReserveReleaseOutboundConnections() throws {
        let rm = makeManager()
        let peer = makePeer()

        try rm.reserveOutboundConnection(to: peer)

        let snap = rm.snapshot()
        #expect(snap.system.outboundConnections == 1)
        #expect(snap.peers[peer]?.outboundConnections == 1)

        rm.releaseConnection(peer: peer, direction: .outbound)

        let snap2 = rm.snapshot()
        #expect(snap2.system.outboundConnections == 0)
        #expect(snap2.peers[peer] == nil)
    }

    // MARK: - Stream Reserve/Release

    @Test("Reserve and release inbound streams")
    func testReserveReleaseInboundStreams() throws {
        let rm = makeManager()
        let peer = makePeer()

        try rm.reserveInboundStream(from: peer)

        let snap = rm.snapshot()
        #expect(snap.system.inboundStreams == 1)
        #expect(snap.peers[peer]?.inboundStreams == 1)

        rm.releaseStream(peer: peer, direction: .inbound)

        let snap2 = rm.snapshot()
        #expect(snap2.system.inboundStreams == 0)
        #expect(snap2.peers[peer] == nil)
    }

    @Test("Reserve and release outbound streams")
    func testReserveReleaseOutboundStreams() throws {
        let rm = makeManager()
        let peer = makePeer()

        try rm.reserveOutboundStream(to: peer)

        let snap = rm.snapshot()
        #expect(snap.system.outboundStreams == 1)
        #expect(snap.peers[peer]?.outboundStreams == 1)

        rm.releaseStream(peer: peer, direction: .outbound)

        let snap2 = rm.snapshot()
        #expect(snap2.system.outboundStreams == 0)
        #expect(snap2.peers[peer] == nil)
    }

    // MARK: - Memory Reserve/Release

    @Test("Reserve and release memory")
    func testReserveReleaseMemory() throws {
        let rm = makeManager()
        let peer = makePeer()

        try rm.reserveMemory(1024, for: peer)

        let snap = rm.snapshot()
        #expect(snap.system.memory == 1024)
        #expect(snap.peers[peer]?.memory == 1024)

        rm.releaseMemory(1024, for: peer)

        let snap2 = rm.snapshot()
        #expect(snap2.system.memory == 0)
        #expect(snap2.peers[peer] == nil)
    }

    // MARK: - System Limit Enforcement

    @Test("System inbound connection limit enforced")
    func testSystemInboundConnectionLimit() throws {
        let rm = makeManager(
            system: ScopeLimits(maxInboundConnections: 2, maxTotalConnections: 10),
            peer: .unlimited
        )
        let peer1 = makePeer()
        let peer2 = makePeer()
        let peer3 = makePeer()

        try rm.reserveInboundConnection(from: peer1)
        try rm.reserveInboundConnection(from: peer2)

        #expect(throws: ResourceError.self) {
            try rm.reserveInboundConnection(from: peer3)
        }

        // System counter unchanged after failed reservation
        let snap = rm.snapshot()
        #expect(snap.system.inboundConnections == 2)
    }

    @Test("System outbound connection limit enforced")
    func testSystemOutboundConnectionLimit() throws {
        let rm = makeManager(
            system: ScopeLimits(maxOutboundConnections: 1, maxTotalConnections: 10),
            peer: .unlimited
        )
        let peer1 = makePeer()
        let peer2 = makePeer()

        try rm.reserveOutboundConnection(to: peer1)

        #expect(throws: ResourceError.self) {
            try rm.reserveOutboundConnection(to: peer2)
        }
    }

    @Test("System total connection limit enforced")
    func testSystemTotalConnectionLimit() throws {
        let rm = makeManager(
            system: ScopeLimits(maxInboundConnections: 10, maxOutboundConnections: 10, maxTotalConnections: 2),
            peer: .unlimited
        )
        let peer1 = makePeer()
        let peer2 = makePeer()
        let peer3 = makePeer()

        try rm.reserveInboundConnection(from: peer1)
        try rm.reserveOutboundConnection(to: peer2)

        #expect(throws: ResourceError.self) {
            try rm.reserveInboundConnection(from: peer3)
        }
    }

    @Test("System inbound stream limit enforced")
    func testSystemInboundStreamLimit() throws {
        let rm = makeManager(
            system: ScopeLimits(maxInboundStreams: 2, maxTotalStreams: 10),
            peer: .unlimited
        )
        let peer1 = makePeer()
        let peer2 = makePeer()
        let peer3 = makePeer()

        try rm.reserveInboundStream(from: peer1)
        try rm.reserveInboundStream(from: peer2)

        #expect(throws: ResourceError.self) {
            try rm.reserveInboundStream(from: peer3)
        }
    }

    @Test("System outbound stream limit enforced")
    func testSystemOutboundStreamLimit() throws {
        let rm = makeManager(
            system: ScopeLimits(maxOutboundStreams: 2, maxTotalStreams: 10),
            peer: .unlimited
        )
        let peer1 = makePeer()
        let peer2 = makePeer()
        let peer3 = makePeer()

        try rm.reserveOutboundStream(to: peer1)
        try rm.reserveOutboundStream(to: peer2)

        #expect(throws: ResourceError.self) {
            try rm.reserveOutboundStream(to: peer3)
        }
    }

    @Test("System total stream limit enforced")
    func testSystemTotalStreamLimit() throws {
        let rm = makeManager(
            system: ScopeLimits(maxInboundStreams: 10, maxOutboundStreams: 10, maxTotalStreams: 2),
            peer: .unlimited
        )
        let peer1 = makePeer()
        let peer2 = makePeer()
        let peer3 = makePeer()

        try rm.reserveInboundStream(from: peer1)
        try rm.reserveOutboundStream(to: peer2)

        #expect(throws: ResourceError.self) {
            try rm.reserveOutboundStream(to: peer3)
        }
    }

    @Test("System memory limit enforced")
    func testSystemMemoryLimit() throws {
        let rm = makeManager(
            system: ScopeLimits(maxMemory: 1000),
            peer: .unlimited
        )
        let peer = makePeer()

        try rm.reserveMemory(800, for: peer)

        #expect(throws: ResourceError.self) {
            try rm.reserveMemory(300, for: peer)
        }

        // Memory unchanged after failed reservation
        let snap = rm.snapshot()
        #expect(snap.system.memory == 800)
    }

    // MARK: - Peer Limit Enforcement

    @Test("Peer inbound connection limit enforced")
    func testPeerInboundConnectionLimit() throws {
        let rm = makeManager(
            system: .unlimited,
            peer: ScopeLimits(maxInboundConnections: 1, maxTotalConnections: 10)
        )
        let peer = makePeer()

        try rm.reserveInboundConnection(from: peer)

        #expect(throws: ResourceError.self) {
            try rm.reserveInboundConnection(from: peer)
        }
    }

    @Test("Peer total connection limit enforced")
    func testPeerTotalConnectionLimit() throws {
        let rm = makeManager(
            system: .unlimited,
            peer: ScopeLimits(maxInboundConnections: 10, maxOutboundConnections: 10, maxTotalConnections: 2)
        )
        let peer = makePeer()

        try rm.reserveInboundConnection(from: peer)
        try rm.reserveOutboundConnection(to: peer)

        #expect(throws: ResourceError.self) {
            try rm.reserveInboundConnection(from: peer)
        }
    }

    @Test("Peer inbound stream limit enforced")
    func testPeerInboundStreamLimit() throws {
        let rm = makeManager(
            system: .unlimited,
            peer: ScopeLimits(maxInboundStreams: 1, maxTotalStreams: 10)
        )
        let peer = makePeer()

        try rm.reserveInboundStream(from: peer)

        #expect(throws: ResourceError.self) {
            try rm.reserveInboundStream(from: peer)
        }
    }

    @Test("Peer outbound stream limit enforced")
    func testPeerOutboundStreamLimit() throws {
        let rm = makeManager(
            system: .unlimited,
            peer: ScopeLimits(maxOutboundStreams: 1, maxTotalStreams: 10)
        )
        let peer = makePeer()

        try rm.reserveOutboundStream(to: peer)

        #expect(throws: ResourceError.self) {
            try rm.reserveOutboundStream(to: peer)
        }
    }

    @Test("Peer total stream limit enforced")
    func testPeerTotalStreamLimit() throws {
        let rm = makeManager(
            system: .unlimited,
            peer: ScopeLimits(maxInboundStreams: 10, maxOutboundStreams: 10, maxTotalStreams: 2)
        )
        let peer = makePeer()

        try rm.reserveInboundStream(from: peer)
        try rm.reserveOutboundStream(to: peer)

        #expect(throws: ResourceError.self) {
            try rm.reserveInboundStream(from: peer)
        }
    }

    @Test("Peer memory limit enforced")
    func testPeerMemoryLimit() throws {
        let rm = makeManager(
            system: .unlimited,
            peer: ScopeLimits(maxMemory: 500)
        )
        let peer = makePeer()

        try rm.reserveMemory(400, for: peer)

        #expect(throws: ResourceError.self) {
            try rm.reserveMemory(200, for: peer)
        }
    }

    // MARK: - Atomic Reservation (No Partial Mutation)

    @Test("Peer limit hit does not mutate system counters")
    func testAtomicReservation() throws {
        let rm = makeManager(
            system: ScopeLimits(maxInboundConnections: 10, maxTotalConnections: 100),
            peer: ScopeLimits(maxInboundConnections: 1, maxTotalConnections: 10)
        )
        let peer = makePeer()

        try rm.reserveInboundConnection(from: peer)
        let systemBefore = rm.snapshot().system.inboundConnections

        // This should fail due to peer limit
        #expect(throws: ResourceError.self) {
            try rm.reserveInboundConnection(from: peer)
        }

        // System counter must NOT have been incremented
        let systemAfter = rm.snapshot().system.inboundConnections
        #expect(systemAfter == systemBefore)
    }

    @Test("System limit hit does not mutate peer counters")
    func testAtomicReservationSystemLimit() throws {
        let rm = makeManager(
            system: ScopeLimits(maxInboundConnections: 1, maxTotalConnections: 100),
            peer: .unlimited
        )
        let peer1 = makePeer()
        let peer2 = makePeer()

        try rm.reserveInboundConnection(from: peer1)

        // This should fail due to system limit
        #expect(throws: ResourceError.self) {
            try rm.reserveInboundConnection(from: peer2)
        }

        // Peer2 counter must NOT have been created
        let snap = rm.snapshot()
        #expect(snap.peers[peer2] == nil)
    }

    // MARK: - Peer Cleanup

    @Test("Zero-resource peers are removed from map")
    func testPeerCleanup() throws {
        let rm = makeManager()
        let peer = makePeer()

        try rm.reserveInboundConnection(from: peer)
        try rm.reserveOutboundStream(to: peer)

        // Release one resource — peer should still exist
        rm.releaseConnection(peer: peer, direction: .inbound)
        let snap1 = rm.snapshot()
        #expect(snap1.peers[peer] != nil)

        // Release the other — peer should be garbage-collected
        rm.releaseStream(peer: peer, direction: .outbound)
        let snap2 = rm.snapshot()
        #expect(snap2.peers[peer] == nil)
    }

    // MARK: - Slot Reuse

    @Test("Released slot can be reserved again")
    func testSlotReuse() throws {
        let rm = makeManager(
            system: ScopeLimits(maxInboundConnections: 1, maxTotalConnections: 10),
            peer: .unlimited
        )
        let peer1 = makePeer()
        let peer2 = makePeer()

        try rm.reserveInboundConnection(from: peer1)

        // Limit reached
        #expect(throws: ResourceError.self) {
            try rm.reserveInboundConnection(from: peer2)
        }

        // Release frees the slot
        rm.releaseConnection(peer: peer1, direction: .inbound)

        // Now reservation succeeds
        try rm.reserveInboundConnection(from: peer2)
        #expect(rm.snapshot().system.inboundConnections == 1)
    }

    // MARK: - Snapshot Accuracy

    @Test("Snapshot reflects current state accurately")
    func testSnapshotAccuracy() throws {
        let rm = makeManager()
        let peer1 = makePeer()
        let peer2 = makePeer()

        try rm.reserveInboundConnection(from: peer1)
        try rm.reserveOutboundConnection(to: peer1)
        try rm.reserveInboundStream(from: peer2)
        try rm.reserveMemory(2048, for: peer2)

        let snap = rm.snapshot()

        #expect(snap.system.inboundConnections == 1)
        #expect(snap.system.outboundConnections == 1)
        #expect(snap.system.totalConnections == 2)
        #expect(snap.system.inboundStreams == 1)
        #expect(snap.system.outboundStreams == 0)
        #expect(snap.system.memory == 2048)

        #expect(snap.peers[peer1]?.inboundConnections == 1)
        #expect(snap.peers[peer1]?.outboundConnections == 1)
        #expect(snap.peers[peer2]?.inboundStreams == 1)
        #expect(snap.peers[peer2]?.memory == 2048)

        #expect(snap.peers.count == 2)
    }

    // MARK: - Scope Access

    @Test("System scope returns current stats and limits")
    func testSystemScope() throws {
        let rm = makeManager(
            system: ScopeLimits(maxInboundConnections: 42)
        )
        let peer = makePeer()
        try rm.reserveInboundConnection(from: peer)

        let scope = rm.systemScope
        #expect(scope.name == "system")
        #expect(scope.stat.inboundConnections == 1)
        #expect(scope.limits.maxInboundConnections == 42)
    }

    @Test("Peer scope returns current stats and limits")
    func testPeerScope() throws {
        let rm = makeManager(
            peer: ScopeLimits(maxOutboundStreams: 99)
        )
        let peer = makePeer()
        try rm.reserveOutboundStream(to: peer)

        let scope = rm.peerScope(for: peer)
        #expect(scope.stat.outboundStreams == 1)
        #expect(scope.limits.maxOutboundStreams == 99)
    }

    // MARK: - NullResourceManager

    @Test("NullResourceManager allows all operations")
    func testNullResourceManager() throws {
        let rm = NullResourceManager()
        let peer = makePeer()

        // All of these should succeed without error
        try rm.reserveInboundConnection(from: peer)
        try rm.reserveOutboundConnection(to: peer)
        try rm.reserveInboundStream(from: peer)
        try rm.reserveOutboundStream(to: peer)
        try rm.reserveMemory(1_000_000_000, for: peer)

        rm.releaseConnection(peer: peer, direction: .inbound)
        rm.releaseConnection(peer: peer, direction: .outbound)
        rm.releaseStream(peer: peer, direction: .inbound)
        rm.releaseStream(peer: peer, direction: .outbound)
        rm.releaseMemory(1_000_000_000, for: peer)

        let snap = rm.snapshot()
        #expect(snap.system == ResourceStat())
        #expect(snap.peers.isEmpty)
    }

    @Test("NullResourceManager scopes report zero and unlimited")
    func testNullResourceManagerScopes() {
        let rm = NullResourceManager()
        let peer = makePeer()

        let systemScope = rm.systemScope
        #expect(systemScope.name == "system")
        #expect(systemScope.stat == ResourceStat())
        #expect(systemScope.limits == .unlimited)

        let peerScope = rm.peerScope(for: peer)
        #expect(peerScope.stat == ResourceStat())
        #expect(peerScope.limits == .unlimited)
    }

    // MARK: - Per-Peer Overrides

    @Test("Per-peer overrides apply custom limits")
    func testPerPeerOverrides() throws {
        let specialPeer = makePeer()
        let normalPeer = makePeer()

        let rm = makeManager(
            system: .unlimited,
            peer: ScopeLimits(maxInboundConnections: 1),
            peerOverrides: [specialPeer: ScopeLimits(maxInboundConnections: 3)]
        )

        // Normal peer: limit is 1
        try rm.reserveInboundConnection(from: normalPeer)
        #expect(throws: ResourceError.self) {
            try rm.reserveInboundConnection(from: normalPeer)
        }

        // Special peer: limit is 3
        try rm.reserveInboundConnection(from: specialPeer)
        try rm.reserveInboundConnection(from: specialPeer)
        try rm.reserveInboundConnection(from: specialPeer)
        #expect(throws: ResourceError.self) {
            try rm.reserveInboundConnection(from: specialPeer)
        }
    }

    // MARK: - ResourceError Values

    @Test("ResourceError contains correct scope and resource strings")
    func testResourceErrorValues() throws {
        let rm = makeManager(
            system: ScopeLimits(maxInboundConnections: 0),
            peer: .unlimited
        )
        let peer = makePeer()

        do {
            try rm.reserveInboundConnection(from: peer)
            Issue.record("Expected ResourceError to be thrown")
        } catch let error as ResourceError {
            #expect(error == .limitExceeded(scope: "system", resource: "inboundConnections"))
        }
    }

    @Test("ResourceError contains peer scope for peer limit violation")
    func testResourceErrorPeerScope() throws {
        let rm = makeManager(
            system: .unlimited,
            peer: ScopeLimits(maxOutboundStreams: 0)
        )
        let peer = makePeer()

        do {
            try rm.reserveOutboundStream(to: peer)
            Issue.record("Expected ResourceError to be thrown")
        } catch let error as ResourceError {
            if case .limitExceeded(let scope, let resource) = error {
                #expect(scope.hasPrefix("peer:"))
                #expect(resource == "outboundStreams")
            } else {
                Issue.record("Unexpected error case")
            }
        }
    }

    // MARK: - ResourceTrackedStream

    @Test("ResourceTrackedStream releases on close exactly once")
    func testResourceTrackedStreamClose() async throws {
        let rm = makeManager(system: .unlimited, peer: .unlimited)
        let peer = makePeer()
        try rm.reserveOutboundStream(to: peer)

        let mockStream = MockMuxedStream()
        let tracked = ResourceTrackedStream(
            stream: mockStream,
            peer: peer,
            direction: .outbound,
            resourceManager: rm
        )

        #expect(rm.snapshot().system.outboundStreams == 1)

        try await tracked.close()

        #expect(rm.snapshot().system.outboundStreams == 0)

        // Second close should not underflow
        try await tracked.close()
        #expect(rm.snapshot().system.outboundStreams == 0)
    }

    @Test("ResourceTrackedStream releases on reset exactly once")
    func testResourceTrackedStreamReset() async throws {
        let rm = makeManager(system: .unlimited, peer: .unlimited)
        let peer = makePeer()
        try rm.reserveInboundStream(from: peer)

        let mockStream = MockMuxedStream()
        let tracked = ResourceTrackedStream(
            stream: mockStream,
            peer: peer,
            direction: .inbound,
            resourceManager: rm
        )

        #expect(rm.snapshot().system.inboundStreams == 1)

        try await tracked.reset()

        #expect(rm.snapshot().system.inboundStreams == 0)
    }

    @Test("ResourceTrackedStream releases on deinit")
    func testResourceTrackedStreamDeinit() throws {
        let rm = makeManager(system: .unlimited, peer: .unlimited)
        let peer = makePeer()
        try rm.reserveOutboundStream(to: peer)

        var tracked: ResourceTrackedStream? = ResourceTrackedStream(
            stream: MockMuxedStream(),
            peer: peer,
            direction: .outbound,
            resourceManager: rm
        )
        _ = tracked // suppress unused warning

        #expect(rm.snapshot().system.outboundStreams == 1)

        tracked = nil

        #expect(rm.snapshot().system.outboundStreams == 0)
    }

    @Test("ResourceTrackedStream delegates read/write")
    func testResourceTrackedStreamDelegation() async throws {
        let rm = NullResourceManager()
        let peer = makePeer()
        let mockStream = MockMuxedStream()
        let tracked = ResourceTrackedStream(
            stream: mockStream,
            peer: peer,
            direction: .outbound,
            resourceManager: rm
        )

        #expect(tracked.id == mockStream.id)

        let data = ByteBuffer(bytes: [1, 2, 3])
        try await tracked.write(data)
        #expect(mockStream.writtenData == [data])

        mockStream.setReadBuffer([ByteBuffer(bytes: [4, 5, 6])])
        let result = try await tracked.read()
        #expect(result == ByteBuffer(bytes: [4, 5, 6]))
    }

    @Test("ResourceTrackedStream delegates closeWrite and closeRead")
    func testResourceTrackedStreamCloseWriteRead() async throws {
        let rm = NullResourceManager()
        let peer = makePeer()
        let mockStream = MockMuxedStream()
        let tracked = ResourceTrackedStream(
            stream: mockStream,
            peer: peer,
            direction: .outbound,
            resourceManager: rm
        )

        try await tracked.closeWrite()
        #expect(mockStream.closeWriteCalled)

        try await tracked.closeRead()
        #expect(mockStream.closeReadCalled)
    }

    // MARK: - ResourceStat Value Type

    @Test("ResourceStat computed properties")
    func testResourceStatComputedProperties() {
        var stat = ResourceStat()
        #expect(stat.isZero)
        #expect(stat.totalConnections == 0)
        #expect(stat.totalStreams == 0)

        stat.inboundConnections = 2
        stat.outboundConnections = 3
        stat.inboundStreams = 10
        stat.outboundStreams = 5
        stat.memory = 1024

        #expect(!stat.isZero)
        #expect(stat.totalConnections == 5)
        #expect(stat.totalStreams == 15)
    }

    // MARK: - ScopeLimits Presets

    @Test("ScopeLimits default presets")
    func testScopeLimitsPresets() {
        let system = ScopeLimits.defaultSystem
        #expect(system.maxInboundConnections == 128)
        #expect(system.maxOutboundConnections == 128)
        #expect(system.maxTotalConnections == 256)
        #expect(system.maxInboundStreams == 4096)
        #expect(system.maxOutboundStreams == 4096)
        #expect(system.maxTotalStreams == 8192)
        #expect(system.maxMemory == 128 * 1024 * 1024)

        let peer = ScopeLimits.defaultPeer
        #expect(peer.maxInboundConnections == 2)
        #expect(peer.maxOutboundConnections == 2)
        #expect(peer.maxTotalConnections == 4)
        #expect(peer.maxInboundStreams == 256)
        #expect(peer.maxOutboundStreams == 256)
        #expect(peer.maxTotalStreams == 512)
        #expect(peer.maxMemory == 16 * 1024 * 1024)

        let unlimited = ScopeLimits.unlimited
        #expect(unlimited.maxInboundConnections == nil)
        #expect(unlimited.maxMemory == nil)
    }

    // MARK: - Release Never Underflows

    @Test("Release does not underflow below zero")
    func testReleaseNoUnderflow() {
        let rm = makeManager()
        let peer = makePeer()

        // Release without prior reserve
        rm.releaseConnection(peer: peer, direction: .inbound)
        rm.releaseStream(peer: peer, direction: .outbound)
        rm.releaseMemory(1000, for: peer)

        let snap = rm.snapshot()
        #expect(snap.system.inboundConnections == 0)
        #expect(snap.system.outboundStreams == 0)
        #expect(snap.system.memory == 0)
    }

    // MARK: - NodeError Integration

    @Test("NodeError has resourceLimitExceeded case")
    func testNodeErrorResourceLimitExceeded() {
        let error = NodeError.resourceLimitExceeded(scope: "system", resource: "inboundConnections")
        if case .resourceLimitExceeded(let scope, let resource) = error {
            #expect(scope == "system")
            #expect(resource == "inboundConnections")
        } else {
            Issue.record("Expected resourceLimitExceeded case")
        }
    }

    // MARK: - Protocol Scope

    @Test("Protocol stream reserve and release")
    func testProtocolStreamReserveRelease() throws {
        let rm = makeManager(system: .unlimited, peer: .unlimited)
        let peer = makePeer()

        try rm.reserveStream(protocolID: "/kad/1.0.0", peer: peer, direction: .inbound)

        let snap = rm.snapshot()
        #expect(snap.system.inboundStreams == 1)
        #expect(snap.peers[peer]?.inboundStreams == 1)
        #expect(snap.protocols["/kad/1.0.0"]?.inboundStreams == 1)

        rm.releaseStream(protocolID: "/kad/1.0.0", peer: peer, direction: .inbound)

        let snap2 = rm.snapshot()
        #expect(snap2.system.inboundStreams == 0)
        #expect(snap2.peers[peer] == nil)
        #expect(snap2.protocols["/kad/1.0.0"] == nil)
    }

    @Test("Protocol stream limit enforced")
    func testProtocolStreamLimit() throws {
        let rm = DefaultResourceManager(
            configuration: ResourceLimitsConfiguration(
                system: .unlimited,
                peer: .unlimited,
                protocolLimits: ScopeLimits(maxTotalStreams: 2)
            )
        )
        let peer1 = makePeer()
        let peer2 = makePeer()
        let peer3 = makePeer()

        try rm.reserveStream(protocolID: "/test/1.0", peer: peer1, direction: .inbound)
        try rm.reserveStream(protocolID: "/test/1.0", peer: peer2, direction: .outbound)

        #expect(throws: ResourceError.self) {
            try rm.reserveStream(protocolID: "/test/1.0", peer: peer3, direction: .inbound)
        }

        // Different protocol should still work
        try rm.reserveStream(protocolID: "/other/1.0", peer: peer3, direction: .inbound)
    }

    @Test("Protocol limit hit does not mutate system/peer counters")
    func testProtocolAtomicReservation() throws {
        let rm = DefaultResourceManager(
            configuration: ResourceLimitsConfiguration(
                system: .unlimited,
                peer: .unlimited,
                protocolLimits: ScopeLimits(maxTotalStreams: 1)
            )
        )
        let peer1 = makePeer()
        let peer2 = makePeer()

        try rm.reserveStream(protocolID: "/test/1.0", peer: peer1, direction: .inbound)
        let systemBefore = rm.snapshot().system.inboundStreams

        #expect(throws: ResourceError.self) {
            try rm.reserveStream(protocolID: "/test/1.0", peer: peer2, direction: .inbound)
        }

        // System counter must NOT have been incremented
        #expect(rm.snapshot().system.inboundStreams == systemBefore)
        // Peer2 must NOT have been created
        #expect(rm.snapshot().peers[peer2] == nil)
    }

    @Test("Protocol cleanup removes zero-count entries")
    func testProtocolCleanup() throws {
        let rm = makeManager(system: .unlimited, peer: .unlimited)
        let peer = makePeer()

        try rm.reserveStream(protocolID: "/test/1.0", peer: peer, direction: .outbound)
        #expect(rm.snapshot().protocols["/test/1.0"] != nil)

        rm.releaseStream(protocolID: "/test/1.0", peer: peer, direction: .outbound)
        #expect(rm.snapshot().protocols["/test/1.0"] == nil)
    }

    @Test("Per-protocol overrides apply custom limits")
    func testPerProtocolOverrides() throws {
        let rm = DefaultResourceManager(
            configuration: ResourceLimitsConfiguration(
                system: .unlimited,
                peer: .unlimited,
                protocolLimits: ScopeLimits(maxTotalStreams: 1),
                protocolOverrides: ["/special/1.0": ScopeLimits(maxTotalStreams: 3)]
            )
        )
        let peer = makePeer()

        // Normal protocol: limit is 1
        try rm.reserveStream(protocolID: "/normal/1.0", peer: peer, direction: .inbound)
        #expect(throws: ResourceError.self) {
            try rm.reserveStream(protocolID: "/normal/1.0", peer: peer, direction: .inbound)
        }

        // Special protocol: limit is 3
        try rm.reserveStream(protocolID: "/special/1.0", peer: peer, direction: .inbound)
        try rm.reserveStream(protocolID: "/special/1.0", peer: peer, direction: .inbound)
        try rm.reserveStream(protocolID: "/special/1.0", peer: peer, direction: .inbound)
        #expect(throws: ResourceError.self) {
            try rm.reserveStream(protocolID: "/special/1.0", peer: peer, direction: .inbound)
        }
    }

    @Test("Protocol scope returns current stats and limits")
    func testProtocolScope() throws {
        let rm = DefaultResourceManager(
            configuration: ResourceLimitsConfiguration(
                system: .unlimited,
                peer: .unlimited,
                protocolLimits: ScopeLimits(maxTotalStreams: 42)
            )
        )
        let peer = makePeer()
        try rm.reserveStream(protocolID: "/test/1.0", peer: peer, direction: .inbound)

        let scope = rm.protocolScope(for: "/test/1.0")
        #expect(scope.name == "protocol:/test/1.0")
        #expect(scope.stat.inboundStreams == 1)
        #expect(scope.limits.maxTotalStreams == 42)
    }

    // MARK: - Service Scope

    @Test("Service memory reserve and release")
    func testServiceMemoryReserveRelease() throws {
        let rm = makeManager(system: .unlimited, peer: .unlimited)

        try rm.reserveServiceMemory(1024, service: "dht")

        let snap = rm.snapshot()
        #expect(snap.system.memory == 1024)
        #expect(snap.services["dht"]?.memory == 1024)

        rm.releaseServiceMemory(1024, service: "dht")

        let snap2 = rm.snapshot()
        #expect(snap2.system.memory == 0)
        #expect(snap2.services["dht"] == nil)
    }

    @Test("Service memory limit enforced")
    func testServiceMemoryLimit() throws {
        let rm = DefaultResourceManager(
            configuration: ResourceLimitsConfiguration(
                system: .unlimited,
                peer: .unlimited,
                serviceLimits: ScopeLimits(maxMemory: 1000)
            )
        )

        try rm.reserveServiceMemory(800, service: "dht")

        #expect(throws: ResourceError.self) {
            try rm.reserveServiceMemory(300, service: "dht")
        }

        // Memory unchanged after failed reservation
        #expect(rm.snapshot().services["dht"]?.memory == 800)
    }

    @Test("Service cleanup removes zero-count entries")
    func testServiceCleanup() throws {
        let rm = makeManager(system: .unlimited, peer: .unlimited)

        try rm.reserveServiceMemory(512, service: "relay")
        #expect(rm.snapshot().services["relay"] != nil)

        rm.releaseServiceMemory(512, service: "relay")
        #expect(rm.snapshot().services["relay"] == nil)
    }

    @Test("Service scope returns current stats and limits")
    func testServiceScope() throws {
        let rm = DefaultResourceManager(
            configuration: ResourceLimitsConfiguration(
                system: .unlimited,
                peer: .unlimited,
                serviceLimits: ScopeLimits(maxMemory: 5000)
            )
        )
        try rm.reserveServiceMemory(100, service: "dht")

        let scope = rm.serviceScope(for: "dht")
        #expect(scope.name == "service:dht")
        #expect(scope.stat.memory == 100)
        #expect(scope.limits.maxMemory == 5000)
    }

    @Test("Snapshot includes all scopes")
    func testSnapshotAllScopes() throws {
        let rm = makeManager(system: .unlimited, peer: .unlimited)
        let peer = makePeer()

        try rm.reserveInboundConnection(from: peer)
        try rm.reserveStream(protocolID: "/test/1.0", peer: peer, direction: .inbound)
        try rm.reserveServiceMemory(256, service: "relay")

        let snap = rm.snapshot()
        #expect(snap.system.inboundConnections == 1)
        #expect(snap.system.inboundStreams == 1)
        #expect(snap.system.memory == 256)
        #expect(snap.peers[peer] != nil)
        #expect(snap.protocols["/test/1.0"]?.inboundStreams == 1)
        #expect(snap.services["relay"]?.memory == 256)
    }

    // MARK: - ResourceLimitsConfiguration

    @Test("ResourceLimitsConfiguration effective peer limits")
    func testEffectivePeerLimits() {
        let specialPeer = makePeer()
        let normalPeer = makePeer()

        let config = ResourceLimitsConfiguration(
            peer: ScopeLimits(maxInboundConnections: 2),
            peerOverrides: [specialPeer: ScopeLimits(maxInboundConnections: 10)]
        )

        let normalLimits = config.effectivePeerLimits(for: normalPeer)
        #expect(normalLimits.maxInboundConnections == 2)

        let specialLimits = config.effectivePeerLimits(for: specialPeer)
        #expect(specialLimits.maxInboundConnections == 10)
    }
}

// MARK: - Mock MuxedStream

private final class MockMuxedStream: MuxedStream, Sendable {
    let id: UInt64 = 42
    let protocolID: String? = nil

    private struct State: Sendable {
        var readBuffer: [ByteBuffer] = []
        var writtenData: [ByteBuffer] = []
        var closeCalled = false
        var resetCalled = false
        var closeWriteCalled = false
        var closeReadCalled = false
    }

    private let _state: Mutex<State>

    init() {
        self._state = Mutex(State())
    }

    var writtenData: [ByteBuffer] { _state.withLock { $0.writtenData } }
    var closeCalled: Bool { _state.withLock { $0.closeCalled } }
    var resetCalled: Bool { _state.withLock { $0.resetCalled } }
    var closeWriteCalled: Bool { _state.withLock { $0.closeWriteCalled } }
    var closeReadCalled: Bool { _state.withLock { $0.closeReadCalled } }

    func setReadBuffer(_ data: [ByteBuffer]) {
        _state.withLock { $0.readBuffer = data }
    }

    func read() async throws -> ByteBuffer {
        let data = _state.withLock { s -> ByteBuffer? in
            guard !s.readBuffer.isEmpty else { return nil }
            return s.readBuffer.removeFirst()
        }
        guard let data else {
            throw NodeError.streamClosed
        }
        return data
    }

    func write(_ data: ByteBuffer) async throws {
        _state.withLock { $0.writtenData.append(data) }
    }

    func closeWrite() async throws {
        _state.withLock { $0.closeWriteCalled = true }
    }

    func closeRead() async throws {
        _state.withLock { $0.closeReadCalled = true }
    }

    func close() async throws {
        _state.withLock { $0.closeCalled = true }
    }

    func reset() async throws {
        _state.withLock { $0.resetCalled = true }
    }
}
