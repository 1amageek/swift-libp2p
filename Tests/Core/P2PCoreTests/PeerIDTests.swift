import Testing
import Foundation
@testable import P2PCore

@Suite("PeerID Tests")
struct PeerIDTests {

    @Test("Generate Ed25519 PeerID")
    func generateEd25519PeerID() throws {
        let keyPair = KeyPair.generateEd25519()
        let peerID = keyPair.peerID

        // PeerID should be non-empty
        #expect(!peerID.bytes.isEmpty)

        // Should use identity multihash for Ed25519
        #expect(peerID.multihash.code == .identity)

        // Should be able to extract public key
        let extractedKey = try peerID.extractPublicKey()
        #expect(extractedKey != nil)
        #expect(extractedKey?.keyType == .ed25519)
    }

    @Test("PeerID from string roundtrip")
    func peerIDStringRoundtrip() throws {
        let keyPair = KeyPair.generateEd25519()
        let peerID = keyPair.peerID

        let string = peerID.description
        let restored = try PeerID(string: string)

        #expect(peerID == restored)
    }

    @Test("PeerID from bytes roundtrip")
    func peerIDBytesRoundtrip() throws {
        let keyPair = KeyPair.generateEd25519()
        let peerID = keyPair.peerID

        let bytes = peerID.bytes
        let restored = try PeerID(bytes: bytes)

        #expect(peerID == restored)
    }

    @Test("PeerID matches public key")
    func peerIDMatchesPublicKey() {
        let keyPair = KeyPair.generateEd25519()
        let peerID = keyPair.peerID

        #expect(peerID.matches(publicKey: keyPair.publicKey))
    }

    @Test("Different keys produce different PeerIDs")
    func differentKeysDifferentPeerIDs() {
        let keyPair1 = KeyPair.generateEd25519()
        let keyPair2 = KeyPair.generateEd25519()

        #expect(keyPair1.peerID != keyPair2.peerID)
    }
}

@Suite("KeyPair Tests")
struct KeyPairTests {

    @Test("Generate Ed25519 key pair")
    func generateEd25519() {
        let keyPair = KeyPair.generateEd25519()

        #expect(keyPair.keyType == .ed25519)
        #expect(keyPair.publicKey.rawBytes.count == 32)
    }

    @Test("Sign and verify")
    func signAndVerify() throws {
        let keyPair = KeyPair.generateEd25519()
        let message = Data("Hello, libp2p!".utf8)

        let signature = try keyPair.sign(message)
        let isValid = try keyPair.verify(signature: signature, for: message)

        #expect(isValid)
    }

    @Test("Invalid signature fails verification")
    func invalidSignatureFails() throws {
        let keyPair = KeyPair.generateEd25519()
        let message = Data("Hello, libp2p!".utf8)

        let signature = try keyPair.sign(message)
        let tamperedSignature = signature + Data([0x00])

        let isValid = try? keyPair.verify(signature: tamperedSignature, for: message)
        #expect(isValid == false || isValid == nil)
    }

    @Test("Wrong message fails verification")
    func wrongMessageFails() throws {
        let keyPair = KeyPair.generateEd25519()
        let message = Data("Hello, libp2p!".utf8)
        let wrongMessage = Data("Wrong message".utf8)

        let signature = try keyPair.sign(message)
        let isValid = try keyPair.verify(signature: signature, for: wrongMessage)

        #expect(!isValid)
    }
}
