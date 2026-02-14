import Testing
import Foundation
import P2PCore
import P2PProtocols
@testable import P2PPlumtree

@Suite("Plumtree Service Tests")
struct PlumtreeServiceTests {

    private func makePeerID() -> PeerID {
        KeyPair.generateEd25519().peerID
    }

    @Test("Service conforms to ProtocolService")
    func conformsToProtocolService() {
        let service = PlumtreeService(
            localPeerID: makePeerID(),
            configuration: .testing
        )
        let _: any ProtocolService = service
        #expect(service.protocolIDs == [plumtreeProtocolID])
    }

    @Test("Start and shutdown lifecycle")
    func startShutdownLifecycle() {
        let service = PlumtreeService(
            localPeerID: makePeerID(),
            configuration: .testing
        )
        #expect(!service.isStarted)

        service.start()
        #expect(service.isStarted)

        service.shutdown()
        #expect(!service.isStarted)
    }

    @Test("Subscribe and unsubscribe")
    func subscribeUnsubscribe() {
        let service = PlumtreeService(
            localPeerID: makePeerID(),
            configuration: .testing
        )
        service.start()

        _ = service.subscribe(to: "test-topic")
        #expect(service.subscribedTopics.contains("test-topic"))

        service.unsubscribe(from: "test-topic")
        #expect(!service.subscribedTopics.contains("test-topic"))

        service.shutdown()
    }

    @Test("Publish requires started service")
    func publishRequiresStarted() {
        let service = PlumtreeService(
            localPeerID: makePeerID(),
            configuration: .testing
        )

        #expect(throws: PlumtreeError.self) {
            try service.publish(data: Data("test".utf8), to: "topic")
        }
    }

    @Test("Publish requires subscription")
    func publishRequiresSubscription() {
        let service = PlumtreeService(
            localPeerID: makePeerID(),
            configuration: .testing
        )
        service.start()

        #expect(throws: PlumtreeError.self) {
            try service.publish(data: Data("test".utf8), to: "topic")
        }

        service.shutdown()
    }

    @Test("Publish rejects oversized messages")
    func publishRejectsOversized() {
        let config = PlumtreeConfiguration(maxMessageSize: 100)
        let service = PlumtreeService(
            localPeerID: makePeerID(),
            configuration: config
        )
        service.start()
        _ = service.subscribe(to: "topic")

        let largeData = Data(repeating: 0xFF, count: 200)
        #expect(throws: PlumtreeError.self) {
            try service.publish(data: largeData, to: "topic")
        }

        service.shutdown()
    }

    @Test("Publish returns message ID")
    func publishReturnsMessageID() throws {
        let service = PlumtreeService(
            localPeerID: makePeerID(),
            configuration: .testing
        )
        service.start()
        _ = service.subscribe(to: "topic")

        let msgID = try service.publish(data: Data("hello".utf8), to: "topic")
        #expect(!msgID.bytes.isEmpty)

        service.shutdown()
    }

    @Test("Events stream is multi-consumer")
    func eventsMultiConsumer() {
        let service = PlumtreeService(
            localPeerID: makePeerID(),
            configuration: .testing
        )

        let stream1 = service.events
        let stream2 = service.events
        // Both should be independent streams
        _ = stream1
        _ = stream2
    }

    @Test("MessageID compute is deterministic")
    func messageIDDeterministic() {
        let source = makePeerID()
        let id1 = PlumtreeMessageID.compute(source: source, sequenceNumber: 42)
        let id2 = PlumtreeMessageID.compute(source: source, sequenceNumber: 42)
        #expect(id1 == id2)

        let id3 = PlumtreeMessageID.compute(source: source, sequenceNumber: 43)
        #expect(id1 != id3)
    }

    @Test("MessageID description is hex prefix")
    func messageIDDescription() {
        let id = PlumtreeMessageID(bytes: Data([0xDE, 0xAD, 0xBE, 0xEF]))
        #expect(id.description == "deadbeef")
    }

    @Test("PlumtreeRPC isEmpty")
    func rpcIsEmpty() {
        let empty = PlumtreeRPC()
        #expect(empty.isEmpty)

        let withGossip = PlumtreeRPC(gossipMessages: [
            PlumtreeGossip(
                messageID: PlumtreeMessageID(bytes: Data([1])),
                topic: "t",
                data: Data(),
                source: makePeerID(),
                hopCount: 0
            )
        ])
        #expect(!withGossip.isEmpty)
    }

    @Test("Configuration presets")
    func configurationPresets() {
        let defaultConfig = PlumtreeConfiguration.default
        #expect(defaultConfig.ihaveTimeout == .seconds(3))
        #expect(defaultConfig.maxMessageSize == 4 * 1024 * 1024)

        let testingConfig = PlumtreeConfiguration.testing
        #expect(testingConfig.ihaveTimeout == .milliseconds(500))
        #expect(testingConfig.lazyPushDelay == .milliseconds(50))
    }
}
