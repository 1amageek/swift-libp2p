import Foundation
import Testing
@testable import P2PGossipSub

@Suite("Topic Tests")
struct TopicTests {
    @Test("Topic preserves string value and UTF-8 bytes")
    func preservesValueAndUTF8Bytes() {
        let topic = Topic("/meshsub/1.1.0/blocks")

        #expect(topic.value == "/meshsub/1.1.0/blocks")
        #expect(topic.utf8Bytes == Data("/meshsub/1.1.0/blocks".utf8))
        #expect(topic.description == "/meshsub/1.1.0/blocks")
    }

    @Test("Topic supports string literals")
    func supportsStringLiteral() {
        let topic: Topic = "blocks"

        #expect(topic.value == "blocks")
    }

    @Test("Topic is hashable and equatable")
    func hashableAndEquatable() {
        let a = Topic("blocks")
        let b = Topic("blocks")
        let c = Topic("transactions")

        #expect(a == b)
        #expect(a != c)

        var set: Set<Topic> = []
        set.insert(a)
        set.insert(b)
        set.insert(c)
        #expect(set.count == 2)
    }

    @Test("Topic encodes and decodes")
    func codable() throws {
        let original = Topic("/meshsub/1.2.0/blocks")

        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Topic.self, from: encoded)

        #expect(decoded == original)
        #expect(decoded.utf8Bytes == original.utf8Bytes)
    }

    @Test("TopicHash reuses topic UTF-8 bytes")
    func topicHashUsesTopicBytes() {
        let topic = Topic("/meshsub/1.1.0/blocks")
        let hash = TopicHash(topic: topic)

        #expect(hash.bytes == topic.utf8Bytes)
    }
}
