/// GossipSubProtobuf - Wire format encoding/decoding for GossipSub protocol
import Foundation
import P2PCore

/// Protobuf encoding/decoding for GossipSub RPC messages.
///
/// Wire format follows the pubsub.proto specification:
/// https://github.com/libp2p/specs/blob/master/pubsub/README.md#the-rpc
public enum GossipSubProtobuf {

    // MARK: - Wire Type Constants

    private static let wireTypeVarint: UInt64 = 0
    private static let wireTypeLengthDelimited: UInt64 = 2

    // MARK: - RPC Tags (field number << 3 | wire type)

    private static let tagRPCSubscriptions: UInt8 = 0x0A   // field 1, wire type 2
    private static let tagRPCMessages: UInt8 = 0x12        // field 2, wire type 2
    private static let tagRPCControl: UInt8 = 0x1A         // field 3, wire type 2

    // MARK: - SubOpts Tags

    private static let tagSubOptsSubscribe: UInt8 = 0x08   // field 1, wire type 0 (bool/varint)
    private static let tagSubOptsTopic: UInt8 = 0x12       // field 2, wire type 2

    // MARK: - Message Tags

    private static let tagMessageFrom: UInt8 = 0x0A        // field 1, wire type 2
    private static let tagMessageData: UInt8 = 0x12        // field 2, wire type 2
    private static let tagMessageSeqno: UInt8 = 0x1A       // field 3, wire type 2
    private static let tagMessageTopic: UInt8 = 0x22       // field 4, wire type 2
    private static let tagMessageSignature: UInt8 = 0x2A   // field 5, wire type 2
    private static let tagMessageKey: UInt8 = 0x32         // field 6, wire type 2

    // MARK: - ControlMessage Tags

    private static let tagControlIHave: UInt8 = 0x0A       // field 1, wire type 2
    private static let tagControlIWant: UInt8 = 0x12       // field 2, wire type 2
    private static let tagControlGraft: UInt8 = 0x1A       // field 3, wire type 2
    private static let tagControlPrune: UInt8 = 0x22       // field 4, wire type 2
    private static let tagControlIDontWant: UInt8 = 0x2A  // field 5, wire type 2

    // MARK: - Control SubMessage Tags

    private static let tagIHaveTopic: UInt8 = 0x0A         // field 1, wire type 2
    private static let tagIHaveMessageIDs: UInt8 = 0x12    // field 2, wire type 2

    private static let tagIWantMessageIDs: UInt8 = 0x0A    // field 1, wire type 2

    private static let tagGraftTopic: UInt8 = 0x0A         // field 1, wire type 2

    private static let tagPruneTopic: UInt8 = 0x0A         // field 1, wire type 2
    private static let tagPrunePeers: UInt8 = 0x12         // field 2, wire type 2
    private static let tagPruneBackoff: UInt8 = 0x18       // field 3, wire type 0 (varint)

    private static let tagIDontWantMessageIDs: UInt8 = 0x0A // field 1, wire type 2

    private static let tagPeerInfoPeerID: UInt8 = 0x0A     // field 1, wire type 2
    private static let tagPeerInfoRecord: UInt8 = 0x12     // field 2, wire type 2

    // MARK: - Encoding

    /// Encodes a GossipSubRPC to protobuf wire format.
    public static func encode(_ rpc: GossipSubRPC) -> Data {
        // Estimate: subscriptions + messages + control overhead
        let estimatedSize = rpc.subscriptions.count * 32 + rpc.messages.count * 128 + 64
        var result = Data(capacity: estimatedSize)

        // Field 1: subscriptions (repeated SubOpts)
        for sub in rpc.subscriptions {
            let subData = encodeSubOpts(sub)
            result.append(tagRPCSubscriptions)
            Varint.encode(UInt64(subData.count), into: &result)
            result.append(subData)
        }

        // Field 2: publish (repeated Message)
        for message in rpc.messages {
            let msgData = encodeMessage(message)
            result.append(tagRPCMessages)
            Varint.encode(UInt64(msgData.count), into: &result)
            result.append(msgData)
        }

        // Field 3: control (optional ControlMessage)
        if let control = rpc.control, !control.isEmpty {
            let ctrlData = encodeControl(control)
            result.append(tagRPCControl)
            Varint.encode(UInt64(ctrlData.count), into: &result)
            result.append(ctrlData)
        }

        return result
    }

    private static func encodeSubOpts(_ sub: GossipSubRPC.SubscriptionOpt) -> Data {
        let topicBytes = sub.topic.utf8Bytes
        var result = Data(capacity: 4 + topicBytes.count)

        // Field 1: subscribe (bool as varint)
        result.append(tagSubOptsSubscribe)
        result.append(sub.subscribe ? 1 : 0)

        // Field 2: topicid (string)
        result.append(tagSubOptsTopic)
        Varint.encode(UInt64(topicBytes.count), into: &result)
        result.append(topicBytes)

        return result
    }

    private static func encodeMessage(_ message: GossipSubMessage) -> Data {
        let topicBytes = message.topic.utf8Bytes
        // Estimate: tag+varint overhead per field + actual data sizes
        let estimatedSize = 32 + message.data.count + message.sequenceNumber.count
            + topicBytes.count + (message.signature?.count ?? 0) + (message.key?.count ?? 0)
        var result = Data(capacity: estimatedSize)

        // Field 1: from (optional bytes)
        if let source = message.source {
            let sourceBytes = source.bytes
            result.append(tagMessageFrom)
            Varint.encode(UInt64(sourceBytes.count), into: &result)
            result.append(sourceBytes)
        }

        // Field 2: data (bytes)
        result.append(tagMessageData)
        Varint.encode(UInt64(message.data.count), into: &result)
        result.append(message.data)

        // Field 3: seqno (bytes)
        if !message.sequenceNumber.isEmpty {
            result.append(tagMessageSeqno)
            Varint.encode(UInt64(message.sequenceNumber.count), into: &result)
            result.append(message.sequenceNumber)
        }

        // Field 4: topic (string) - required
        result.append(tagMessageTopic)
        Varint.encode(UInt64(topicBytes.count), into: &result)
        result.append(topicBytes)

        // Field 5: signature (optional bytes)
        if let sig = message.signature {
            result.append(tagMessageSignature)
            Varint.encode(UInt64(sig.count), into: &result)
            result.append(sig)
        }

        // Field 6: key (optional bytes)
        if let key = message.key {
            result.append(tagMessageKey)
            Varint.encode(UInt64(key.count), into: &result)
            result.append(key)
        }

        return result
    }

    private static func encodeControl(_ control: ControlMessageBatch) -> Data {
        let estimatedSize = control.ihaves.count * 64 + control.iwants.count * 64
            + control.grafts.count * 32 + control.prunes.count * 48
            + control.idontwants.count * 64
        var result = Data(capacity: estimatedSize)

        // Field 1: ihave (repeated)
        for ihave in control.ihaves {
            let ihaveData = encodeIHave(ihave)
            result.append(tagControlIHave)
            Varint.encode(UInt64(ihaveData.count), into: &result)
            result.append(ihaveData)
        }

        // Field 2: iwant (repeated)
        for iwant in control.iwants {
            let iwantData = encodeIWant(iwant)
            result.append(tagControlIWant)
            Varint.encode(UInt64(iwantData.count), into: &result)
            result.append(iwantData)
        }

        // Field 3: graft (repeated)
        for graft in control.grafts {
            let graftData = encodeGraft(graft)
            result.append(tagControlGraft)
            Varint.encode(UInt64(graftData.count), into: &result)
            result.append(graftData)
        }

        // Field 4: prune (repeated)
        for prune in control.prunes {
            let pruneData = encodePrune(prune)
            result.append(tagControlPrune)
            Varint.encode(UInt64(pruneData.count), into: &result)
            result.append(pruneData)
        }

        // Field 5: idontwant (repeated, v1.2)
        for idontwant in control.idontwants {
            let idontwantData = encodeIDontWant(idontwant)
            result.append(tagControlIDontWant)
            Varint.encode(UInt64(idontwantData.count), into: &result)
            result.append(idontwantData)
        }

        return result
    }

    private static func encodeIHave(_ ihave: ControlMessage.IHave) -> Data {
        let topicBytes = ihave.topic.utf8Bytes
        // Estimate: tag+varint+topic + per-messageID (tag+varint+~32 bytes)
        var result = Data(capacity: 4 + topicBytes.count + ihave.messageIDs.count * 36)

        // Field 1: topicID (string)
        result.append(tagIHaveTopic)
        Varint.encode(UInt64(topicBytes.count), into: &result)
        result.append(topicBytes)

        // Field 2: messageIDs (repeated bytes)
        for msgID in ihave.messageIDs {
            result.append(tagIHaveMessageIDs)
            Varint.encode(UInt64(msgID.bytes.count), into: &result)
            result.append(msgID.bytes)
        }

        return result
    }

    private static func encodeIWant(_ iwant: ControlMessage.IWant) -> Data {
        // Estimate: per-messageID (tag+varint+~32 bytes)
        var result = Data(capacity: iwant.messageIDs.count * 36)

        // Field 1: messageIDs (repeated bytes)
        for msgID in iwant.messageIDs {
            result.append(tagIWantMessageIDs)
            Varint.encode(UInt64(msgID.bytes.count), into: &result)
            result.append(msgID.bytes)
        }

        return result
    }

    private static func encodeGraft(_ graft: ControlMessage.Graft) -> Data {
        let topicBytes = graft.topic.utf8Bytes
        var result = Data(capacity: 4 + topicBytes.count)

        // Field 1: topicID (string)
        result.append(tagGraftTopic)
        Varint.encode(UInt64(topicBytes.count), into: &result)
        result.append(topicBytes)

        return result
    }

    private static func encodePrune(_ prune: ControlMessage.Prune) -> Data {
        let topicBytes = prune.topic.utf8Bytes
        // Estimate: topic + peers + backoff
        var result = Data(capacity: 4 + topicBytes.count + prune.peers.count * 48 + 12)

        // Field 1: topicID (string)
        result.append(tagPruneTopic)
        Varint.encode(UInt64(topicBytes.count), into: &result)
        result.append(topicBytes)

        // Field 2: peers (repeated PeerInfo)
        for peer in prune.peers {
            let peerData = encodePeerInfo(peer)
            result.append(tagPrunePeers)
            Varint.encode(UInt64(peerData.count), into: &result)
            result.append(peerData)
        }

        // Field 3: backoff (optional uint64)
        if let backoff = prune.backoff {
            result.append(tagPruneBackoff)
            Varint.encode(backoff, into: &result)
        }

        return result
    }

    private static func encodePeerInfo(_ info: ControlMessage.Prune.PeerInfo) -> Data {
        var result = Data(capacity: 4 + info.peerID.bytes.count + (info.signedPeerRecord?.count ?? 0) + 4)

        // Field 1: peerID (bytes)
        result.append(tagPeerInfoPeerID)
        let peerIDBytes = info.peerID.bytes
        Varint.encode(UInt64(peerIDBytes.count), into: &result)
        result.append(peerIDBytes)

        // Field 2: signedPeerRecord (optional bytes)
        if let record = info.signedPeerRecord {
            result.append(tagPeerInfoRecord)
            Varint.encode(UInt64(record.count), into: &result)
            result.append(record)
        }

        return result
    }

    private static func encodeIDontWant(_ idontwant: ControlMessage.IDontWant) -> Data {
        // Estimate: per-messageID (tag+varint+~32 bytes)
        var result = Data(capacity: idontwant.messageIDs.count * 36)

        // Field 1: messageIDs (repeated bytes)
        for msgID in idontwant.messageIDs {
            result.append(tagIDontWantMessageIDs)
            Varint.encode(UInt64(msgID.bytes.count), into: &result)
            result.append(msgID.bytes)
        }

        return result
    }

    // MARK: - Decoding

    /// Decodes a GossipSubRPC from protobuf wire format.
    public static func decode(_ data: Data) throws -> GossipSubRPC {
        var subscriptions: [GossipSubRPC.SubscriptionOpt] = []
        var messages: [GossipSubMessage] = []
        var control: ControlMessageBatch?

        var offset = data.startIndex

        while offset < data.endIndex {
            let (tag, tagBytes) = try Varint.decode(Data(data[offset...]))
            offset += tagBytes

            let fieldNumber = tag >> 3
            let wireType = tag & 0x07

            guard wireType == wireTypeLengthDelimited else {
                offset = try skipField(in: data, at: offset, wireType: wireType)
                continue
            }

            let (length, lengthBytes) = try Varint.decode(Data(data[offset...]))
            offset += lengthBytes

            let fieldEnd = offset + Int(length)
            guard fieldEnd <= data.endIndex else {
                throw GossipSubError.invalidProtobuf("Field truncated")
            }

            let fieldData = Data(data[offset..<fieldEnd])
            offset = fieldEnd

            switch fieldNumber {
            case 1: // subscriptions
                let sub = try decodeSubOpts(fieldData)
                subscriptions.append(sub)

            case 2: // publish
                let msg = try decodeMessage(fieldData)
                messages.append(msg)

            case 3: // control
                control = try decodeControl(fieldData)

            default:
                break
            }
        }

        return GossipSubRPC(
            subscriptions: subscriptions,
            messages: messages,
            control: control
        )
    }

    private static func decodeSubOpts(_ data: Data) throws -> GossipSubRPC.SubscriptionOpt {
        var subscribe = false
        var topic: Topic?

        var offset = data.startIndex

        while offset < data.endIndex {
            let (tag, tagBytes) = try Varint.decode(Data(data[offset...]))
            offset += tagBytes

            let fieldNumber = tag >> 3
            let wireType = tag & 0x07

            switch fieldNumber {
            case 1: // subscribe (bool/varint)
                guard wireType == 0 else {
                    offset = try skipField(in: data, at: offset, wireType: wireType)
                    continue
                }
                let (value, valueBytes) = try Varint.decode(Data(data[offset...]))
                offset += valueBytes
                subscribe = value != 0

            case 2: // topicid (string)
                guard wireType == wireTypeLengthDelimited else {
                    offset = try skipField(in: data, at: offset, wireType: wireType)
                    continue
                }
                let (length, lengthBytes) = try Varint.decode(Data(data[offset...]))
                offset += lengthBytes
                let fieldEnd = offset + Int(length)
                if let str = String(data: Data(data[offset..<fieldEnd]), encoding: .utf8) {
                    topic = Topic(str)
                }
                offset = fieldEnd

            default:
                offset = try skipField(in: data, at: offset, wireType: wireType)
            }
        }

        guard let topic = topic else {
            throw GossipSubError.invalidProtobuf("Missing topic in SubOpts")
        }

        return GossipSubRPC.SubscriptionOpt(subscribe: subscribe, topic: topic)
    }

    private static func decodeMessage(_ data: Data) throws -> GossipSubMessage {
        var source: PeerID?
        var messageData = Data()
        var sequenceNumber = Data()
        var topic: Topic?
        var signature: Data?
        var key: Data?

        var offset = data.startIndex

        while offset < data.endIndex {
            let (tag, tagBytes) = try Varint.decode(Data(data[offset...]))
            offset += tagBytes

            let fieldNumber = tag >> 3
            let wireType = tag & 0x07

            guard wireType == wireTypeLengthDelimited else {
                offset = try skipField(in: data, at: offset, wireType: wireType)
                continue
            }

            let (length, lengthBytes) = try Varint.decode(Data(data[offset...]))
            offset += lengthBytes
            let fieldEnd = offset + Int(length)
            let fieldData = Data(data[offset..<fieldEnd])
            offset = fieldEnd

            switch fieldNumber {
            case 1: // from
                source = try PeerID(bytes: fieldData)

            case 2: // data
                messageData = fieldData

            case 3: // seqno
                sequenceNumber = fieldData

            case 4: // topic
                if let str = String(data: fieldData, encoding: .utf8) {
                    topic = Topic(str)
                }

            case 5: // signature
                signature = fieldData

            case 6: // key
                key = fieldData

            default:
                break
            }
        }

        guard let topic = topic else {
            throw GossipSubError.invalidProtobuf("Missing topic in Message")
        }

        return GossipSubMessage(
            source: source,
            data: messageData,
            sequenceNumber: sequenceNumber,
            topic: topic,
            signature: signature,
            key: key
        )
    }

    private static func decodeControl(_ data: Data) throws -> ControlMessageBatch {
        var batch = ControlMessageBatch()

        var offset = data.startIndex

        while offset < data.endIndex {
            let (tag, tagBytes) = try Varint.decode(Data(data[offset...]))
            offset += tagBytes

            let fieldNumber = tag >> 3
            let wireType = tag & 0x07

            guard wireType == wireTypeLengthDelimited else {
                offset = try skipField(in: data, at: offset, wireType: wireType)
                continue
            }

            let (length, lengthBytes) = try Varint.decode(Data(data[offset...]))
            offset += lengthBytes
            let fieldEnd = offset + Int(length)
            let fieldData = Data(data[offset..<fieldEnd])
            offset = fieldEnd

            switch fieldNumber {
            case 1: // ihave
                let ihave = try decodeIHave(fieldData)
                batch.ihaves.append(ihave)

            case 2: // iwant
                let iwant = try decodeIWant(fieldData)
                batch.iwants.append(iwant)

            case 3: // graft
                let graft = try decodeGraft(fieldData)
                batch.grafts.append(graft)

            case 4: // prune
                let prune = try decodePrune(fieldData)
                batch.prunes.append(prune)

            case 5: // idontwant (v1.2)
                let idontwant = try decodeIDontWant(fieldData)
                batch.idontwants.append(idontwant)

            default:
                break
            }
        }

        return batch
    }

    private static func decodeIHave(_ data: Data) throws -> ControlMessage.IHave {
        var topic: Topic?
        var messageIDs: [MessageID] = []

        var offset = data.startIndex

        while offset < data.endIndex {
            let (tag, tagBytes) = try Varint.decode(Data(data[offset...]))
            offset += tagBytes

            let fieldNumber = tag >> 3
            let wireType = tag & 0x07

            guard wireType == wireTypeLengthDelimited else {
                offset = try skipField(in: data, at: offset, wireType: wireType)
                continue
            }

            let (length, lengthBytes) = try Varint.decode(Data(data[offset...]))
            offset += lengthBytes
            let fieldEnd = offset + Int(length)
            let fieldData = Data(data[offset..<fieldEnd])
            offset = fieldEnd

            switch fieldNumber {
            case 1: // topicID
                if let str = String(data: fieldData, encoding: .utf8) {
                    topic = Topic(str)
                }

            case 2: // messageIDs
                messageIDs.append(MessageID(bytes: fieldData))

            default:
                break
            }
        }

        guard let topic = topic else {
            throw GossipSubError.invalidProtobuf("Missing topic in IHave")
        }

        return ControlMessage.IHave(topic: topic, messageIDs: messageIDs)
    }

    private static func decodeIWant(_ data: Data) throws -> ControlMessage.IWant {
        var messageIDs: [MessageID] = []

        var offset = data.startIndex

        while offset < data.endIndex {
            let (tag, tagBytes) = try Varint.decode(Data(data[offset...]))
            offset += tagBytes

            let fieldNumber = tag >> 3
            let wireType = tag & 0x07

            guard wireType == wireTypeLengthDelimited else {
                offset = try skipField(in: data, at: offset, wireType: wireType)
                continue
            }

            let (length, lengthBytes) = try Varint.decode(Data(data[offset...]))
            offset += lengthBytes
            let fieldEnd = offset + Int(length)
            let fieldData = Data(data[offset..<fieldEnd])
            offset = fieldEnd

            if fieldNumber == 1 {
                messageIDs.append(MessageID(bytes: fieldData))
            }
        }

        return ControlMessage.IWant(messageIDs: messageIDs)
    }

    private static func decodeGraft(_ data: Data) throws -> ControlMessage.Graft {
        var topic: Topic?

        var offset = data.startIndex

        while offset < data.endIndex {
            let (tag, tagBytes) = try Varint.decode(Data(data[offset...]))
            offset += tagBytes

            let fieldNumber = tag >> 3
            let wireType = tag & 0x07

            guard wireType == wireTypeLengthDelimited else {
                offset = try skipField(in: data, at: offset, wireType: wireType)
                continue
            }

            let (length, lengthBytes) = try Varint.decode(Data(data[offset...]))
            offset += lengthBytes
            let fieldEnd = offset + Int(length)
            let fieldData = Data(data[offset..<fieldEnd])
            offset = fieldEnd

            if fieldNumber == 1 {
                if let str = String(data: fieldData, encoding: .utf8) {
                    topic = Topic(str)
                }
            }
        }

        guard let topic = topic else {
            throw GossipSubError.invalidProtobuf("Missing topic in Graft")
        }

        return ControlMessage.Graft(topic: topic)
    }

    private static func decodePrune(_ data: Data) throws -> ControlMessage.Prune {
        var topic: Topic?
        var peers: [ControlMessage.Prune.PeerInfo] = []
        var backoff: UInt64?

        var offset = data.startIndex

        while offset < data.endIndex {
            let (tag, tagBytes) = try Varint.decode(Data(data[offset...]))
            offset += tagBytes

            let fieldNumber = tag >> 3
            let wireType = tag & 0x07

            switch fieldNumber {
            case 1: // topicID (string)
                guard wireType == wireTypeLengthDelimited else {
                    offset = try skipField(in: data, at: offset, wireType: wireType)
                    continue
                }
                let (length, lengthBytes) = try Varint.decode(Data(data[offset...]))
                offset += lengthBytes
                let fieldEnd = offset + Int(length)
                if let str = String(data: Data(data[offset..<fieldEnd]), encoding: .utf8) {
                    topic = Topic(str)
                }
                offset = fieldEnd

            case 2: // peers (repeated PeerInfo)
                guard wireType == wireTypeLengthDelimited else {
                    offset = try skipField(in: data, at: offset, wireType: wireType)
                    continue
                }
                let (length, lengthBytes) = try Varint.decode(Data(data[offset...]))
                offset += lengthBytes
                let fieldEnd = offset + Int(length)
                let peerInfo = try decodePeerInfo(Data(data[offset..<fieldEnd]))
                peers.append(peerInfo)
                offset = fieldEnd

            case 3: // backoff (uint64)
                guard wireType == 0 else {
                    offset = try skipField(in: data, at: offset, wireType: wireType)
                    continue
                }
                let (value, valueBytes) = try Varint.decode(Data(data[offset...]))
                offset += valueBytes
                backoff = value

            default:
                offset = try skipField(in: data, at: offset, wireType: wireType)
            }
        }

        guard let topic = topic else {
            throw GossipSubError.invalidProtobuf("Missing topic in Prune")
        }

        return ControlMessage.Prune(topic: topic, peers: peers, backoff: backoff)
    }

    private static func decodePeerInfo(_ data: Data) throws -> ControlMessage.Prune.PeerInfo {
        var peerID: PeerID?
        var signedPeerRecord: Data?

        var offset = data.startIndex

        while offset < data.endIndex {
            let (tag, tagBytes) = try Varint.decode(Data(data[offset...]))
            offset += tagBytes

            let fieldNumber = tag >> 3
            let wireType = tag & 0x07

            guard wireType == wireTypeLengthDelimited else {
                offset = try skipField(in: data, at: offset, wireType: wireType)
                continue
            }

            let (length, lengthBytes) = try Varint.decode(Data(data[offset...]))
            offset += lengthBytes
            let fieldEnd = offset + Int(length)
            let fieldData = Data(data[offset..<fieldEnd])
            offset = fieldEnd

            switch fieldNumber {
            case 1: // peerID
                peerID = try PeerID(bytes: fieldData)

            case 2: // signedPeerRecord
                signedPeerRecord = fieldData

            default:
                break
            }
        }

        guard let peerID = peerID else {
            throw GossipSubError.invalidProtobuf("Missing peerID in PeerInfo")
        }

        return ControlMessage.Prune.PeerInfo(peerID: peerID, signedPeerRecord: signedPeerRecord)
    }

    private static func decodeIDontWant(_ data: Data) throws -> ControlMessage.IDontWant {
        var messageIDs: [MessageID] = []

        var offset = data.startIndex

        while offset < data.endIndex {
            let (tag, tagBytes) = try Varint.decode(Data(data[offset...]))
            offset += tagBytes

            let fieldNumber = tag >> 3
            let wireType = tag & 0x07

            guard wireType == wireTypeLengthDelimited else {
                offset = try skipField(in: data, at: offset, wireType: wireType)
                continue
            }

            let (length, lengthBytes) = try Varint.decode(Data(data[offset...]))
            offset += lengthBytes
            let fieldEnd = offset + Int(length)
            let fieldData = Data(data[offset..<fieldEnd])
            offset = fieldEnd

            if fieldNumber == 1 {
                messageIDs.append(MessageID(bytes: fieldData))
            }
        }

        return ControlMessage.IDontWant(messageIDs: messageIDs)
    }

    // MARK: - Helpers

    private static func skipField(in data: Data, at offset: Int, wireType: UInt64) throws -> Int {
        var newOffset = offset
        switch wireType {
        case 0: // Varint
            let (_, bytes) = try Varint.decode(Data(data[newOffset...]))
            newOffset += bytes
        case 1: // 64-bit
            newOffset += 8
        case 2: // Length-delimited
            let (length, lengthBytes) = try Varint.decode(Data(data[newOffset...]))
            newOffset += lengthBytes + Int(length)
        case 5: // 32-bit
            newOffset += 4
        default:
            throw GossipSubError.invalidProtobuf("Unknown wire type \(wireType)")
        }
        return newOffset
    }
}
