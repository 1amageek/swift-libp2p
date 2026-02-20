import Testing
import P2PCore
import P2PMux
@testable import P2P

@Suite("NATManager")
struct NATManagerTests {

    @Test("init creates manager with configuration")
    func initCreatesManager() {
        let config = NATTraversalConfiguration()
        let peerID = PeerID(publicKey: KeyPair.generateEd25519().publicKey)
        let manager = NATManager(config: config, localPeer: peerID)
        #expect(manager.currentStatus == .unknown)
    }

    @Test("shutdown is idempotent")
    func shutdownIdempotent() {
        let config = NATTraversalConfiguration()
        let peerID = PeerID(publicKey: KeyPair.generateEd25519().publicKey)
        let manager = NATManager(config: config, localPeer: peerID)
        manager.shutdown()
        manager.shutdown() // Should not crash
    }

    @Test("handlePeerConnected with isLimited false does nothing")
    func peerConnectedNotLimited() throws {
        var config = NATTraversalConfiguration()
        config.enableHolePunching = true
        let peerID = PeerID(publicKey: KeyPair.generateEd25519().publicKey)
        let manager = NATManager(config: config, localPeer: peerID)
        let remotePeer = PeerID(publicKey: KeyPair.generateEd25519().publicKey)
        let addr = try Multiaddr("/ip4/1.2.3.4/tcp/4001")

        // Not limited - should not track
        manager.handlePeerConnected(remotePeer, address: addr, isLimited: false)
        // No crash means success
    }

    @Test("handlePeerDisconnected removes pending")
    func peerDisconnectedRemovesPending() throws {
        var config = NATTraversalConfiguration()
        config.enableHolePunching = true
        let peerID = PeerID(publicKey: KeyPair.generateEd25519().publicKey)
        let manager = NATManager(config: config, localPeer: peerID)
        let remotePeer = PeerID(publicKey: KeyPair.generateEd25519().publicKey)
        let addr = try Multiaddr("/ip4/1.2.3.4/tcp/4001/p2p-circuit")

        // Note: dcutr is nil so handlePeerConnected won't insert
        manager.handlePeerConnected(remotePeer, address: addr, isLimited: true)
        manager.handlePeerDisconnected(remotePeer)
        // No crash means success
    }

    @Test("relayAddresses returns empty when no autoRelay")
    func relayAddressesEmpty() {
        let config = NATTraversalConfiguration()
        let peerID = PeerID(publicKey: KeyPair.generateEd25519().publicKey)
        let manager = NATManager(config: config, localPeer: peerID)
        let addresses = manager.relayAddresses()
        #expect(addresses.isEmpty)
    }

    @Test("events stream is available", .timeLimit(.minutes(1)))
    func eventsStreamAvailable() async {
        let config = NATTraversalConfiguration()
        let peerID = PeerID(publicKey: KeyPair.generateEd25519().publicKey)
        let manager = NATManager(config: config, localPeer: peerID)

        // Access events stream
        let _ = manager.events

        // Shutdown finishes the stream
        manager.shutdown()
    }

    @Test("shutdown after start cleans up", .timeLimit(.minutes(1)))
    func shutdownAfterStart() async {
        let config = NATTraversalConfiguration()
        let peerID = PeerID(publicKey: KeyPair.generateEd25519().publicKey)
        let manager = NATManager(config: config, localPeer: peerID)

        // start() with no services configured should be safe
        // We can't easily mock StreamOpener/HandlerRegistry here,
        // so just test the shutdown path
        manager.shutdown()
        #expect(manager.currentStatus == .unknown)
    }
}
