/// SKademliaTests - Tests for S/Kademlia security features
///
/// S/Kademlia extends Kademlia with security enhancements:
/// - Cryptographic node ID validation
/// - Sibling broadcast for redundancy
/// - Disjoint paths for query robustness

import Testing
import Foundation
@testable import P2PKademlia
@testable import P2PCore

@Suite("S/Kademlia Security Tests")
struct SKademliaTests {

    // MARK: - Configuration Tests

    @Test("S/Kademlia standard configuration has security features enabled")
    func standardConfigurationEnabled() {
        let config = SKademliaConfig.standard

        #expect(config.enabled == true)
        #expect(config.validateNodeIDs == true)
        #expect(config.useSiblingBroadcast == true)
        #expect(config.useDisjointPaths == true)
    }

    @Test("S/Kademlia disabled configuration has security features disabled")
    func disabledConfiguration() {
        let config = SKademliaConfig.disabled

        #expect(config.enabled == false)
        #expect(config.validateNodeIDs == false)
        #expect(config.useSiblingBroadcast == false)
        #expect(config.useDisjointPaths == false)
    }

    @Test("Custom S/Kademlia configuration")
    func customConfiguration() {
        let config = SKademliaConfig(
            enabled: true,
            validateNodeIDs: true,
            useSiblingBroadcast: true,
            siblingCount: 3,
            useDisjointPaths: false,
            disjointPathCount: 2
        )

        #expect(config.enabled == true)
        #expect(config.validateNodeIDs == true)
        #expect(config.useSiblingBroadcast == true)
        #expect(config.siblingCount == 3)
        #expect(config.useDisjointPaths == false)
    }

    @Test("Sibling count is at least 1")
    func siblingCountMinimum() {
        let config = SKademliaConfig(
            enabled: true,
            siblingCount: 0
        )

        #expect(config.siblingCount >= 1)
    }

    @Test("Disjoint path count is at least 2")
    func disjointPathCountMinimum() {
        let config = SKademliaConfig(
            enabled: true,
            disjointPathCount: 1
        )

        #expect(config.disjointPathCount >= 2)
    }

    // MARK: - Node ID Validation Tests

    @Test("Valid node ID derived from public key")
    func validNodeIDFromPublicKey() throws {
        let keyPair = KeyPair.generateEd25519()
        let peerID = keyPair.peerID
        let publicKey = keyPair.publicKey

        let isValid = SKademliaValidator.validateNodeID(peerID, publicKey: publicKey)
        #expect(isValid == true)
    }

    @Test("Invalid node ID does not match public key")
    func invalidNodeIDMismatch() throws {
        let keyPair1 = KeyPair.generateEd25519()
        let keyPair2 = KeyPair.generateEd25519()

        // PeerID from keyPair1, but public key from keyPair2
        let peerID = keyPair1.peerID
        let publicKey = keyPair2.publicKey

        let isValid = SKademliaValidator.validateNodeID(peerID, publicKey: publicKey)
        #expect(isValid == false)
    }

    @Test("Secure node ID check")
    func secureNodeIDCheck() throws {
        let keyPair = KeyPair.generateEd25519()
        let peerID = keyPair.peerID

        // All libp2p peer IDs derived from keys should be considered secure
        let isSecure = SKademliaValidator.isSecureNodeID(peerID)
        #expect(isSecure == true)
    }

    // MARK: - Kademlia Configuration Integration Tests

    @Test("Kademlia default configuration disables S/Kademlia")
    func kademliaDefaultConfiguration() {
        let config = KademliaConfiguration.default

        #expect(config.skademlia.enabled == false)
    }

    @Test("Kademlia secure configuration enables S/Kademlia")
    func kademliaSecureConfiguration() {
        let config = KademliaConfiguration.secure

        #expect(config.skademlia.enabled == true)
        #expect(config.skademlia.validateNodeIDs == true)
        #expect(config.skademlia.useSiblingBroadcast == true)
        #expect(config.skademlia.useDisjointPaths == true)
    }

    @Test("Kademlia custom S/Kademlia configuration")
    func kademliaCustomSKademliaConfiguration() {
        let skademlia = SKademliaConfig(
            enabled: true,
            validateNodeIDs: false,
            useSiblingBroadcast: true
        )
        let config = KademliaConfiguration(skademlia: skademlia)

        #expect(config.skademlia.enabled == true)
        #expect(config.skademlia.validateNodeIDs == false)
        #expect(config.skademlia.useSiblingBroadcast == true)
    }
}
