/// ConnectionPoolTests - Tests for ConnectionPool

import Testing
import Foundation
import P2PCore
import P2PMux
@testable import P2P

private func randomPeerID() -> PeerID {
    PeerID(publicKey: KeyPair.generateEd25519().publicKey)
}

/// Mock MuxedConnection for testing.
private final class MockMuxedConnection: MuxedConnection, @unchecked Sendable {
    let localPeer: PeerID
    let remotePeer: PeerID
    let localAddress: Multiaddr?
    let remoteAddress: Multiaddr

    var inboundStreams: AsyncStream<MuxedStream> {
        AsyncStream { $0.finish() }
    }

    init(localPeer: PeerID, remotePeer: PeerID, address: Multiaddr) {
        self.localPeer = localPeer
        self.remotePeer = remotePeer
        self.localAddress = nil
        self.remoteAddress = address
    }

    func newStream() async throws -> MuxedStream {
        throw MockConnectionError.notSupported
    }

    func acceptStream() async throws -> MuxedStream {
        throw MockConnectionError.notSupported
    }

    func close() async throws {}
}

private enum MockConnectionError: Error {
    case notSupported
}

@Suite("ConnectionPool Tests")
struct ConnectionPoolTests {

    private func makePool(
        highWatermark: Int = 100,
        lowWatermark: Int = 80,
        maxInbound: Int? = nil,
        maxOutbound: Int? = nil,
        maxPerPeer: Int = 2,
        gracePeriod: Duration = .seconds(30)
    ) -> ConnectionPool {
        let limits = ConnectionLimits(
            highWatermark: highWatermark,
            lowWatermark: lowWatermark,
            maxConnectionsPerPeer: maxPerPeer,
            maxInbound: maxInbound,
            maxOutbound: maxOutbound,
            gracePeriod: gracePeriod
        )
        return ConnectionPool(configuration: PoolConfiguration(limits: limits))
    }

    private func makeMockConnection(remotePeer: PeerID? = nil) -> (PeerID, Multiaddr, MockMuxedConnection) {
        let local = randomPeerID()
        let remote = remotePeer ?? randomPeerID()
        let addr = try! Multiaddr("/ip4/127.0.0.1/tcp/4001")
        let conn = MockMuxedConnection(localPeer: local, remotePeer: remote, address: addr)
        return (remote, addr, conn)
    }

    // MARK: - Adding Connections

    @Test("addConnecting creates entry in connecting state")
    func addConnecting() {
        let pool = makePool()
        let peer = randomPeerID()
        let addr = try! Multiaddr("/ip4/127.0.0.1/tcp/4001")

        let id = pool.addConnecting(for: peer, address: addr, direction: .outbound)

        let managed = pool.managedConnection(id)
        #expect(managed != nil)
        if case .connecting = managed?.state {} else {
            Issue.record("Expected connecting state")
        }
        #expect(managed?.connection == nil)
        #expect(pool.totalEntryCount == 1)
    }

    @Test("add creates connected entry with connection")
    func addConnection() {
        let pool = makePool()
        let (remote, addr, conn) = makeMockConnection()

        let id = pool.add(conn, for: remote, address: addr, direction: .inbound)

        let managed = pool.managedConnection(id)
        #expect(managed != nil)
        #expect(managed?.state.isConnected == true)
        #expect(managed?.connection != nil)
        #expect(pool.connectionCount == 1)
        #expect(pool.isConnected(to: remote) == true)
    }

    // MARK: - Removing Connections

    @Test("remove deletes connection from pool")
    func removeConnection() {
        let pool = makePool()
        let (remote, addr, conn) = makeMockConnection()

        let id = pool.add(conn, for: remote, address: addr, direction: .outbound)
        #expect(pool.connectionCount == 1)

        let removed = pool.remove(id)
        #expect(removed != nil)
        #expect(pool.connectionCount == 0)
        #expect(pool.isConnected(to: remote) == false)
    }

    @Test("remove(forPeer:) removes all connections for peer")
    func removeForPeer() {
        let pool = makePool()
        let peer = randomPeerID()
        let addr = try! Multiaddr("/ip4/127.0.0.1/tcp/4001")
        let local = randomPeerID()

        let conn1 = MockMuxedConnection(localPeer: local, remotePeer: peer, address: addr)
        let conn2 = MockMuxedConnection(localPeer: local, remotePeer: peer, address: addr)

        pool.add(conn1, for: peer, address: addr, direction: .outbound)
        pool.add(conn2, for: peer, address: addr, direction: .inbound)
        #expect(pool.connectionCount == 2)

        let removed = pool.remove(forPeer: peer)
        #expect(removed.count == 2)
        #expect(pool.connectionCount == 0)
    }

    // MARK: - Query

    @Test("connection(to:) returns active connection")
    func connectionForPeer() {
        let pool = makePool()
        let (remote, addr, conn) = makeMockConnection()

        pool.add(conn, for: remote, address: addr, direction: .outbound)

        let retrieved = pool.connection(to: remote)
        #expect(retrieved != nil)
    }

    @Test("connection(to:) returns nil for unknown peer")
    func connectionForUnknownPeer() {
        let pool = makePool()

        let result = pool.connection(to: randomPeerID())
        #expect(result == nil)
    }

    @Test("connectedPeers returns all connected peers")
    func connectedPeers() {
        let pool = makePool()
        let (peer1, addr1, conn1) = makeMockConnection()
        let (peer2, addr2, conn2) = makeMockConnection()

        pool.add(conn1, for: peer1, address: addr1, direction: .outbound)
        pool.add(conn2, for: peer2, address: addr2, direction: .inbound)

        let peers = pool.connectedPeers
        #expect(peers.count == 2)
        #expect(Set(peers).contains(peer1))
        #expect(Set(peers).contains(peer2))
    }

    @Test("connectionCount only counts connected entries")
    func connectionCount() {
        let pool = makePool()
        let peer1 = randomPeerID()
        let addr = try! Multiaddr("/ip4/127.0.0.1/tcp/4001")
        let (peer2, addr2, conn2) = makeMockConnection()

        // Add one connecting (not counted) and one connected (counted)
        pool.addConnecting(for: peer1, address: addr, direction: .outbound)
        pool.add(conn2, for: peer2, address: addr2, direction: .inbound)

        #expect(pool.totalEntryCount == 2)
        #expect(pool.connectionCount == 1)
    }

    @Test("inboundCount and outboundCount track direction")
    func directionCounts() {
        let pool = makePool()
        let (peer1, addr1, conn1) = makeMockConnection()
        let (peer2, addr2, conn2) = makeMockConnection()
        let (peer3, addr3, conn3) = makeMockConnection()

        pool.add(conn1, for: peer1, address: addr1, direction: .inbound)
        pool.add(conn2, for: peer2, address: addr2, direction: .outbound)
        pool.add(conn3, for: peer3, address: addr3, direction: .inbound)

        #expect(pool.inboundCount == 2)
        #expect(pool.outboundCount == 1)
    }

    // MARK: - Pending Dials

    @Test("Pending dials prevent duplicate dials")
    func pendingDials() {
        let pool = makePool()
        let peer = randomPeerID()

        #expect(pool.hasPendingDial(to: peer) == false)

        let task = Task<PeerID, any Error> { peer }
        pool.registerPendingDial(task, for: peer)

        #expect(pool.hasPendingDial(to: peer) == true)
        #expect(pool.pendingDial(to: peer) != nil)

        pool.removePendingDial(for: peer)
        #expect(pool.hasPendingDial(to: peer) == false)
    }

    // MARK: - Tagging & Protection

    @Test("Tag connection adds tag")
    func tagConnection() {
        let pool = makePool()
        let (remote, addr, conn) = makeMockConnection()

        let id = pool.add(conn, for: remote, address: addr, direction: .outbound)
        pool.tag(remote, with: "relay")

        let managed = pool.managedConnection(id)
        #expect(managed?.tags.contains("relay") == true)
    }

    @Test("Protect connection sets protected flag")
    func protectConnection() {
        let pool = makePool()
        let (remote, addr, conn) = makeMockConnection()

        let id = pool.add(conn, for: remote, address: addr, direction: .outbound)
        pool.protect(remote)

        let managed = pool.managedConnection(id)
        #expect(managed?.isProtected == true)
    }

    @Test("Unprotect connection clears protected flag")
    func unprotectConnection() {
        let pool = makePool()
        let (remote, addr, conn) = makeMockConnection()

        let id = pool.add(conn, for: remote, address: addr, direction: .outbound)
        pool.protect(remote)
        pool.unprotect(remote)

        let managed = pool.managedConnection(id)
        #expect(managed?.isProtected == false)
    }

    // MARK: - Connection Limits

    @Test("canAcceptInbound respects limit")
    func connectionLimitsInbound() {
        let pool = makePool(maxInbound: 1)
        let (peer1, addr1, conn1) = makeMockConnection()

        #expect(pool.canAcceptInbound() == true)

        pool.add(conn1, for: peer1, address: addr1, direction: .inbound)
        #expect(pool.canAcceptInbound() == false)
    }

    @Test("canDialOutbound respects limit")
    func connectionLimitsOutbound() {
        let pool = makePool(maxOutbound: 1)
        let (peer1, addr1, conn1) = makeMockConnection()

        #expect(pool.canDialOutbound() == true)

        pool.add(conn1, for: peer1, address: addr1, direction: .outbound)
        #expect(pool.canDialOutbound() == false)
    }

    @Test("canConnectTo respects per-peer limit")
    func connectionLimitsPerPeer() {
        let pool = makePool(maxPerPeer: 1)
        let peer = randomPeerID()
        let addr = try! Multiaddr("/ip4/127.0.0.1/tcp/4001")
        let conn = MockMuxedConnection(localPeer: randomPeerID(), remotePeer: peer, address: addr)

        #expect(pool.canConnectTo(peer: peer) == true)

        pool.add(conn, for: peer, address: addr, direction: .outbound)
        #expect(pool.canConnectTo(peer: peer) == false)
    }

    // MARK: - Auto-Reconnect

    @Test("Auto-reconnect address management")
    func autoReconnect() {
        let pool = makePool()
        let peer = randomPeerID()
        let addr = try! Multiaddr("/ip4/127.0.0.1/tcp/4001")

        #expect(pool.reconnectAddress(for: peer) == nil)

        pool.enableAutoReconnect(for: peer, address: addr)
        #expect(pool.reconnectAddress(for: peer) != nil)

        pool.disableAutoReconnect(for: peer)
        #expect(pool.reconnectAddress(for: peer) == nil)
    }

    // MARK: - Retry Count

    @Test("Retry count increment and reset")
    func retryCount() {
        let pool = makePool()
        let (remote, addr, conn) = makeMockConnection()

        let id = pool.add(conn, for: remote, address: addr, direction: .outbound)

        let managed0 = pool.managedConnection(id)
        #expect(managed0?.retryCount == 0)

        let count1 = pool.incrementRetryCount(id)
        #expect(count1 == 1)

        let count2 = pool.incrementRetryCount(id)
        #expect(count2 == 2)

        pool.resetRetryCount(id)
        let managed = pool.managedConnection(id)
        #expect(managed?.retryCount == 0)
    }

    // MARK: - Trimming

    @Test("trimIfNeeded reduces active connections toward low watermark")
    func trimReducesToLowWatermark() {
        let pool = makePool(highWatermark: 3, lowWatermark: 2, gracePeriod: .zero)

        for _ in 0..<4 {
            let (peer, addr, conn) = makeMockConnection()
            pool.add(conn, for: peer, address: addr, direction: .outbound)
        }

        #expect(pool.connectionCount == 4)
        let trimmed = pool.trimIfNeeded()

        #expect(trimmed.count == 2)
        #expect(pool.connectionCount == 2)
    }

    @Test("trimIfNeeded never trims protected connections")
    func trimRespectsProtection() {
        let pool = makePool(highWatermark: 2, lowWatermark: 1, gracePeriod: .zero)

        let (protectedPeer, protectedAddr, protectedConn) = makeMockConnection()
        pool.add(protectedConn, for: protectedPeer, address: protectedAddr, direction: .outbound)
        pool.protect(protectedPeer)

        var otherPeers: [PeerID] = []
        for _ in 0..<2 {
            let (peer, addr, conn) = makeMockConnection()
            otherPeers.append(peer)
            pool.add(conn, for: peer, address: addr, direction: .outbound)
        }

        let trimmed = pool.trimIfNeeded()

        #expect(trimmed.count == 2)
        #expect(pool.isConnected(to: protectedPeer))
        for peer in otherPeers {
            #expect(!pool.isConnected(to: peer))
        }
    }

    @Test("trimIfNeeded trims fewer tags first")
    func trimPrefersFewerTags() {
        let pool = makePool(highWatermark: 2, lowWatermark: 1, gracePeriod: .zero)

        let (peerNoTag, addrNoTag, connNoTag) = makeMockConnection()
        pool.add(connNoTag, for: peerNoTag, address: addrNoTag, direction: .outbound)

        let (peerOneTag, addrOneTag, connOneTag) = makeMockConnection()
        pool.add(connOneTag, for: peerOneTag, address: addrOneTag, direction: .outbound)
        pool.tag(peerOneTag, with: "relay")

        let (peerTwoTags, addrTwoTags, connTwoTags) = makeMockConnection()
        pool.add(connTwoTags, for: peerTwoTags, address: addrTwoTags, direction: .outbound)
        pool.tag(peerTwoTags, with: "relay")
        pool.tag(peerTwoTags, with: "bootstrap")

        let trimmed = pool.trimIfNeeded()
        let trimmedPeers = Set(trimmed.map(\.peer))

        #expect(trimmedPeers.contains(peerNoTag))
        #expect(trimmedPeers.contains(peerOneTag))
        #expect(!trimmedPeers.contains(peerTwoTags))
        #expect(pool.isConnected(to: peerTwoTags))
    }

    @Test("trimIfNeeded trims oldest activity first when tags are equal")
    func trimPrefersOlderActivity() async {
        let pool = makePool(highWatermark: 2, lowWatermark: 2, gracePeriod: .zero)

        let (oldPeer, oldAddr, oldConn) = makeMockConnection()
        pool.add(oldConn, for: oldPeer, address: oldAddr, direction: .outbound)
        do {
            try await Task.sleep(for: .milliseconds(5))
        } catch {
            Issue.record("Unexpected cancellation during trim test sleep #1: \(error)")
        }

        let (midPeer, midAddr, midConn) = makeMockConnection()
        pool.add(midConn, for: midPeer, address: midAddr, direction: .outbound)
        do {
            try await Task.sleep(for: .milliseconds(5))
        } catch {
            Issue.record("Unexpected cancellation during trim test sleep #2: \(error)")
        }

        let (newPeer, newAddr, newConn) = makeMockConnection()
        pool.add(newConn, for: newPeer, address: newAddr, direction: .outbound)

        let trimmed = pool.trimIfNeeded()

        #expect(trimmed.count == 1)
        #expect(trimmed.first?.peer == oldPeer)
        #expect(!pool.isConnected(to: oldPeer))
        #expect(pool.isConnected(to: midPeer))
        #expect(pool.isConnected(to: newPeer))
    }

    @Test("trimIfNeeded does not trim connections within grace period")
    func trimRespectsGracePeriod() {
        let pool = makePool(highWatermark: 1, lowWatermark: 0, gracePeriod: .seconds(60))

        let (peer1, addr1, conn1) = makeMockConnection()
        pool.add(conn1, for: peer1, address: addr1, direction: .outbound)

        let (peer2, addr2, conn2) = makeMockConnection()
        pool.add(conn2, for: peer2, address: addr2, direction: .outbound)

        let trimmed = pool.trimIfNeeded()

        #expect(trimmed.isEmpty)
        #expect(pool.connectionCount == 2)
    }

    // MARK: - Trim Inspection

    @Test("trimReport includes selection and exclusion reasons")
    func trimReportIncludesSelectionAndExclusions() {
        let pool = makePool(highWatermark: 2, lowWatermark: 1, gracePeriod: .seconds(60))

        let (protectedPeer, protectedAddr, protectedConn) = makeMockConnection()
        pool.add(protectedConn, for: protectedPeer, address: protectedAddr, direction: .outbound)
        pool.protect(protectedPeer)

        let (candidatePeer1, candidateAddr1, candidateConn1) = makeMockConnection()
        pool.add(candidateConn1, for: candidatePeer1, address: candidateAddr1, direction: .outbound)

        let (candidatePeer2, candidateAddr2, candidateConn2) = makeMockConnection()
        pool.add(candidateConn2, for: candidatePeer2, address: candidateAddr2, direction: .outbound)

        let connectingPeer = randomPeerID()
        let connectingAddr = try! Multiaddr("/ip4/127.0.0.1/tcp/4010")
        _ = pool.addConnecting(for: connectingPeer, address: connectingAddr, direction: .outbound)

        let report = pool.trimReport()
        #expect(report.activeConnectionCount == 3)
        #expect(report.totalEntryCount == 4)
        #expect(report.targetTrimCount == 2)
        #expect(report.trimmableCount == 0)
        #expect(report.selectedCount == 0)
        #expect(report.requiresTrim)

        let byPeer = Dictionary(uniqueKeysWithValues: report.candidates.map { ($0.peer, $0) })
        #expect(byPeer[protectedPeer]?.exclusionReason == .protected)
        #expect(byPeer[candidatePeer1]?.exclusionReason == .withinGracePeriod)
        #expect(byPeer[candidatePeer2]?.exclusionReason == .withinGracePeriod)
        #expect(byPeer[connectingPeer]?.exclusionReason == .notConnected)
    }

    @Test("trimReport selection matches trimIfNeeded result")
    func trimReportMatchesTrimExecution() async {
        let pool = makePool(highWatermark: 2, lowWatermark: 2, gracePeriod: .zero)

        let (oldPeer, oldAddr, oldConn) = makeMockConnection()
        pool.add(oldConn, for: oldPeer, address: oldAddr, direction: .outbound)
        do {
            try await Task.sleep(for: .milliseconds(5))
        } catch {
            Issue.record("Unexpected cancellation during trim report test sleep #1: \(error)")
        }

        let (newerPeer, newerAddr, newerConn) = makeMockConnection()
        pool.add(newerConn, for: newerPeer, address: newerAddr, direction: .outbound)
        do {
            try await Task.sleep(for: .milliseconds(5))
        } catch {
            Issue.record("Unexpected cancellation during trim report test sleep #2: \(error)")
        }

        let (newestPeer, newestAddr, newestConn) = makeMockConnection()
        pool.add(newestConn, for: newestPeer, address: newestAddr, direction: .outbound)

        let report = pool.trimReport()
        #expect(report.requiresTrim)
        #expect(report.targetTrimCount == 1)

        let planned = report.candidates.filter(\.selectedForTrim)
        #expect(planned.count == 1)
        #expect(planned.first?.peer == oldPeer)
        #expect(planned.first?.trimRank == 1)

        let trimmed = pool.trimIfNeeded()
        #expect(trimmed.count == 1)
        #expect(trimmed.first?.peer == oldPeer)
    }

    // MARK: - connectedManagedConnections

    @Test("connectedManagedConnections returns only connected entries")
    func connectedManagedConnectionsFiltering() {
        let pool = makePool(maxPerPeer: 3)
        let (remotePeer, addr, conn1) = makeMockConnection()

        // Add two connections: one connected, one connecting
        pool.add(conn1, for: remotePeer, address: addr, direction: .inbound)
        let connectingID = pool.addConnecting(for: remotePeer, address: addr, direction: .outbound)

        let connected = pool.connectedManagedConnections(for: remotePeer)
        #expect(connected.count == 1)
        #expect(connected.first?.direction == .inbound)

        // Transition connecting to connected
        let conn2 = MockMuxedConnection(
            localPeer: randomPeerID(),
            remotePeer: remotePeer,
            address: addr
        )
        pool.updateConnection(connectingID, connection: conn2)

        let connectedAfter = pool.connectedManagedConnections(for: remotePeer)
        #expect(connectedAfter.count == 2)
    }

    @Test("connectedManagedConnections returns empty for unknown peer")
    func connectedManagedConnectionsUnknownPeer() {
        let pool = makePool()
        let unknown = randomPeerID()
        #expect(pool.connectedManagedConnections(for: unknown).isEmpty)
    }
}
