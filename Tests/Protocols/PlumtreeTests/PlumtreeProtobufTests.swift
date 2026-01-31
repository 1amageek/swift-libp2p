import Testing
import Foundation
import P2PCore
@testable import P2PPlumtree

@Suite("Plumtree Protobuf Tests")
struct PlumtreeProtobufTests {

    private func makePeerID() -> PeerID {
        KeyPair.generateEd25519().peerID
    }

    @Test("Gossip roundtrip")
    func gossipRoundtrip() throws {
        let source = makePeerID()
        let msgID = PlumtreeMessageID.compute(source: source, sequenceNumber: 42)
        let gossip = PlumtreeGossip(
            messageID: msgID,
            topic: "test-topic",
            data: Data("hello world".utf8),
            source: source,
            hopCount: 3
        )

        let rpc = PlumtreeRPC(gossipMessages: [gossip])
        let encoded = PlumtreeProtobuf.encode(rpc)
        let decoded = try PlumtreeProtobuf.decode(encoded)

        #expect(decoded.gossipMessages.count == 1)
        let g = decoded.gossipMessages[0]
        #expect(g.messageID == msgID)
        #expect(g.topic == "test-topic")
        #expect(g.data == Data("hello world".utf8))
        #expect(g.source == source)
        #expect(g.hopCount == 3)
    }

    @Test("IHave roundtrip")
    func ihaveRoundtrip() throws {
        let msgID = PlumtreeMessageID(bytes: Data([1, 2, 3, 4, 5]))
        let entry = PlumtreeIHaveEntry(messageID: msgID, topic: "my-topic")

        let rpc = PlumtreeRPC(ihaveEntries: [entry])
        let encoded = PlumtreeProtobuf.encode(rpc)
        let decoded = try PlumtreeProtobuf.decode(encoded)

        #expect(decoded.ihaveEntries.count == 1)
        #expect(decoded.ihaveEntries[0].messageID == msgID)
        #expect(decoded.ihaveEntries[0].topic == "my-topic")
    }

    @Test("Graft with messageID roundtrip")
    func graftWithMessageIDRoundtrip() throws {
        let msgID = PlumtreeMessageID(bytes: Data([10, 20, 30]))
        let graft = PlumtreeGraftRequest(topic: "graft-topic", messageID: msgID)

        let rpc = PlumtreeRPC(graftRequests: [graft])
        let encoded = PlumtreeProtobuf.encode(rpc)
        let decoded = try PlumtreeProtobuf.decode(encoded)

        #expect(decoded.graftRequests.count == 1)
        #expect(decoded.graftRequests[0].topic == "graft-topic")
        #expect(decoded.graftRequests[0].messageID == msgID)
    }

    @Test("Graft without messageID roundtrip")
    func graftWithoutMessageIDRoundtrip() throws {
        let graft = PlumtreeGraftRequest(topic: "no-msg-topic")

        let rpc = PlumtreeRPC(graftRequests: [graft])
        let encoded = PlumtreeProtobuf.encode(rpc)
        let decoded = try PlumtreeProtobuf.decode(encoded)

        #expect(decoded.graftRequests.count == 1)
        #expect(decoded.graftRequests[0].topic == "no-msg-topic")
        #expect(decoded.graftRequests[0].messageID == nil)
    }

    @Test("Prune roundtrip")
    func pruneRoundtrip() throws {
        let prune = PlumtreePruneRequest(topic: "prune-topic")

        let rpc = PlumtreeRPC(pruneRequests: [prune])
        let encoded = PlumtreeProtobuf.encode(rpc)
        let decoded = try PlumtreeProtobuf.decode(encoded)

        #expect(decoded.pruneRequests.count == 1)
        #expect(decoded.pruneRequests[0].topic == "prune-topic")
    }

    @Test("Mixed RPC roundtrip")
    func mixedRPCRoundtrip() throws {
        let source = makePeerID()
        let gossip = PlumtreeGossip(
            messageID: PlumtreeMessageID.compute(source: source, sequenceNumber: 1),
            topic: "t1",
            data: Data([0xFF]),
            source: source,
            hopCount: 0
        )
        let ihave = PlumtreeIHaveEntry(
            messageID: PlumtreeMessageID(bytes: Data([1])),
            topic: "t2"
        )
        let graft = PlumtreeGraftRequest(topic: "t3")
        let prune = PlumtreePruneRequest(topic: "t4")

        let rpc = PlumtreeRPC(
            gossipMessages: [gossip],
            ihaveEntries: [ihave],
            graftRequests: [graft],
            pruneRequests: [prune]
        )
        let encoded = PlumtreeProtobuf.encode(rpc)
        let decoded = try PlumtreeProtobuf.decode(encoded)

        #expect(decoded.gossipMessages.count == 1)
        #expect(decoded.ihaveEntries.count == 1)
        #expect(decoded.graftRequests.count == 1)
        #expect(decoded.pruneRequests.count == 1)
        #expect(decoded.gossipMessages[0].topic == "t1")
        #expect(decoded.ihaveEntries[0].topic == "t2")
        #expect(decoded.graftRequests[0].topic == "t3")
        #expect(decoded.pruneRequests[0].topic == "t4")
    }

    @Test("Empty RPC roundtrip")
    func emptyRPCRoundtrip() throws {
        let rpc = PlumtreeRPC()
        let encoded = PlumtreeProtobuf.encode(rpc)
        // Empty RPC produces empty data
        #expect(encoded.isEmpty)
    }

    @Test("Decode empty data throws")
    func decodeEmptyDataThrows() {
        #expect(throws: (any Error).self) {
            try PlumtreeProtobuf.decode(Data())
        }
    }

    @Test("Decode garbage data throws")
    func decodeGarbageDataThrows() {
        #expect(throws: (any Error).self) {
            try PlumtreeProtobuf.decode(Data([0xFF, 0xFF, 0xFF]))
        }
    }

    @Test("Multiple gossip messages roundtrip")
    func multipleGossipRoundtrip() throws {
        let source = makePeerID()
        let gossips = (0..<3).map { i in
            PlumtreeGossip(
                messageID: PlumtreeMessageID.compute(source: source, sequenceNumber: UInt64(i)),
                topic: "topic-\(i)",
                data: Data("msg-\(i)".utf8),
                source: source,
                hopCount: UInt32(i)
            )
        }

        let rpc = PlumtreeRPC(gossipMessages: gossips)
        let encoded = PlumtreeProtobuf.encode(rpc)
        let decoded = try PlumtreeProtobuf.decode(encoded)

        #expect(decoded.gossipMessages.count == 3)
        for (i, g) in decoded.gossipMessages.enumerated() {
            #expect(g.topic == "topic-\(i)")
            #expect(g.data == Data("msg-\(i)".utf8))
            #expect(g.hopCount == UInt32(i))
        }
    }

    @Test("Large payload roundtrip")
    func largePayloadRoundtrip() throws {
        let source = makePeerID()
        let largeData = Data(repeating: 0xAB, count: 100_000)
        let gossip = PlumtreeGossip(
            messageID: PlumtreeMessageID.compute(source: source, sequenceNumber: 1),
            topic: "large",
            data: largeData,
            source: source,
            hopCount: 0
        )

        let rpc = PlumtreeRPC(gossipMessages: [gossip])
        let encoded = PlumtreeProtobuf.encode(rpc)
        let decoded = try PlumtreeProtobuf.decode(encoded)

        #expect(decoded.gossipMessages.count == 1)
        #expect(decoded.gossipMessages[0].data.count == 100_000)
        #expect(decoded.gossipMessages[0].data == largeData)
    }
}
