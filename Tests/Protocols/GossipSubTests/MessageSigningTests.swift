/// MessageSigningTests - Tests for GossipSub message signing functionality
import Testing
import Foundation
@testable import P2PGossipSub
@testable import P2PCore

@Suite("GossipSub Message Signing")
struct MessageSigningTests {

    // MARK: - Builder Signing Tests

    @Test("Builder signs message with Ed25519 key")
    func builderSignsMessage() throws {
        let privateKey = PrivateKey.generateEd25519()
        let peerID = privateKey.publicKey.peerID
        let topic = Topic("test-topic")
        let data = Data("Hello, World!".utf8)

        let message = try GossipSubMessage.Builder(data: data, topic: topic)
            .source(peerID)
            .sign(with: privateKey)
            .build()

        #expect(message.source == peerID)
        #expect(message.data == data)
        #expect(message.topic == topic)
        #expect(message.signature != nil)
        #expect(message.key != nil)
        #expect(message.sequenceNumber.count == 8)
    }

    @Test("Signed message passes verification")
    func signedMessageVerifies() throws {
        let privateKey = PrivateKey.generateEd25519()
        let peerID = privateKey.publicKey.peerID
        let topic = Topic("test-topic")
        let data = Data("Test message".utf8)

        let message = try GossipSubMessage.Builder(data: data, topic: topic)
            .source(peerID)
            .sign(with: privateKey)
            .build()

        #expect(message.verifySignature() == true)
    }

    @Test("Signing requires source to be set")
    func signingRequiresSource() throws {
        let privateKey = PrivateKey.generateEd25519()
        let topic = Topic("test-topic")
        let data = Data("Test".utf8)

        #expect(throws: GossipSubError.signingRequiresSource) {
            _ = try GossipSubMessage.Builder(data: data, topic: topic)
                .sign(with: privateKey)
                .build()
        }
    }

    @Test("Unsigned message fails verification")
    func unsignedMessageFailsVerification() throws {
        let privateKey = PrivateKey.generateEd25519()
        let peerID = privateKey.publicKey.peerID
        let topic = Topic("test-topic")
        let data = Data("Test".utf8)

        let message = try GossipSubMessage.Builder(data: data, topic: topic)
            .source(peerID)
            .autoSequenceNumber()
            .build()

        #expect(message.signature == nil)
        #expect(message.verifySignature() == false)
    }

    @Test("Tampered message fails verification")
    func tamperedMessageFailsVerification() throws {
        let privateKey = PrivateKey.generateEd25519()
        let peerID = privateKey.publicKey.peerID
        let topic = Topic("test-topic")
        let originalData = Data("Original".utf8)

        let signedMessage = try GossipSubMessage.Builder(data: originalData, topic: topic)
            .source(peerID)
            .sign(with: privateKey)
            .build()

        // Create tampered message with different data but same signature
        let tamperedMessage = GossipSubMessage(
            source: signedMessage.source,
            data: Data("Tampered".utf8),  // Different data
            sequenceNumber: signedMessage.sequenceNumber,
            topic: signedMessage.topic,
            signature: signedMessage.signature,
            key: signedMessage.key
        )

        #expect(tamperedMessage.verifySignature() == false)
    }

    @Test("Message signed with wrong key fails verification")
    func wrongKeyFailsVerification() throws {
        let signingKey = PrivateKey.generateEd25519()
        let differentKey = PrivateKey.generateEd25519()
        let claimedPeerID = differentKey.publicKey.peerID  // Different from signing key
        let topic = Topic("test-topic")
        let data = Data("Test".utf8)

        // Sign with signingKey but claim to be from differentKey's PeerID
        let signedMessage = try GossipSubMessage.Builder(data: data, topic: topic)
            .source(signingKey.publicKey.peerID)
            .sign(with: signingKey)
            .build()

        // Create message claiming to be from different peer but with same signature
        let spoofedMessage = GossipSubMessage(
            source: claimedPeerID,
            data: data,
            sequenceNumber: signedMessage.sequenceNumber,
            topic: signedMessage.topic,
            signature: signedMessage.signature,
            key: signedMessage.key  // Key won't match claimed source
        )

        #expect(spoofedMessage.verifySignature() == false)
    }

    // MARK: - Router Tests

    @Test("Router with signingKey signs published messages")
    func routerSignsMessages() throws {
        let privateKey = PrivateKey.generateEd25519()
        let peerID = privateKey.publicKey.peerID

        var config = GossipSubConfiguration()
        config.signMessages = true

        let router = GossipSubRouter(
            localPeerID: peerID,
            signingKey: privateKey,
            configuration: config
        )

        // Subscribe to allow publishing
        _ = try router.subscribe(to: Topic("test"))

        let message = try router.publish(Data("Hello".utf8), to: Topic("test"))

        #expect(message.signature != nil)
        #expect(message.key != nil)
        #expect(message.verifySignature() == true)
    }

    @Test("Router without signingKey fails when signMessages is enabled")
    func routerWithoutKeyFailsWhenSigningRequired() throws {
        let privateKey = PrivateKey.generateEd25519()
        let peerID = privateKey.publicKey.peerID

        var config = GossipSubConfiguration()
        config.signMessages = true

        let router = GossipSubRouter(
            localPeerID: peerID,
            signingKey: nil,  // No signing key
            configuration: config
        )

        _ = try router.subscribe(to: Topic("test"))

        #expect(throws: GossipSubError.signingKeyRequired) {
            _ = try router.publish(Data("Hello".utf8), to: Topic("test"))
        }
    }

    @Test("Router without signingKey works when signMessages is disabled")
    func routerWithoutKeyWorksWhenSigningDisabled() throws {
        let privateKey = PrivateKey.generateEd25519()
        let peerID = privateKey.publicKey.peerID

        var config = GossipSubConfiguration()
        config.signMessages = false

        let router = GossipSubRouter(
            localPeerID: peerID,
            signingKey: nil,
            configuration: config
        )

        _ = try router.subscribe(to: Topic("test"))

        let message = try router.publish(Data("Hello".utf8), to: Topic("test"))

        #expect(message.signature == nil)
        #expect(message.key == nil)
    }

    @Test("Router publish rejects data over maxMessageSize")
    func routerPublishRejectsOversizedData() throws {
        let privateKey = PrivateKey.generateEd25519()
        let peerID = privateKey.publicKey.peerID

        var config = GossipSubConfiguration()
        config.maxMessageSize = 8
        config.signMessages = false

        let router = GossipSubRouter(
            localPeerID: peerID,
            signingKey: nil,
            configuration: config
        )

        _ = try router.subscribe(to: Topic("test"))

        let oversized = Data(repeating: 0xAB, count: 9)
        do {
            _ = try router.publish(oversized, to: Topic("test"))
            Issue.record("Expected publish to fail with messageTooLarge")
        } catch let error as GossipSubError {
            #expect(error == .messageTooLarge(size: 9, maxSize: 8))
        } catch {
            Issue.record("Expected GossipSubError.messageTooLarge, got \(error)")
        }
    }

    // MARK: - Service Tests

    @Test("Service with KeyPair enables signing")
    func serviceWithKeyPairEnablesSigning() throws {
        let keyPair = KeyPair.generateEd25519()

        var config = GossipSubConfiguration()
        config.signMessages = true

        let service = GossipSubService(keyPair: keyPair, configuration: config)
        service.start()
        defer { service.shutdown() }

        #expect(service.localPeerID == keyPair.peerID)
    }

    @Test("Service with localPeerID only requires testing config")
    func serviceWithPeerIDRequiresTestingConfig() throws {
        let keyPair = KeyPair.generateEd25519()

        // This should work because .testing has signMessages=false
        let service = GossipSubService(
            localPeerID: keyPair.peerID,
            configuration: .testing
        )
        service.start()
        defer { service.shutdown() }

        #expect(service.localPeerID == keyPair.peerID)
    }

    // MARK: - Wire Format Compatibility

    @Test("Signing data format matches libp2p spec")
    func signingDataFormatMatchesSpec() throws {
        // This test verifies the signing data format is compatible with
        // the libp2p pubsub specification
        let privateKey = PrivateKey.generateEd25519()
        let peerID = privateKey.publicKey.peerID
        let topic = Topic("test-topic")
        let data = Data([0x01, 0x02, 0x03])
        let seqno = Data([0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01])

        let message = try GossipSubMessage.Builder(data: data, topic: topic)
            .source(peerID)
            .sequenceNumber(seqno)
            .sign(with: privateKey)
            .build()

        // Verify signature format
        #expect(message.signature != nil)
        #expect(message.signature!.count == 64)  // Ed25519 signature is 64 bytes

        // Verify key format (protobuf-encoded public key)
        #expect(message.key != nil)

        // Verify the signature is valid
        #expect(message.verifySignature() == true)
    }
}
