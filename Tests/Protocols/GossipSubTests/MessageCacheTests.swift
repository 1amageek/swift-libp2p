/// MessageCacheTests - Tests for GossipSub message caching
import Testing
import Foundation
@testable import P2PGossipSub
@testable import P2PCore

@Suite("Message Cache Tests")
struct MessageCacheTests {

    // MARK: - Basic Operations

    @Test("Put and get message")
    func putAndGet() {
        let cache = MessageCache(windowCount: 5, gossipWindowCount: 3)
        let topic = Topic("test")
        let message = makeMessage(topic: topic, data: "hello")

        cache.put(message)

        let retrieved = cache.get(message.id)
        #expect(retrieved != nil)
        #expect(retrieved?.data == message.data)
        #expect(retrieved?.topic == message.topic)
    }

    @Test("Contains returns true for cached message")
    func containsCached() {
        let cache = MessageCache(windowCount: 5, gossipWindowCount: 3)
        let message = makeMessage(topic: "test", data: "hello")

        #expect(!cache.contains(message.id))

        cache.put(message)

        #expect(cache.contains(message.id))
    }

    @Test("Duplicate messages are not added twice")
    func noDuplicates() {
        let cache = MessageCache(windowCount: 5, gossipWindowCount: 3)
        let message = makeMessage(topic: "test", data: "hello")

        cache.put(message)
        cache.put(message) // Same message again

        #expect(cache.count == 1)
    }

    // MARK: - Window Shifting

    @Test("Messages expire after window shift")
    func windowShift() {
        let cache = MessageCache(windowCount: 3, gossipWindowCount: 2)
        let message = makeMessage(topic: "test", data: "hello")

        cache.put(message)
        #expect(cache.contains(message.id))

        // Shift 3 times (window count)
        cache.shift()
        cache.shift()
        cache.shift()

        // Message should be evicted
        #expect(!cache.contains(message.id))
        #expect(cache.get(message.id) == nil)
    }

    @Test("Newer messages survive window shift")
    func newerMessagesSurvive() {
        let cache = MessageCache(windowCount: 3, gossipWindowCount: 2)

        let oldMessage = makeMessage(topic: "test", data: "old")
        cache.put(oldMessage)

        cache.shift() // Move to window 1

        let newMessage = makeMessage(topic: "test", data: "new")
        cache.put(newMessage)

        cache.shift() // Move to window 2
        cache.shift() // Move to window 3, old message evicted

        #expect(!cache.contains(oldMessage.id))
        #expect(cache.contains(newMessage.id))
    }

    // MARK: - Gossip IDs

    @Test("Get gossip IDs for topic")
    func gossipIDs() {
        let cache = MessageCache(windowCount: 5, gossipWindowCount: 3)
        let topic = Topic("test")

        let msg1 = makeMessage(topic: topic, data: "1")
        let msg2 = makeMessage(topic: topic, data: "2")
        let msg3 = makeMessage(topic: "other", data: "3")

        cache.put(msg1)
        cache.put(msg2)
        cache.put(msg3)

        let gossipIDs = cache.getGossipIDs(for: topic)

        #expect(gossipIDs.count == 2)
        #expect(gossipIDs.contains(msg1.id))
        #expect(gossipIDs.contains(msg2.id))
        #expect(!gossipIDs.contains(msg3.id))
    }

    @Test("Gossip IDs only from recent windows")
    func gossipIDsRecentOnly() {
        let cache = MessageCache(windowCount: 5, gossipWindowCount: 2)
        let topic = Topic("test")

        let oldMsg = makeMessage(topic: topic, data: "old")
        cache.put(oldMsg)

        cache.shift()
        cache.shift()
        cache.shift() // Old message now in window 3 (outside gossip window)

        let newMsg = makeMessage(topic: topic, data: "new")
        cache.put(newMsg)

        let gossipIDs = cache.getGossipIDs(for: topic)

        // Only new message should be in gossip range
        #expect(gossipIDs.contains(newMsg.id))
        // Old message outside gossip window but still in cache
        #expect(cache.contains(oldMsg.id))
    }

    // MARK: - Get Multiple

    @Test("Get multiple messages by ID")
    func getMultiple() {
        let cache = MessageCache(windowCount: 5, gossipWindowCount: 3)

        let msg1 = makeMessage(topic: "test", data: "1")
        let msg2 = makeMessage(topic: "test", data: "2")
        let msg3 = makeMessage(topic: "test", data: "3")
        let unknownID = MessageID(bytes: Data([0xFF, 0xFF]))

        cache.put(msg1)
        cache.put(msg2)
        cache.put(msg3)

        let result = cache.getMultiple([msg1.id, msg3.id, unknownID])

        #expect(result.count == 2)
        #expect(result[msg1.id]?.data == msg1.data)
        #expect(result[msg3.id]?.data == msg3.data)
        #expect(result[unknownID] == nil)
    }

    // MARK: - Clear

    @Test("Clear removes all messages")
    func clearCache() {
        let cache = MessageCache(windowCount: 5, gossipWindowCount: 3)

        cache.put(makeMessage(topic: "test", data: "1"))
        cache.put(makeMessage(topic: "test", data: "2"))
        cache.put(makeMessage(topic: "test", data: "3"))

        #expect(cache.count == 3)

        cache.clear()

        #expect(cache.count == 0)
        #expect(cache.allMessageIDs.isEmpty)
    }

    // MARK: - Helpers

    private func makeMessage(topic: Topic, data: String) -> GossipSubMessage {
        var seqno = Data(count: 8)
        for i in 0..<8 {
            seqno[i] = UInt8.random(in: 0...255)
        }
        return GossipSubMessage(
            source: nil,
            data: Data(data.utf8),
            sequenceNumber: seqno,
            topic: topic
        )
    }

    private func makeMessage(topic: String, data: String) -> GossipSubMessage {
        makeMessage(topic: Topic(topic), data: data)
    }
}

@Suite("Seen Cache Tests")
struct SeenCacheTests {

    @Test("Add returns true for new message")
    func addNew() {
        let cache = SeenCache(maxSize: 100, ttl: .seconds(60))
        let msgID = MessageID(bytes: Data([0x01, 0x02, 0x03]))

        let isNew = cache.add(msgID)
        #expect(isNew == true)
    }

    @Test("Add returns false for duplicate")
    func addDuplicate() {
        let cache = SeenCache(maxSize: 100, ttl: .seconds(60))
        let msgID = MessageID(bytes: Data([0x01, 0x02, 0x03]))

        _ = cache.add(msgID)
        let isNew = cache.add(msgID)

        #expect(isNew == false)
    }

    @Test("Contains returns correct values")
    func containsCheck() {
        let cache = SeenCache(maxSize: 100, ttl: .seconds(60))
        let msgID = MessageID(bytes: Data([0x01, 0x02, 0x03]))
        let otherID = MessageID(bytes: Data([0x04, 0x05, 0x06]))

        #expect(!cache.contains(msgID))

        cache.add(msgID)

        #expect(cache.contains(msgID))
        #expect(!cache.contains(otherID))
    }

    @Test("LRU eviction when full")
    func lruEviction() {
        let cache = SeenCache(maxSize: 3, ttl: .seconds(60))

        let id1 = MessageID(bytes: Data([0x01]))
        let id2 = MessageID(bytes: Data([0x02]))
        let id3 = MessageID(bytes: Data([0x03]))
        let id4 = MessageID(bytes: Data([0x04]))

        cache.add(id1)
        cache.add(id2)
        cache.add(id3)

        #expect(cache.count == 3)

        cache.add(id4) // Should evict id1

        #expect(cache.count == 3)
        #expect(!cache.contains(id1)) // Evicted
        #expect(cache.contains(id2))
        #expect(cache.contains(id3))
        #expect(cache.contains(id4))
    }

    @Test("Clear removes all entries")
    func clearAll() {
        let cache = SeenCache(maxSize: 100, ttl: .seconds(60))

        cache.add(MessageID(bytes: Data([0x01])))
        cache.add(MessageID(bytes: Data([0x02])))
        cache.add(MessageID(bytes: Data([0x03])))

        #expect(cache.count == 3)

        cache.clear()

        #expect(cache.count == 0)
    }
}
