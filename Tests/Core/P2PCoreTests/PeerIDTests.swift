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

    // MARK: - Ed25519 Tests

    @Test("Generate Ed25519 key pair")
    func generateEd25519() {
        let keyPair = KeyPair.generateEd25519()

        #expect(keyPair.keyType == .ed25519)
        #expect(keyPair.publicKey.rawBytes.count == 32)
    }

    @Test("Sign and verify Ed25519")
    func signAndVerifyEd25519() throws {
        let keyPair = KeyPair.generateEd25519()
        let message = Data("Hello, libp2p!".utf8)

        let signature = try keyPair.sign(message)
        let isValid = try keyPair.verify(signature: signature, for: message)

        #expect(isValid)
    }

    @Test("Invalid signature fails verification Ed25519")
    func invalidSignatureFailsEd25519() throws {
        let keyPair = KeyPair.generateEd25519()
        let message = Data("Hello, libp2p!".utf8)

        let signature = try keyPair.sign(message)
        let tamperedSignature = signature + Data([0x00])

        let isValid = try? keyPair.verify(signature: tamperedSignature, for: message)
        #expect(isValid == false || isValid == nil)
    }

    @Test("Wrong message fails verification Ed25519")
    func wrongMessageFailsEd25519() throws {
        let keyPair = KeyPair.generateEd25519()
        let message = Data("Hello, libp2p!".utf8)
        let wrongMessage = Data("Wrong message".utf8)

        let signature = try keyPair.sign(message)
        let isValid = try keyPair.verify(signature: signature, for: wrongMessage)

        #expect(!isValid)
    }

    // MARK: - ECDSA P-256 Tests

    @Test("Generate ECDSA P-256 key pair")
    func generateECDSA() {
        let keyPair = KeyPair.generateECDSA()

        #expect(keyPair.keyType == .ecdsa)
        // P-256 public key in X9.63 uncompressed format is 65 bytes
        #expect(keyPair.publicKey.rawBytes.count == 65)
    }

    @Test("Sign and verify ECDSA P-256")
    func signAndVerifyECDSA() throws {
        let keyPair = KeyPair.generateECDSA()
        let message = Data("Hello, libp2p with ECDSA!".utf8)

        let signature = try keyPair.sign(message)
        let isValid = try keyPair.verify(signature: signature, for: message)

        #expect(isValid)
    }

    @Test("Invalid signature fails verification ECDSA")
    func invalidSignatureFailsECDSA() throws {
        let keyPair = KeyPair.generateECDSA()
        let message = Data("Hello, libp2p with ECDSA!".utf8)

        let signature = try keyPair.sign(message)
        // Tamper with the signature
        var tamperedSignature = signature
        if !tamperedSignature.isEmpty {
            tamperedSignature[tamperedSignature.count - 1] ^= 0xFF
        }

        let isValid = try? keyPair.verify(signature: tamperedSignature, for: message)
        #expect(isValid == false || isValid == nil)
    }

    @Test("Wrong message fails verification ECDSA")
    func wrongMessageFailsECDSA() throws {
        let keyPair = KeyPair.generateECDSA()
        let message = Data("Hello, libp2p with ECDSA!".utf8)
        let wrongMessage = Data("Wrong message".utf8)

        let signature = try keyPair.sign(message)
        let isValid = try keyPair.verify(signature: signature, for: wrongMessage)

        #expect(!isValid)
    }

    @Test("ECDSA PeerID generation")
    func ecdsaPeerID() throws {
        let keyPair = KeyPair.generateECDSA()
        let peerID = keyPair.peerID

        // PeerID should be non-empty
        #expect(!peerID.bytes.isEmpty)

        // ECDSA keys are larger, so should use SHA256 multihash
        #expect(peerID.multihash.code == .sha2_256)
    }

    @Test("ECDSA PeerID roundtrip")
    func ecdsaPeerIDRoundtrip() throws {
        let keyPair = KeyPair.generateECDSA()
        let peerID = keyPair.peerID

        let string = peerID.description
        let restored = try PeerID(string: string)

        #expect(peerID == restored)
    }

    @Test("ECDSA private key raw bytes roundtrip")
    func ecdsaPrivateKeyRoundtrip() throws {
        let original = KeyPair.generateECDSA()
        let rawBytes = original.privateKey.rawBytes

        let restored = try KeyPair(keyType: .ecdsa, rawBytes: rawBytes)

        // Public keys should match
        #expect(restored.publicKey.rawBytes == original.publicKey.rawBytes)

        // Should be able to sign with restored key
        let message = Data("Test message".utf8)
        let signature = try restored.sign(message)
        let isValid = try original.verify(signature: signature, for: message)
        #expect(isValid)
    }

    // MARK: - Comparable Tests

    @Test("PeerID Comparable is deterministic")
    func peerIDComparable() {
        let a = PeerID(publicKey: KeyPair.generateEd25519().publicKey)
        let b = PeerID(publicKey: KeyPair.generateEd25519().publicKey)

        // Exactly one of <, ==, > must hold
        let lt = a < b
        let gt = b < a
        let eq = a == b
        #expect((lt && !gt && !eq) || (!lt && gt && !eq) || (!lt && !gt && eq))

        // Consistent with itself
        #expect(!(a < a))
        #expect(a == a)
    }

    @Test("PeerID Comparable is consistent with bytes")
    func peerIDComparableConsistentWithBytes() {
        let a = PeerID(publicKey: KeyPair.generateEd25519().publicKey)
        let b = PeerID(publicKey: KeyPair.generateEd25519().publicKey)

        let bytesLt = a.bytes.lexicographicallyPrecedes(b.bytes)
        #expect((a < b) == bytesLt)
    }

    @Test("PeerID Comparable is transitive")
    func peerIDComparableTransitive() {
        var peers = (0..<5).map { _ in
            PeerID(publicKey: KeyPair.generateEd25519().publicKey)
        }
        peers.sort()

        // Sorted order should be consistent
        for i in 0..<peers.count - 1 {
            #expect(peers[i] <= peers[i + 1])
        }
    }
}
