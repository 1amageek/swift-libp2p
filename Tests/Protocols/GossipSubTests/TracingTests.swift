/// TracingTests - Tests for GossipSub tracing functionality
import Testing
import Foundation
@testable import P2PGossipSub
@testable import P2PCore

@Suite("GossipSub Tracing Tests")
struct TracingTests {

    // MARK: - Helpers

    private func makePeerID() -> PeerID {
        let keyPair = KeyPair.generateEd25519()
        return PeerID(publicKey: keyPair.publicKey)
    }

    // MARK: - GossipSubTracer Protocol Conformance

    @Test("JSONTracer conforms to GossipSubTracer protocol")
    func jsonTracerConformsToProtocol() {
        let tracer: any GossipSubTracer = JSONTracer()
        let peer = makePeerID()

        // All protocol methods should be callable
        tracer.addPeer(peer, protocol: "/meshsub/1.1.0")
        tracer.removePeer(peer)
        tracer.join(topic: "test-topic")
        tracer.leave(topic: "test-topic")
        tracer.graft(peer: peer, topic: "test-topic")
        tracer.prune(peer: peer, topic: "test-topic")
        tracer.deliverMessage(id: Data([0x01]), topic: "test-topic", from: peer, size: 100)
        tracer.rejectMessage(id: Data([0x01]), topic: "test-topic", from: peer, reason: .invalidSignature)
        tracer.duplicateMessage(id: Data([0x01]), topic: "test-topic", from: peer)
        tracer.publishMessage(id: Data([0x01]), topic: "test-topic")
    }

    // MARK: - addPeer / removePeer

    @Test("addPeer records ADD_PEER event with protocol")
    func addPeerEvent() {
        let tracer = JSONTracer()
        let peer = makePeerID()

        tracer.addPeer(peer, protocol: "/meshsub/1.1.0")

        let events = tracer.events()
        #expect(events.count == 1)
        #expect(events[0].type == "ADD_PEER")
        #expect(events[0].peerID == peer.description)
        #expect(events[0].extra?["protocol"] == "/meshsub/1.1.0")
        #expect(events[0].topic == nil)
        #expect(events[0].messageID == nil)
    }

    @Test("removePeer records REMOVE_PEER event")
    func removePeerEvent() {
        let tracer = JSONTracer()
        let peer = makePeerID()

        tracer.removePeer(peer)

        let events = tracer.events()
        #expect(events.count == 1)
        #expect(events[0].type == "REMOVE_PEER")
        #expect(events[0].peerID == peer.description)
    }

    // MARK: - graft / prune

    @Test("graft records GRAFT event with peer and topic")
    func graftEvent() {
        let tracer = JSONTracer()
        let peer = makePeerID()

        tracer.graft(peer: peer, topic: "blocks")

        let events = tracer.events()
        #expect(events.count == 1)
        #expect(events[0].type == "GRAFT")
        #expect(events[0].peerID == peer.description)
        #expect(events[0].topic == "blocks")
    }

    @Test("prune records PRUNE event with peer and topic")
    func pruneEvent() {
        let tracer = JSONTracer()
        let peer = makePeerID()

        tracer.prune(peer: peer, topic: "transactions")

        let events = tracer.events()
        #expect(events.count == 1)
        #expect(events[0].type == "PRUNE")
        #expect(events[0].peerID == peer.description)
        #expect(events[0].topic == "transactions")
    }

    // MARK: - deliverMessage / rejectMessage / duplicateMessage

    @Test("deliverMessage records DELIVER_MESSAGE event with size")
    func deliverMessageEvent() {
        let tracer = JSONTracer()
        let peer = makePeerID()
        let msgID = Data([0xAB, 0xCD, 0xEF])

        tracer.deliverMessage(id: msgID, topic: "data", from: peer, size: 256)

        let events = tracer.events()
        #expect(events.count == 1)
        #expect(events[0].type == "DELIVER_MESSAGE")
        #expect(events[0].peerID == peer.description)
        #expect(events[0].topic == "data")
        #expect(events[0].messageID == "abcdef")
        #expect(events[0].extra?["size"] == "256")
    }

    @Test("rejectMessage records REJECT_MESSAGE event with reason")
    func rejectMessageEvent() {
        let tracer = JSONTracer()
        let peer = makePeerID()
        let msgID = Data([0x01, 0x02])

        tracer.rejectMessage(id: msgID, topic: "spam", from: peer, reason: .validationFailed)

        let events = tracer.events()
        #expect(events.count == 1)
        #expect(events[0].type == "REJECT_MESSAGE")
        #expect(events[0].peerID == peer.description)
        #expect(events[0].topic == "spam")
        #expect(events[0].messageID == "0102")
        #expect(events[0].extra?["reason"] == "validationFailed")
    }

    @Test("duplicateMessage records DUPLICATE_MESSAGE event")
    func duplicateMessageEvent() {
        let tracer = JSONTracer()
        let peer = makePeerID()
        let msgID = Data([0xFF])

        tracer.duplicateMessage(id: msgID, topic: "chat", from: peer)

        let events = tracer.events()
        #expect(events.count == 1)
        #expect(events[0].type == "DUPLICATE_MESSAGE")
        #expect(events[0].peerID == peer.description)
        #expect(events[0].topic == "chat")
        #expect(events[0].messageID == "ff")
    }

    // MARK: - publishMessage

    @Test("publishMessage records PUBLISH_MESSAGE event")
    func publishMessageEvent() {
        let tracer = JSONTracer()
        let msgID = Data([0xDE, 0xAD])

        tracer.publishMessage(id: msgID, topic: "announcements")

        let events = tracer.events()
        #expect(events.count == 1)
        #expect(events[0].type == "PUBLISH_MESSAGE")
        #expect(events[0].topic == "announcements")
        #expect(events[0].messageID == "dead")
        #expect(events[0].peerID == nil)
    }

    // MARK: - join / leave

    @Test("join records JOIN event")
    func joinEvent() {
        let tracer = JSONTracer()

        tracer.join(topic: "my-topic")

        let events = tracer.events()
        #expect(events.count == 1)
        #expect(events[0].type == "JOIN")
        #expect(events[0].topic == "my-topic")
        #expect(events[0].peerID == nil)
        #expect(events[0].messageID == nil)
    }

    @Test("leave records LEAVE event")
    func leaveEvent() {
        let tracer = JSONTracer()

        tracer.leave(topic: "old-topic")

        let events = tracer.events()
        #expect(events.count == 1)
        #expect(events[0].type == "LEAVE")
        #expect(events[0].topic == "old-topic")
    }

    // MARK: - eventsAsJSON serialization

    @Test("eventsAsJSON produces valid JSON")
    func eventsAsJSONSerialization() throws {
        let tracer = JSONTracer()
        let peer = makePeerID()

        tracer.addPeer(peer, protocol: "/meshsub/1.1.0")
        tracer.join(topic: "test")
        tracer.graft(peer: peer, topic: "test")

        let jsonData = try tracer.eventsAsJSON()

        // Decode back to verify round-trip
        let decoder = JSONDecoder()
        let decoded = try decoder.decode([JSONTracer.TraceEvent].self, from: jsonData)

        #expect(decoded.count == 3)
        #expect(decoded[0].type == "ADD_PEER")
        #expect(decoded[1].type == "JOIN")
        #expect(decoded[2].type == "GRAFT")
    }

    @Test("eventsAsJSON produces empty array when no events")
    func eventsAsJSONEmpty() throws {
        let tracer = JSONTracer()

        let jsonData = try tracer.eventsAsJSON()
        let decoded = try JSONDecoder().decode([JSONTracer.TraceEvent].self, from: jsonData)

        #expect(decoded.isEmpty)
    }

    @Test("TraceEvent timestamp is a valid unix epoch")
    func traceEventTimestamp() {
        let tracer = JSONTracer()
        let before = Date().timeIntervalSince1970

        tracer.join(topic: "ts-test")

        let after = Date().timeIntervalSince1970
        let events = tracer.events()

        #expect(events.count == 1)
        #expect(events[0].timestamp >= before)
        #expect(events[0].timestamp <= after)
    }

    // MARK: - maxEvents limit

    @Test("maxEvents enforces buffer size limit")
    func maxEventsLimit() {
        let tracer = JSONTracer(maxEvents: 5)

        for i in 0..<10 {
            tracer.join(topic: "topic-\(i)")
        }

        let events = tracer.events()
        #expect(events.count == 5)

        // Should retain the most recent 5 events (topics 5-9)
        #expect(events[0].topic == "topic-5")
        #expect(events[1].topic == "topic-6")
        #expect(events[2].topic == "topic-7")
        #expect(events[3].topic == "topic-8")
        #expect(events[4].topic == "topic-9")
    }

    @Test("maxEvents of 1 retains only the last event")
    func maxEventsOne() {
        let tracer = JSONTracer(maxEvents: 1)

        tracer.join(topic: "first")
        tracer.join(topic: "second")
        tracer.join(topic: "third")

        let events = tracer.events()
        #expect(events.count == 1)
        #expect(events[0].topic == "third")
    }

    // MARK: - clear

    @Test("clear removes all buffered events")
    func clearEvents() {
        let tracer = JSONTracer()
        let peer = makePeerID()

        tracer.addPeer(peer, protocol: "/meshsub/1.1.0")
        tracer.join(topic: "test")
        tracer.graft(peer: peer, topic: "test")

        #expect(tracer.events().count == 3)

        tracer.clear()

        #expect(tracer.events().isEmpty)
    }

    @Test("clear allows new events to be recorded afterward")
    func clearThenRecord() {
        let tracer = JSONTracer()

        tracer.join(topic: "before-clear")
        tracer.clear()
        tracer.join(topic: "after-clear")

        let events = tracer.events()
        #expect(events.count == 1)
        #expect(events[0].topic == "after-clear")
    }

    // MARK: - RejectReason raw values

    @Test("RejectReason raw values match expected strings")
    func rejectReasonRawValues() {
        #expect(RejectReason.blacklisted.rawValue == "blacklisted")
        #expect(RejectReason.validationFailed.rawValue == "validationFailed")
        #expect(RejectReason.validationThrottled.rawValue == "validationThrottled")
        #expect(RejectReason.invalidSignature.rawValue == "invalidSignature")
        #expect(RejectReason.selfOrigin.rawValue == "selfOrigin")
    }

    @Test("All RejectReason cases produce distinct raw values")
    func rejectReasonDistinct() {
        let allRawValues: Set<String> = [
            RejectReason.blacklisted.rawValue,
            RejectReason.validationFailed.rawValue,
            RejectReason.validationThrottled.rawValue,
            RejectReason.invalidSignature.rawValue,
            RejectReason.selfOrigin.rawValue,
        ]
        #expect(allRawValues.count == 5)
    }

    // MARK: - Concurrent safety

    @Test("JSONTracer handles concurrent writes safely", .timeLimit(.minutes(1)))
    func concurrentSafety() async {
        let tracer = JSONTracer()
        let iterations = 100

        await withTaskGroup(of: Void.self) { group in
            // Multiple writers adding events concurrently
            for i in 0..<iterations {
                group.addTask {
                    let peer = PeerID(publicKey: KeyPair.generateEd25519().publicKey)
                    tracer.addPeer(peer, protocol: "/meshsub/1.1.0")
                    tracer.graft(peer: peer, topic: "topic-\(i)")
                    tracer.deliverMessage(
                        id: Data([UInt8(i % 256)]),
                        topic: "topic-\(i)",
                        from: peer,
                        size: i * 10
                    )
                }
            }
        }

        // Each iteration produces 3 events: addPeer, graft, deliverMessage
        let events = tracer.events()
        #expect(events.count == iterations * 3)
    }

    @Test("JSONTracer handles concurrent reads and writes", .timeLimit(.minutes(1)))
    func concurrentReadsAndWrites() async {
        let tracer = JSONTracer()
        let iterations = 50

        await withTaskGroup(of: Void.self) { group in
            // Writers
            for i in 0..<iterations {
                group.addTask {
                    tracer.join(topic: "topic-\(i)")
                }
            }

            // Readers interleaved with writers
            for _ in 0..<iterations {
                group.addTask {
                    _ = tracer.events()
                }
            }
        }

        let events = tracer.events()
        #expect(events.count == iterations)
    }

    // MARK: - Multiple event types in sequence

    @Test("Multiple event types are recorded in order")
    func multipleEventTypesInOrder() {
        let tracer = JSONTracer()
        let peer = makePeerID()
        let msgID = Data([0x01, 0x02, 0x03])

        tracer.addPeer(peer, protocol: "/meshsub/1.1.0")
        tracer.join(topic: "ordered-topic")
        tracer.graft(peer: peer, topic: "ordered-topic")
        tracer.publishMessage(id: msgID, topic: "ordered-topic")
        tracer.deliverMessage(id: msgID, topic: "ordered-topic", from: peer, size: 42)
        tracer.duplicateMessage(id: msgID, topic: "ordered-topic", from: peer)
        tracer.rejectMessage(id: msgID, topic: "ordered-topic", from: peer, reason: .blacklisted)
        tracer.prune(peer: peer, topic: "ordered-topic")
        tracer.leave(topic: "ordered-topic")
        tracer.removePeer(peer)

        let events = tracer.events()
        #expect(events.count == 10)

        let types = events.map(\.type)
        #expect(types == [
            "ADD_PEER",
            "JOIN",
            "GRAFT",
            "PUBLISH_MESSAGE",
            "DELIVER_MESSAGE",
            "DUPLICATE_MESSAGE",
            "REJECT_MESSAGE",
            "PRUNE",
            "LEAVE",
            "REMOVE_PEER",
        ])
    }

    // MARK: - Hex encoding of message IDs

    @Test("Message IDs are hex-encoded in events")
    func messageIDHexEncoding() {
        let tracer = JSONTracer()
        let peer = makePeerID()

        tracer.deliverMessage(
            id: Data([0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]),
            topic: "hex-test",
            from: peer,
            size: 16
        )

        let events = tracer.events()
        #expect(events[0].messageID == "00112233445566778899aabbccddeeff")
    }

    @Test("Empty message ID produces empty hex string")
    func emptyMessageIDHex() {
        let tracer = JSONTracer()

        tracer.publishMessage(id: Data(), topic: "empty-id")

        let events = tracer.events()
        #expect(events[0].messageID == "")
    }

    // MARK: - Circular buffer compaction

    @Test("Circular buffer compacts after many evictions")
    func circularBufferCompaction() {
        // maxEvents=3, insert enough to trigger compaction (startIndex > maxSize)
        let tracer = JSONTracer(maxEvents: 3)

        // Insert many more than maxEvents to trigger internal compaction
        for i in 0..<20 {
            tracer.join(topic: "topic-\(i)")
        }

        let events = tracer.events()
        #expect(events.count == 3)
        // Should retain the most recent 3 events (topics 17-19)
        #expect(events[0].topic == "topic-17")
        #expect(events[1].topic == "topic-18")
        #expect(events[2].topic == "topic-19")
    }

    @Test("Circular buffer clear resets internal state")
    func circularBufferClearResets() {
        let tracer = JSONTracer(maxEvents: 5)

        for i in 0..<10 {
            tracer.join(topic: "topic-\(i)")
        }

        tracer.clear()

        // After clear, new events should work correctly
        tracer.join(topic: "fresh-1")
        tracer.join(topic: "fresh-2")

        let events = tracer.events()
        #expect(events.count == 2)
        #expect(events[0].topic == "fresh-1")
        #expect(events[1].topic == "fresh-2")
    }

    @Test("Circular buffer eventsAsJSON after eviction")
    func circularBufferJSONAfterEviction() throws {
        let tracer = JSONTracer(maxEvents: 2)

        tracer.join(topic: "a")
        tracer.join(topic: "b")
        tracer.join(topic: "c")

        let jsonData = try tracer.eventsAsJSON()
        let decoded = try JSONDecoder().decode([JSONTracer.TraceEvent].self, from: jsonData)

        #expect(decoded.count == 2)
        #expect(decoded[0].topic == "b")
        #expect(decoded[1].topic == "c")
    }
}
