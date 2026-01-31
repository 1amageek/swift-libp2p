/// ExtendedValidatorTests - Tests for GossipSub v1.1 extended message validators
import Testing
import Foundation
@testable import P2PGossipSub
@testable import P2PCore
@testable import P2PMux

/// Test validator that always accepts.
private struct AcceptValidator: MessageValidator {
    func validate(message: GossipSubMessage, from peer: PeerID) async -> GossipSubMessage.ValidationResult {
        .accept
    }
}

/// Test validator that always rejects.
private struct RejectValidator: MessageValidator {
    func validate(message: GossipSubMessage, from peer: PeerID) async -> GossipSubMessage.ValidationResult {
        .reject
    }
}

/// Test validator that always ignores.
private struct IgnoreValidator: MessageValidator {
    func validate(message: GossipSubMessage, from peer: PeerID) async -> GossipSubMessage.ValidationResult {
        .ignore
    }
}

/// Test validator that checks message data for a specific prefix.
private struct PrefixValidator: MessageValidator {
    let requiredPrefix: Data

    func validate(message: GossipSubMessage, from peer: PeerID) async -> GossipSubMessage.ValidationResult {
        if message.data.starts(with: requiredPrefix) {
            return .accept
        }
        return .reject
    }
}

@Suite("Extended Validator Tests", .serialized)
struct ExtendedValidatorTests {

    // MARK: - Helpers

    private func makePeerID() -> PeerID {
        KeyPair.generateEd25519().peerID
    }

    private func makeRouter(
        configuration: GossipSubConfiguration = .testing
    ) -> GossipSubRouter {
        let localPeerID = makePeerID()
        return GossipSubRouter(localPeerID: localPeerID, configuration: configuration)
    }

    private func makeMessage(topic: Topic, data: Data = Data("test".utf8)) -> GossipSubMessage {
        let builder = GossipSubMessage.Builder(data: data, topic: topic)
            .autoSequenceNumber()
        do {
            return try builder.build()
        } catch {
            fatalError("Failed to build test message: \(error)")
        }
    }

    // MARK: - Tests

    @Test("Validator accept allows message delivery")
    func validatorAccept() async throws {
        let router = makeRouter()
        let topic = Topic("test-topic")

        _ = try router.subscribe(to: topic)

        // Register accept validator
        router.registerValidator(AcceptValidator(), for: topic)

        let sender = makePeerID()
        let message = makeMessage(topic: topic)

        // Send message
        let rpc = GossipSubRPC(messages: [message])
        _ = await router.handleRPC(rpc, from: sender)

        // Message should be forwarded (accepted)
        // Even with no mesh peers, the message should be processed and cached
        #expect(router.seenCache.contains(message.id))
    }

    @Test("Validator reject penalizes sender and drops message")
    func validatorReject() async throws {
        let router = makeRouter()
        let topic = Topic("test-topic")

        _ = try router.subscribe(to: topic)

        // Register reject validator
        router.registerValidator(RejectValidator(), for: topic)

        let sender = makePeerID()
        let message = makeMessage(topic: topic)

        let rpc = GossipSubRPC(messages: [message])
        _ = await router.handleRPC(rpc, from: sender)

        // Message should be seen (dedup cache) but not in message cache (rejected)
        #expect(router.seenCache.contains(message.id))
        #expect(!router.messageCache.contains(message.id))

        // Peer should have been penalized
        let score = router.peerScorer.score(for: sender)
        #expect(score < 0)
    }

    @Test("Validator ignore drops message without penalty")
    func validatorIgnore() async throws {
        let router = makeRouter()
        let topic = Topic("test-topic")

        _ = try router.subscribe(to: topic)

        // Register ignore validator
        router.registerValidator(IgnoreValidator(), for: topic)

        let sender = makePeerID()
        let scoreBefore = router.peerScorer.score(for: sender)
        let message = makeMessage(topic: topic)

        let rpc = GossipSubRPC(messages: [message])
        _ = await router.handleRPC(rpc, from: sender)

        // Message should be seen but not cached
        #expect(router.seenCache.contains(message.id))
        #expect(!router.messageCache.contains(message.id))

        // No penalty should be applied
        let scoreAfter = router.peerScorer.score(for: sender)
        #expect(scoreAfter == scoreBefore)
    }

    @Test("Per-topic validators are called correctly")
    func validatorPerTopic() async throws {
        let router = makeRouter()
        let acceptTopic = Topic("accept-topic")
        let rejectTopic = Topic("reject-topic")

        _ = try router.subscribe(to: acceptTopic)
        _ = try router.subscribe(to: rejectTopic)

        router.registerValidator(AcceptValidator(), for: acceptTopic)
        router.registerValidator(RejectValidator(), for: rejectTopic)

        let sender = makePeerID()

        // Message on accept topic should be cached
        let acceptMsg = makeMessage(topic: acceptTopic)
        let rpc1 = GossipSubRPC(messages: [acceptMsg])
        _ = await router.handleRPC(rpc1, from: sender)
        #expect(router.messageCache.contains(acceptMsg.id))

        // Message on reject topic should NOT be cached
        let rejectMsg = makeMessage(topic: rejectTopic, data: Data("rejected".utf8))
        let rpc2 = GossipSubRPC(messages: [rejectMsg])
        _ = await router.handleRPC(rpc2, from: sender)
        #expect(!router.messageCache.contains(rejectMsg.id))
    }

    @Test("Validator register and unregister")
    func validatorRegisterUnregister() async throws {
        let router = makeRouter()
        let topic = Topic("test-topic")

        _ = try router.subscribe(to: topic)

        // Register reject validator
        router.registerValidator(RejectValidator(), for: topic)

        let sender = makePeerID()
        let msg1 = makeMessage(topic: topic, data: Data("msg1".utf8))
        let rpc1 = GossipSubRPC(messages: [msg1])
        _ = await router.handleRPC(rpc1, from: sender)

        // Should be rejected
        #expect(!router.messageCache.contains(msg1.id))

        // Unregister
        router.unregisterValidator(for: topic)

        // Now messages should be accepted
        let msg2 = makeMessage(topic: topic, data: Data("msg2".utf8))
        let rpc2 = GossipSubRPC(messages: [msg2])
        _ = await router.handleRPC(rpc2, from: sender)

        #expect(router.messageCache.contains(msg2.id))
    }

    @Test("Topic without validator accepts all messages")
    func topicWithoutValidator() async throws {
        let router = makeRouter()
        let topic = Topic("no-validator-topic")

        _ = try router.subscribe(to: topic)

        // No validator registered

        let sender = makePeerID()
        let message = makeMessage(topic: topic)
        let rpc = GossipSubRPC(messages: [message])
        _ = await router.handleRPC(rpc, from: sender)

        // Message should be accepted and cached
        #expect(router.messageCache.contains(message.id))
    }
}
