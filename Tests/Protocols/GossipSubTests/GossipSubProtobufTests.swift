/// GossipSubProtobufTests - Tests for GossipSub Protobuf encoding/decoding
import Testing
import Foundation
@testable import P2PGossipSub
@testable import P2PCore

@Suite("GossipSub Protobuf Tests")
struct GossipSubProtobufTests {

    // MARK: - RPC Encoding/Decoding

    @Test("Encode and decode empty RPC")
    func encodeDecodeEmptyRPC() throws {
        let rpc = GossipSubRPC()
        let encoded = GossipSubProtobuf.encode(rpc)
        let decoded = try GossipSubProtobuf.decode(encoded)

        #expect(decoded.subscriptions.isEmpty)
        #expect(decoded.messages.isEmpty)
        #expect(decoded.control == nil || decoded.control?.isEmpty == true)
    }

    @Test("Encode and decode subscription")
    func encodeDecodeSubscription() throws {
        let topic = Topic("test-topic")
        var rpc = GossipSubRPC()
        rpc.subscriptions.append(.subscribe(to: topic))

        let encoded = GossipSubProtobuf.encode(rpc)
        let decoded = try GossipSubProtobuf.decode(encoded)

        #expect(decoded.subscriptions.count == 1)
        #expect(decoded.subscriptions[0].subscribe == true)
        #expect(decoded.subscriptions[0].topic == topic)
    }

    @Test("Encode and decode unsubscription")
    func encodeDecodeUnsubscription() throws {
        let topic = Topic("test-topic")
        var rpc = GossipSubRPC()
        rpc.subscriptions.append(.unsubscribe(from: topic))

        let encoded = GossipSubProtobuf.encode(rpc)
        let decoded = try GossipSubProtobuf.decode(encoded)

        #expect(decoded.subscriptions.count == 1)
        #expect(decoded.subscriptions[0].subscribe == false)
        #expect(decoded.subscriptions[0].topic == topic)
    }

    @Test("Encode and decode message")
    func encodeDecodeMessage() throws {
        let topic = Topic("test-topic")
        let data = Data("Hello, World!".utf8)
        let seqno = Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])

        let message = GossipSubMessage(
            source: nil,
            data: data,
            sequenceNumber: seqno,
            topic: topic
        )

        var rpc = GossipSubRPC()
        rpc.messages.append(message)

        let encoded = GossipSubProtobuf.encode(rpc)
        let decoded = try GossipSubProtobuf.decode(encoded)

        #expect(decoded.messages.count == 1)
        #expect(decoded.messages[0].topic == topic)
        #expect(decoded.messages[0].data == data)
        #expect(decoded.messages[0].sequenceNumber == seqno)
    }

    // MARK: - Control Message Tests

    @Test("Encode and decode GRAFT")
    func encodeDecodeGraft() throws {
        let topic = Topic("test-topic")
        var control = ControlMessageBatch()
        control.grafts.append(ControlMessage.Graft(topic: topic))

        let rpc = GossipSubRPC(control: control)
        let encoded = GossipSubProtobuf.encode(rpc)
        let decoded = try GossipSubProtobuf.decode(encoded)

        #expect(decoded.control?.grafts.count == 1)
        #expect(decoded.control?.grafts[0].topic == topic)
    }

    @Test("Encode and decode PRUNE with backoff")
    func encodeDecodePruneWithBackoff() throws {
        let topic = Topic("test-topic")
        var control = ControlMessageBatch()
        control.prunes.append(ControlMessage.Prune(topic: topic, backoff: 60))

        let rpc = GossipSubRPC(control: control)
        let encoded = GossipSubProtobuf.encode(rpc)
        let decoded = try GossipSubProtobuf.decode(encoded)

        #expect(decoded.control?.prunes.count == 1)
        #expect(decoded.control?.prunes[0].topic == topic)
        #expect(decoded.control?.prunes[0].backoff == 60)
    }

    @Test("Encode and decode IHAVE")
    func encodeDecodeIHave() throws {
        let topic = Topic("test-topic")
        let msgID1 = MessageID(bytes: Data([0x01, 0x02, 0x03]))
        let msgID2 = MessageID(bytes: Data([0x04, 0x05, 0x06]))

        var control = ControlMessageBatch()
        control.ihaves.append(ControlMessage.IHave(topic: topic, messageIDs: [msgID1, msgID2]))

        let rpc = GossipSubRPC(control: control)
        let encoded = GossipSubProtobuf.encode(rpc)
        let decoded = try GossipSubProtobuf.decode(encoded)

        #expect(decoded.control?.ihaves.count == 1)
        #expect(decoded.control?.ihaves[0].topic == topic)
        #expect(decoded.control?.ihaves[0].messageIDs.count == 2)
        #expect(decoded.control?.ihaves[0].messageIDs[0] == msgID1)
        #expect(decoded.control?.ihaves[0].messageIDs[1] == msgID2)
    }

    @Test("Encode and decode IWANT")
    func encodeDecodeIWant() throws {
        let msgID1 = MessageID(bytes: Data([0x01, 0x02, 0x03]))
        let msgID2 = MessageID(bytes: Data([0x04, 0x05, 0x06]))

        var control = ControlMessageBatch()
        control.iwants.append(ControlMessage.IWant(messageIDs: [msgID1, msgID2]))

        let rpc = GossipSubRPC(control: control)
        let encoded = GossipSubProtobuf.encode(rpc)
        let decoded = try GossipSubProtobuf.decode(encoded)

        #expect(decoded.control?.iwants.count == 1)
        #expect(decoded.control?.iwants[0].messageIDs.count == 2)
    }

    @Test("Encode and decode IDONTWANT")
    func encodeDecodeIDontWant() throws {
        let msgID1 = MessageID(bytes: Data([0x01, 0x02, 0x03]))
        let msgID2 = MessageID(bytes: Data([0x04, 0x05, 0x06]))

        var control = ControlMessageBatch()
        control.idontwants.append(ControlMessage.IDontWant(messageIDs: [msgID1, msgID2]))

        let rpc = GossipSubRPC(control: control)
        let encoded = GossipSubProtobuf.encode(rpc)
        let decoded = try GossipSubProtobuf.decode(encoded)

        #expect(decoded.control?.idontwants.count == 1)
        #expect(decoded.control?.idontwants[0].messageIDs.count == 2)
        #expect(decoded.control?.idontwants[0].messageIDs[0] == msgID1)
        #expect(decoded.control?.idontwants[0].messageIDs[1] == msgID2)
    }

    @Test("Encode and decode multiple IDONTWANTs in batch")
    func encodeDecodeMultipleIDontWants() throws {
        let msgID1 = MessageID(bytes: Data([0x01, 0x02]))
        let msgID2 = MessageID(bytes: Data([0x03, 0x04]))
        let msgID3 = MessageID(bytes: Data([0x05, 0x06]))

        var control = ControlMessageBatch()
        control.idontwants.append(ControlMessage.IDontWant(messageIDs: [msgID1]))
        control.idontwants.append(ControlMessage.IDontWant(messageIDs: [msgID2, msgID3]))

        let rpc = GossipSubRPC(control: control)
        let encoded = GossipSubProtobuf.encode(rpc)
        let decoded = try GossipSubProtobuf.decode(encoded)

        #expect(decoded.control?.idontwants.count == 2)
        #expect(decoded.control?.idontwants[0].messageIDs.count == 1)
        #expect(decoded.control?.idontwants[0].messageIDs[0] == msgID1)
        #expect(decoded.control?.idontwants[1].messageIDs.count == 2)
    }

    @Test("Encode and decode IDONTWANT with empty messageIDs")
    func encodeDecodeIDontWantEmpty() throws {
        var control = ControlMessageBatch()
        control.idontwants.append(ControlMessage.IDontWant(messageIDs: []))

        let rpc = GossipSubRPC(control: control)
        let encoded = GossipSubProtobuf.encode(rpc)
        let decoded = try GossipSubProtobuf.decode(encoded)

        #expect(decoded.control?.idontwants.count == 1)
        #expect(decoded.control?.idontwants[0].messageIDs.isEmpty == true)
    }

    // MARK: - Complex RPC Tests

    @Test("Encode and decode complex RPC with all fields")
    func encodeDecodeComplexRPC() throws {
        let topic1 = Topic("topic-1")
        let topic2 = Topic("topic-2")
        let data = Data("test message".utf8)
        let seqno = Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])

        var rpc = GossipSubRPC()
        rpc.subscriptions.append(.subscribe(to: topic1))
        rpc.subscriptions.append(.unsubscribe(from: topic2))
        rpc.messages.append(GossipSubMessage(
            source: nil,
            data: data,
            sequenceNumber: seqno,
            topic: topic1
        ))

        var control = ControlMessageBatch()
        control.grafts.append(ControlMessage.Graft(topic: topic1))
        control.prunes.append(ControlMessage.Prune(topic: topic2, backoff: 30))
        control.ihaves.append(ControlMessage.IHave(
            topic: topic1,
            messageIDs: [MessageID(bytes: Data([0xAA, 0xBB]))]
        ))
        control.iwants.append(ControlMessage.IWant(
            messageIDs: [MessageID(bytes: Data([0xCC, 0xDD]))]
        ))
        control.idontwants.append(ControlMessage.IDontWant(
            messageIDs: [MessageID(bytes: Data([0xEE, 0xFF]))]
        ))
        rpc.control = control

        let encoded = GossipSubProtobuf.encode(rpc)
        let decoded = try GossipSubProtobuf.decode(encoded)

        #expect(decoded.subscriptions.count == 2)
        #expect(decoded.messages.count == 1)
        #expect(decoded.control?.grafts.count == 1)
        #expect(decoded.control?.prunes.count == 1)
        #expect(decoded.control?.ihaves.count == 1)
        #expect(decoded.control?.iwants.count == 1)
        #expect(decoded.control?.idontwants.count == 1)
        #expect(decoded.control?.idontwants[0].messageIDs[0] == MessageID(bytes: Data([0xEE, 0xFF])))
    }
}
