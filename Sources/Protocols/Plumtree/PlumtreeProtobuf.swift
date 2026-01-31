/// PlumtreeProtobuf - Wire format encoding/decoding for Plumtree protocol
///
/// Hand-written protobuf following the same pattern as GossipSubProtobuf.
import Foundation
import P2PCore

/// Protobuf encoding/decoding for Plumtree RPC messages.
public enum PlumtreeProtobuf {

    // MARK: - Wire Type Constants

    private static let wireTypeVarint: UInt64 = 0
    private static let wireTypeLengthDelimited: UInt64 = 2

    // MARK: - RPC Tags (field number << 3 | wire type)

    private static let tagRPCGossip: UInt8 = 0x0A       // field 1, wire type 2
    private static let tagRPCIHave: UInt8 = 0x12         // field 2, wire type 2
    private static let tagRPCGraft: UInt8 = 0x1A         // field 3, wire type 2
    private static let tagRPCPrune: UInt8 = 0x22         // field 4, wire type 2

    // MARK: - Gossip Tags

    private static let tagGossipMessageID: UInt8 = 0x0A  // field 1, wire type 2
    private static let tagGossipTopic: UInt8 = 0x12      // field 2, wire type 2
    private static let tagGossipData: UInt8 = 0x1A       // field 3, wire type 2
    private static let tagGossipSource: UInt8 = 0x22     // field 4, wire type 2
    private static let tagGossipHopCount: UInt8 = 0x28   // field 5, wire type 0

    // MARK: - IHave Tags

    private static let tagIHaveMessageID: UInt8 = 0x0A   // field 1, wire type 2
    private static let tagIHaveTopic: UInt8 = 0x12       // field 2, wire type 2

    // MARK: - Graft Tags

    private static let tagGraftTopic: UInt8 = 0x0A       // field 1, wire type 2
    private static let tagGraftMessageID: UInt8 = 0x12   // field 2, wire type 2

    // MARK: - Prune Tags

    private static let tagPruneTopic: UInt8 = 0x0A       // field 1, wire type 2

    // MARK: - Encoding Helpers

    /// Writes a varint directly into the buffer, avoiding intermediate Data allocation.
    @inline(__always)
    private static func appendVarint(_ value: UInt64, to data: inout Data) {
        var n = value
        while n >= 0x80 {
            data.append(UInt8(n & 0x7F) | 0x80)
            n >>= 7
        }
        data.append(UInt8(n))
    }

    /// Writes a tag + length-delimited field into the buffer.
    @inline(__always)
    private static func appendLengthDelimited(tag: UInt8, bytes: Data, to data: inout Data) {
        data.append(tag)
        appendVarint(UInt64(bytes.count), to: &data)
        data.append(bytes)
    }

    // MARK: - Encoding

    /// Encodes a PlumtreeRPC to protobuf wire format.
    public static func encode(_ rpc: PlumtreeRPC) -> Data {
        var result = Data()

        for gossip in rpc.gossipMessages {
            let data = encodeGossip(gossip)
            result.append(tagRPCGossip)
            appendVarint(UInt64(data.count), to: &result)
            result.append(data)
        }

        for ihave in rpc.ihaveEntries {
            let data = encodeIHave(ihave)
            result.append(tagRPCIHave)
            appendVarint(UInt64(data.count), to: &result)
            result.append(data)
        }

        for graft in rpc.graftRequests {
            let data = encodeGraft(graft)
            result.append(tagRPCGraft)
            appendVarint(UInt64(data.count), to: &result)
            result.append(data)
        }

        for prune in rpc.pruneRequests {
            let data = encodePrune(prune)
            result.append(tagRPCPrune)
            appendVarint(UInt64(data.count), to: &result)
            result.append(data)
        }

        return result
    }

    private static func encodeGossip(_ gossip: PlumtreeGossip) -> Data {
        let topicBytes = Data(gossip.topic.utf8)
        var result = Data()
        result.reserveCapacity(
            gossip.messageID.bytes.count + topicBytes.count +
            gossip.data.count + gossip.source.bytes.count + 20
        )

        appendLengthDelimited(tag: tagGossipMessageID, bytes: gossip.messageID.bytes, to: &result)
        appendLengthDelimited(tag: tagGossipTopic, bytes: topicBytes, to: &result)
        appendLengthDelimited(tag: tagGossipData, bytes: gossip.data, to: &result)
        appendLengthDelimited(tag: tagGossipSource, bytes: gossip.source.bytes, to: &result)

        // Field 5: hop_count (varint)
        result.append(tagGossipHopCount)
        appendVarint(UInt64(gossip.hopCount), to: &result)

        return result
    }

    private static func encodeIHave(_ ihave: PlumtreeIHaveEntry) -> Data {
        let topicBytes = Data(ihave.topic.utf8)
        var result = Data()
        result.reserveCapacity(ihave.messageID.bytes.count + topicBytes.count + 6)

        appendLengthDelimited(tag: tagIHaveMessageID, bytes: ihave.messageID.bytes, to: &result)
        appendLengthDelimited(tag: tagIHaveTopic, bytes: topicBytes, to: &result)

        return result
    }

    private static func encodeGraft(_ graft: PlumtreeGraftRequest) -> Data {
        let topicBytes = Data(graft.topic.utf8)
        var result = Data()
        result.reserveCapacity(topicBytes.count + (graft.messageID?.bytes.count ?? 0) + 6)

        appendLengthDelimited(tag: tagGraftTopic, bytes: topicBytes, to: &result)

        if let msgID = graft.messageID {
            appendLengthDelimited(tag: tagGraftMessageID, bytes: msgID.bytes, to: &result)
        }

        return result
    }

    private static func encodePrune(_ prune: PlumtreePruneRequest) -> Data {
        let topicBytes = Data(prune.topic.utf8)
        var result = Data()
        result.reserveCapacity(topicBytes.count + 3)

        appendLengthDelimited(tag: tagPruneTopic, bytes: topicBytes, to: &result)

        return result
    }

    // MARK: - Decoding

    /// Decodes a PlumtreeRPC from protobuf wire format.
    ///
    /// Uses zero-copy varint decoding via `Varint.decode(from:at:)` and
    /// passes the original data buffer through to sub-decoders to avoid
    /// per-field Data copies on the hot path.
    public static func decode(_ data: Data) throws -> PlumtreeRPC {
        guard !data.isEmpty else {
            throw PlumtreeError.decodingFailed("Empty data")
        }

        var gossipMessages: [PlumtreeGossip] = []
        var ihaveEntries: [PlumtreeIHaveEntry] = []
        var graftRequests: [PlumtreeGraftRequest] = []
        var pruneRequests: [PlumtreePruneRequest] = []

        var offset = 0

        while offset < data.count {
            let (tag, tagBytes) = try Varint.decode(from: data, at: offset)
            offset += tagBytes

            let fieldNumber = tag >> 3
            let wireType = tag & 0x07

            guard wireType == wireTypeLengthDelimited else {
                offset = try skipField(in: data, at: offset, wireType: wireType)
                continue
            }

            let (length, lengthBytes) = try Varint.decode(from: data, at: offset)
            offset += lengthBytes

            let fieldEnd = offset + Int(length)
            guard fieldEnd <= data.count else {
                throw PlumtreeError.decodingFailed("Field truncated")
            }

            switch fieldNumber {
            case 1:
                let gossip = try decodeGossip(data, from: offset, to: fieldEnd)
                gossipMessages.append(gossip)
            case 2:
                let ihave = try decodeIHave(data, from: offset, to: fieldEnd)
                ihaveEntries.append(ihave)
            case 3:
                let graft = try decodeGraft(data, from: offset, to: fieldEnd)
                graftRequests.append(graft)
            case 4:
                let prune = try decodePrune(data, from: offset, to: fieldEnd)
                pruneRequests.append(prune)
            default:
                break
            }

            offset = fieldEnd
        }

        return PlumtreeRPC(
            gossipMessages: gossipMessages,
            ihaveEntries: ihaveEntries,
            graftRequests: graftRequests,
            pruneRequests: pruneRequests
        )
    }

    private static func decodeGossip(_ data: Data, from start: Int, to end: Int) throws -> PlumtreeGossip {
        var messageID: PlumtreeMessageID?
        var topic: String?
        var payload = Data()
        var source: PeerID?
        var hopCount: UInt32 = 0

        var offset = start

        while offset < end {
            let (tag, tagBytes) = try Varint.decode(from: data, at: offset)
            offset += tagBytes

            let fieldNumber = tag >> 3
            let wireType = tag & 0x07

            switch fieldNumber {
            case 1, 2, 3, 4: // length-delimited fields
                guard wireType == wireTypeLengthDelimited else {
                    offset = try skipField(in: data, at: offset, wireType: wireType)
                    continue
                }
                let (length, lengthBytes) = try Varint.decode(from: data, at: offset)
                offset += lengthBytes
                let fieldEnd = offset + Int(length)
                guard fieldEnd <= end else {
                    throw PlumtreeError.decodingFailed("Gossip field truncated")
                }

                let base = data.startIndex
                let fieldData = Data(data[(base + offset)..<(base + fieldEnd)])
                offset = fieldEnd

                switch fieldNumber {
                case 1: messageID = PlumtreeMessageID(bytes: fieldData)
                case 2:
                    guard let str = String(data: fieldData, encoding: .utf8) else {
                        throw PlumtreeError.decodingFailed("Invalid topic UTF-8")
                    }
                    topic = str
                case 3: payload = fieldData
                case 4: source = try PeerID(bytes: fieldData)
                default: break
                }

            case 5: // hop_count (varint)
                guard wireType == wireTypeVarint else {
                    offset = try skipField(in: data, at: offset, wireType: wireType)
                    continue
                }
                let (value, valueBytes) = try Varint.decode(from: data, at: offset)
                offset += valueBytes
                hopCount = UInt32(value)

            default:
                offset = try skipField(in: data, at: offset, wireType: wireType)
            }
        }

        guard let messageID else {
            throw PlumtreeError.decodingFailed("Missing message_id in Gossip")
        }
        guard let topic else {
            throw PlumtreeError.decodingFailed("Missing topic in Gossip")
        }
        guard let source else {
            throw PlumtreeError.decodingFailed("Missing source in Gossip")
        }

        return PlumtreeGossip(
            messageID: messageID,
            topic: topic,
            data: payload,
            source: source,
            hopCount: hopCount
        )
    }

    private static func decodeIHave(_ data: Data, from start: Int, to end: Int) throws -> PlumtreeIHaveEntry {
        var messageID: PlumtreeMessageID?
        var topic: String?

        var offset = start

        while offset < end {
            let (tag, tagBytes) = try Varint.decode(from: data, at: offset)
            offset += tagBytes

            let fieldNumber = tag >> 3
            let wireType = tag & 0x07

            guard wireType == wireTypeLengthDelimited else {
                offset = try skipField(in: data, at: offset, wireType: wireType)
                continue
            }

            let (length, lengthBytes) = try Varint.decode(from: data, at: offset)
            offset += lengthBytes
            let fieldEnd = offset + Int(length)
            guard fieldEnd <= end else {
                throw PlumtreeError.decodingFailed("IHave field truncated")
            }

            let base = data.startIndex
            let fieldData = Data(data[(base + offset)..<(base + fieldEnd)])
            offset = fieldEnd

            switch fieldNumber {
            case 1: messageID = PlumtreeMessageID(bytes: fieldData)
            case 2:
                guard let str = String(data: fieldData, encoding: .utf8) else {
                    throw PlumtreeError.decodingFailed("Invalid topic UTF-8")
                }
                topic = str
            default: break
            }
        }

        guard let messageID else {
            throw PlumtreeError.decodingFailed("Missing message_id in IHave")
        }
        guard let topic else {
            throw PlumtreeError.decodingFailed("Missing topic in IHave")
        }

        return PlumtreeIHaveEntry(messageID: messageID, topic: topic)
    }

    private static func decodeGraft(_ data: Data, from start: Int, to end: Int) throws -> PlumtreeGraftRequest {
        var topic: String?
        var messageID: PlumtreeMessageID?

        var offset = start

        while offset < end {
            let (tag, tagBytes) = try Varint.decode(from: data, at: offset)
            offset += tagBytes

            let fieldNumber = tag >> 3
            let wireType = tag & 0x07

            guard wireType == wireTypeLengthDelimited else {
                offset = try skipField(in: data, at: offset, wireType: wireType)
                continue
            }

            let (length, lengthBytes) = try Varint.decode(from: data, at: offset)
            offset += lengthBytes
            let fieldEnd = offset + Int(length)
            guard fieldEnd <= end else {
                throw PlumtreeError.decodingFailed("Graft field truncated")
            }

            let base = data.startIndex
            let fieldData = Data(data[(base + offset)..<(base + fieldEnd)])
            offset = fieldEnd

            switch fieldNumber {
            case 1:
                guard let str = String(data: fieldData, encoding: .utf8) else {
                    throw PlumtreeError.decodingFailed("Invalid topic UTF-8")
                }
                topic = str
            case 2: messageID = PlumtreeMessageID(bytes: fieldData)
            default: break
            }
        }

        guard let topic else {
            throw PlumtreeError.decodingFailed("Missing topic in Graft")
        }

        return PlumtreeGraftRequest(topic: topic, messageID: messageID)
    }

    private static func decodePrune(_ data: Data, from start: Int, to end: Int) throws -> PlumtreePruneRequest {
        var topic: String?

        var offset = start

        while offset < end {
            let (tag, tagBytes) = try Varint.decode(from: data, at: offset)
            offset += tagBytes

            let fieldNumber = tag >> 3
            let wireType = tag & 0x07

            guard wireType == wireTypeLengthDelimited else {
                offset = try skipField(in: data, at: offset, wireType: wireType)
                continue
            }

            let (length, lengthBytes) = try Varint.decode(from: data, at: offset)
            offset += lengthBytes
            let fieldEnd = offset + Int(length)
            guard fieldEnd <= end else {
                throw PlumtreeError.decodingFailed("Prune field truncated")
            }

            if fieldNumber == 1 {
                let base = data.startIndex
                let fieldData = Data(data[(base + offset)..<(base + fieldEnd)])
                guard let str = String(data: fieldData, encoding: .utf8) else {
                    throw PlumtreeError.decodingFailed("Invalid topic UTF-8")
                }
                topic = str
            }

            offset = fieldEnd
        }

        guard let topic else {
            throw PlumtreeError.decodingFailed("Missing topic in Prune")
        }

        return PlumtreePruneRequest(topic: topic)
    }

    // MARK: - Helpers

    private static func skipField(in data: Data, at offset: Int, wireType: UInt64) throws -> Int {
        switch wireType {
        case 0: // Varint
            let (_, bytes) = try Varint.decode(from: data, at: offset)
            return offset + bytes
        case 1: // 64-bit
            return offset + 8
        case 2: // Length-delimited
            let (length, lengthBytes) = try Varint.decode(from: data, at: offset)
            return offset + lengthBytes + Int(length)
        case 5: // 32-bit
            return offset + 4
        default:
            throw PlumtreeError.decodingFailed("Unknown wire type \(wireType)")
        }
    }
}
