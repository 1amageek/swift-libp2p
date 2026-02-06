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
        maxPerPeer: Int = 2
    ) -> ConnectionPool {
        let limits = ConnectionLimits(
            highWatermark: highWatermark,
            lowWatermark: lowWatermark,
            maxConnectionsPerPeer: maxPerPeer,
            maxInbound: maxInbound,
            maxOutbound: maxOutbound
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
}
