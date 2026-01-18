/// NoiseHandshakeTests - Unit tests for Noise XX handshake pattern
import Testing
import Foundation
import Crypto
@testable import P2PSecurityNoise
@testable import P2PCore

@Suite("NoiseHandshake Tests")
struct NoiseHandshakeTests {

    // MARK: - Full Handshake Tests

    @Test("Full XX handshake completes successfully")
    func testFullHandshakeXX() throws {
        let initiatorKeyPair = KeyPair.generateEd25519()
        let responderKeyPair = KeyPair.generateEd25519()

        let initiator = NoiseHandshake(localKeyPair: initiatorKeyPair, isInitiator: true)
        let responder = NoiseHandshake(localKeyPair: responderKeyPair, isInitiator: false)

        // Message A: Initiator -> Responder (-> e)
        let messageA = initiator.writeMessageA()
        try responder.readMessageA(messageA)

        // Message B: Responder -> Initiator (<- e, ee, s, es)
        let messageB = try responder.writeMessageB()
        let payloadB = try initiator.readMessageB(messageB)

        // Verify responder's identity
        let responderStaticPub = Data(responder.localStaticKey.publicKey.rawRepresentation)
        let verifiedResponderPeerID = try payloadB.verify(noiseStaticPublicKey: responderStaticPub)
        #expect(verifiedResponderPeerID == responderKeyPair.peerID)

        // Message C: Initiator -> Responder (-> s, se)
        let messageC = try initiator.writeMessageC()
        let payloadC = try responder.readMessageC(messageC)

        // Verify initiator's identity
        let initiatorStaticPub = Data(initiator.localStaticKey.publicKey.rawRepresentation)
        let verifiedInitiatorPeerID = try payloadC.verify(noiseStaticPublicKey: initiatorStaticPub)
        #expect(verifiedInitiatorPeerID == initiatorKeyPair.peerID)

        // Split and verify cipher states
        let (initiatorSend, initiatorRecv) = initiator.split()
        let (responderSend, responderRecv) = responder.split()

        // Test that cipher states are correctly oriented
        var iSend = initiatorSend
        var rRecv = responderRecv
        var rSend = responderSend
        var iRecv = initiatorRecv

        // Initiator sends, Responder receives
        let testData1 = Data("Hello from initiator".utf8)
        let encrypted1 = try iSend.encryptWithAD(Data(), plaintext: testData1)
        let decrypted1 = try rRecv.decryptWithAD(Data(), ciphertext: encrypted1)
        #expect(decrypted1 == testData1)

        // Responder sends, Initiator receives
        let testData2 = Data("Hello from responder".utf8)
        let encrypted2 = try rSend.encryptWithAD(Data(), plaintext: testData2)
        let decrypted2 = try iRecv.decryptWithAD(Data(), ciphertext: encrypted2)
        #expect(decrypted2 == testData2)
    }

    // MARK: - Message A Tests

    @Test("Message A has correct format")
    func testMessageAFormat() {
        let keyPair = KeyPair.generateEd25519()
        let initiator = NoiseHandshake(localKeyPair: keyPair, isInitiator: true)

        let messageA = initiator.writeMessageA()

        // Message A should be exactly 32 bytes (ephemeral public key)
        #expect(messageA.count == noisePublicKeySize)
    }

    @Test("Message A is valid X25519 public key")
    func testMessageAValidKey() throws {
        let keyPair = KeyPair.generateEd25519()
        let initiator = NoiseHandshake(localKeyPair: keyPair, isInitiator: true)

        let messageA = initiator.writeMessageA()

        // Should be parseable as X25519 public key
        let publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: messageA)
        #expect(publicKey.rawRepresentation == messageA)
    }

    // MARK: - Message B Tests

    @Test("Message B contains all expected components")
    func testMessageBComponents() throws {
        let initiatorKeyPair = KeyPair.generateEd25519()
        let responderKeyPair = KeyPair.generateEd25519()

        let initiator = NoiseHandshake(localKeyPair: initiatorKeyPair, isInitiator: true)
        let responder = NoiseHandshake(localKeyPair: responderKeyPair, isInitiator: false)

        let messageA = initiator.writeMessageA()
        try responder.readMessageA(messageA)
        let messageB = try responder.writeMessageB()

        // Message B should contain:
        // - 32 bytes ephemeral public key (unencrypted)
        // - 48 bytes encrypted static key (32 + 16 tag)
        // - Variable length encrypted payload (with 16 byte tag)
        #expect(messageB.count >= 32 + 48 + 16)

        // First 32 bytes should be valid X25519 public key
        let ephemeralPub = Data(messageB.prefix(noisePublicKeySize))
        let _ = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephemeralPub)
    }

    // MARK: - Message C Tests

    @Test("Message C contains encrypted static key and payload")
    func testMessageCComponents() throws {
        let initiatorKeyPair = KeyPair.generateEd25519()
        let responderKeyPair = KeyPair.generateEd25519()

        let initiator = NoiseHandshake(localKeyPair: initiatorKeyPair, isInitiator: true)
        let responder = NoiseHandshake(localKeyPair: responderKeyPair, isInitiator: false)

        let messageA = initiator.writeMessageA()
        try responder.readMessageA(messageA)
        let messageB = try responder.writeMessageB()
        _ = try initiator.readMessageB(messageB)
        let messageC = try initiator.writeMessageC()

        // Message C should contain:
        // - 48 bytes encrypted static key (32 + 16 tag)
        // - Variable length encrypted payload (with 16 byte tag)
        #expect(messageC.count >= 48 + 16)
    }

    // MARK: - Split Direction Tests

    @Test("Split produces correctly oriented cipher states")
    func testSplitCipherDirection() throws {
        let initiatorKeyPair = KeyPair.generateEd25519()
        let responderKeyPair = KeyPair.generateEd25519()

        let initiator = NoiseHandshake(localKeyPair: initiatorKeyPair, isInitiator: true)
        let responder = NoiseHandshake(localKeyPair: responderKeyPair, isInitiator: false)

        // Complete handshake
        let messageA = initiator.writeMessageA()
        try responder.readMessageA(messageA)
        let messageB = try responder.writeMessageB()
        _ = try initiator.readMessageB(messageB)
        let messageC = try initiator.writeMessageC()
        _ = try responder.readMessageC(messageC)

        let (iSend, iRecv) = initiator.split()
        let (rSend, rRecv) = responder.split()

        // Initiator's send key should match Responder's recv key
        // We verify by encrypting with one and decrypting with the other
        var iSendCopy = iSend
        var rRecvCopy = rRecv

        let testMessage = Data("test message".utf8)
        let ciphertext = try iSendCopy.encryptWithAD(Data(), plaintext: testMessage)
        let plaintext = try rRecvCopy.decryptWithAD(Data(), ciphertext: ciphertext)
        #expect(plaintext == testMessage)

        // Vice versa
        var rSendCopy = rSend
        var iRecvCopy = iRecv

        let testMessage2 = Data("reverse message".utf8)
        let ciphertext2 = try rSendCopy.encryptWithAD(Data(), plaintext: testMessage2)
        let plaintext2 = try iRecvCopy.decryptWithAD(Data(), ciphertext: ciphertext2)
        #expect(plaintext2 == testMessage2)
    }

    // MARK: - PeerID Extraction Tests

    @Test("Correct PeerID is extracted after handshake")
    func testPeerIDExtraction() throws {
        let initiatorKeyPair = KeyPair.generateEd25519()
        let responderKeyPair = KeyPair.generateEd25519()

        let initiator = NoiseHandshake(localKeyPair: initiatorKeyPair, isInitiator: true)
        let responder = NoiseHandshake(localKeyPair: responderKeyPair, isInitiator: false)

        // Complete handshake
        let messageA = initiator.writeMessageA()
        try responder.readMessageA(messageA)
        let messageB = try responder.writeMessageB()
        let payloadB = try initiator.readMessageB(messageB)
        let messageC = try initiator.writeMessageC()
        let payloadC = try responder.readMessageC(messageC)

        // Verify PeerIDs
        let responderStaticPub = Data(responder.localStaticKey.publicKey.rawRepresentation)
        let initiatorStaticPub = Data(initiator.localStaticKey.publicKey.rawRepresentation)

        let extractedResponderPeerID = try payloadB.verify(noiseStaticPublicKey: responderStaticPub)
        let extractedInitiatorPeerID = try payloadC.verify(noiseStaticPublicKey: initiatorStaticPub)

        #expect(extractedResponderPeerID == responderKeyPair.peerID)
        #expect(extractedInitiatorPeerID == initiatorKeyPair.peerID)
    }

    // MARK: - Error Tests

    @Test("Handshake fails with out of order message")
    func testHandshakeMessageOutOfOrder() throws {
        let keyPair = KeyPair.generateEd25519()
        let initiator = NoiseHandshake(localKeyPair: keyPair, isInitiator: true)

        // Try to write Message C before reading Message B
        #expect(throws: NoiseError.self) {
            _ = try initiator.writeMessageC()
        }
    }

    @Test("Responder fails without reading Message A first")
    func testResponderMessageOutOfOrder() throws {
        let keyPair = KeyPair.generateEd25519()
        let responder = NoiseHandshake(localKeyPair: keyPair, isInitiator: false)

        // Try to write Message B before reading Message A
        #expect(throws: NoiseError.self) {
            _ = try responder.writeMessageB()
        }
    }

    @Test("Handshake fails with truncated Message A")
    func testHandshakeTruncatedMessageA() {
        let keyPair = KeyPair.generateEd25519()
        let responder = NoiseHandshake(localKeyPair: keyPair, isInitiator: false)

        let truncatedMessageA = Data(repeating: 0x42, count: 16) // Too short

        #expect(throws: NoiseError.self) {
            try responder.readMessageA(truncatedMessageA)
        }
    }

    @Test("Handshake fails with truncated Message B")
    func testHandshakeTruncatedMessageB() throws {
        let initiatorKeyPair = KeyPair.generateEd25519()
        let responderKeyPair = KeyPair.generateEd25519()

        let initiator = NoiseHandshake(localKeyPair: initiatorKeyPair, isInitiator: true)
        let responder = NoiseHandshake(localKeyPair: responderKeyPair, isInitiator: false)

        let messageA = initiator.writeMessageA()
        try responder.readMessageA(messageA)
        _ = try responder.writeMessageB()

        // Use a truncated Message B
        let truncatedMessageB = Data(repeating: 0x42, count: 50)

        #expect(throws: (any Error).self) {
            _ = try initiator.readMessageB(truncatedMessageB)
        }
    }

    @Test("Handshake fails with too short ephemeral key in Message A")
    func testHandshakeTooShortEphemeralKey() {
        let keyPair = KeyPair.generateEd25519()
        let responder = NoiseHandshake(localKeyPair: keyPair, isInitiator: false)

        // 31 bytes is too short for X25519 public key
        let shortMessageA = Data(repeating: 0x42, count: 31)

        #expect(throws: (any Error).self) {
            try responder.readMessageA(shortMessageA)
        }
    }

    @Test("Handshake fails with tampered Message B")
    func testHandshakeTamperedMessageB() throws {
        let initiatorKeyPair = KeyPair.generateEd25519()
        let responderKeyPair = KeyPair.generateEd25519()

        let initiator = NoiseHandshake(localKeyPair: initiatorKeyPair, isInitiator: true)
        let responder = NoiseHandshake(localKeyPair: responderKeyPair, isInitiator: false)

        let messageA = initiator.writeMessageA()
        try responder.readMessageA(messageA)
        var messageB = try responder.writeMessageB()

        // Tamper with encrypted portion
        messageB[50] ^= 0xFF

        #expect(throws: (any Error).self) {
            _ = try initiator.readMessageB(messageB)
        }
    }

    @Test("Handshake fails with tampered Message C")
    func testHandshakeTamperedMessageC() throws {
        let initiatorKeyPair = KeyPair.generateEd25519()
        let responderKeyPair = KeyPair.generateEd25519()

        let initiator = NoiseHandshake(localKeyPair: initiatorKeyPair, isInitiator: true)
        let responder = NoiseHandshake(localKeyPair: responderKeyPair, isInitiator: false)

        let messageA = initiator.writeMessageA()
        try responder.readMessageA(messageA)
        let messageB = try responder.writeMessageB()
        _ = try initiator.readMessageB(messageB)
        var messageC = try initiator.writeMessageC()

        // Tamper with encrypted portion
        messageC[20] ^= 0xFF

        #expect(throws: (any Error).self) {
            _ = try responder.readMessageC(messageC)
        }
    }

    // MARK: - Remote Key Tests

    @Test("Remote static and ephemeral keys are set after handshake")
    func testRemoteKeysSet() throws {
        let initiatorKeyPair = KeyPair.generateEd25519()
        let responderKeyPair = KeyPair.generateEd25519()

        let initiator = NoiseHandshake(localKeyPair: initiatorKeyPair, isInitiator: true)
        let responder = NoiseHandshake(localKeyPair: responderKeyPair, isInitiator: false)

        // Before handshake
        #expect(initiator.remoteStaticKey == nil)
        #expect(initiator.remoteEphemeralKey == nil)
        #expect(responder.remoteStaticKey == nil)
        #expect(responder.remoteEphemeralKey == nil)

        // Complete handshake
        let messageA = initiator.writeMessageA()
        try responder.readMessageA(messageA)
        let messageB = try responder.writeMessageB()
        _ = try initiator.readMessageB(messageB)
        let messageC = try initiator.writeMessageC()
        _ = try responder.readMessageC(messageC)

        // After handshake
        #expect(initiator.remoteStaticKey != nil)
        #expect(initiator.remoteEphemeralKey != nil)
        #expect(responder.remoteStaticKey != nil)
        #expect(responder.remoteEphemeralKey != nil)

        // Initiator's remote static should match responder's local static
        #expect(initiator.remoteStaticKey?.rawRepresentation ==
                responder.localStaticKey.publicKey.rawRepresentation)

        // Responder's remote static should match initiator's local static
        #expect(responder.remoteStaticKey?.rawRepresentation ==
                initiator.localStaticKey.publicKey.rawRepresentation)
    }

    // MARK: - Multiple Sessions Tests

    @Test("Multiple independent sessions produce different keys")
    func testMultipleIndependentSessions() throws {
        let keyPair1 = KeyPair.generateEd25519()
        let keyPair2 = KeyPair.generateEd25519()

        // Session 1
        let initiator1 = NoiseHandshake(localKeyPair: keyPair1, isInitiator: true)
        let responder1 = NoiseHandshake(localKeyPair: keyPair2, isInitiator: false)

        let messageA1 = initiator1.writeMessageA()
        try responder1.readMessageA(messageA1)
        let messageB1 = try responder1.writeMessageB()
        _ = try initiator1.readMessageB(messageB1)
        let messageC1 = try initiator1.writeMessageC()
        _ = try responder1.readMessageC(messageC1)

        let (send1, _) = initiator1.split()

        // Session 2 (same key pairs, different ephemeral keys)
        let initiator2 = NoiseHandshake(localKeyPair: keyPair1, isInitiator: true)
        let responder2 = NoiseHandshake(localKeyPair: keyPair2, isInitiator: false)

        let messageA2 = initiator2.writeMessageA()
        try responder2.readMessageA(messageA2)
        let messageB2 = try responder2.writeMessageB()
        _ = try initiator2.readMessageB(messageB2)
        let messageC2 = try initiator2.writeMessageC()
        _ = try responder2.readMessageC(messageC2)

        let (send2, _) = initiator2.split()

        // Encrypt same message with both sessions - should produce different ciphertexts
        var s1 = send1
        var s2 = send2
        let testData = Data("test".utf8)
        let ct1 = try s1.encryptWithAD(Data(), plaintext: testData)
        let ct2 = try s2.encryptWithAD(Data(), plaintext: testData)

        // Different ephemeral keys should lead to different session keys
        #expect(ct1 != ct2)
    }
}
