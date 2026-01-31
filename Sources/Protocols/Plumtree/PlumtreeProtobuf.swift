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

    // MARK: - Encoding

    /// Encodes a PlumtreeRPC to protobuf wire format.
    public static func encode(_ rpc: PlumtreeRPC) -> Data {
        var result = Data()

        for gossip in rpc.gossipMessages {
            let data = encodeGossip(gossip)
            result.append(tagRPCGossip)
            result.append(contentsOf: Varint.encode(UInt64(data.count)))
            result.append(data)
        }

        for ihave in rpc.ihaveEntries {
            let data = encodeIHave(ihave)
            result.append(tagRPCIHave)
            result.append(contentsOf: Varint.encode(UInt64(data.count)))
            result.append(data)
        }

        for graft in rpc.graftRequests {
            let data = encodeGraft(graft)
            result.append(tagRPCGraft)
            result.append(contentsOf: Varint.encode(UInt64(data.count)))
            result.append(data)
        }

        for prune in rpc.pruneRequests {
            let data = encodePrune(prune)
            result.append(tagRPCPrune)
            result.append(contentsOf: Varint.encode(UInt64(data.count)))
            result.append(data)
        }

        return result
    }

    private static func encodeGossip(_ gossip: PlumtreeGossip) -> Data {
        var result = Data()

        // Field 1: message_id
        result.append(tagGossipMessageID)
        result.append(contentsOf: Varint.encode(UInt64(gossip.messageID.bytes.count)))
        result.append(gossip.messageID.bytes)

        // Field 2: topic
        let topicBytes = Data(gossip.topic.utf8)
        result.append(tagGossipTopic)
        result.append(contentsOf: Varint.encode(UInt64(topicBytes.count)))
        result.append(topicBytes)

        // Field 3: data
        result.append(tagGossipData)
        result.append(contentsOf: Varint.encode(UInt64(gossip.data.count)))
        result.append(gossip.data)

        // Field 4: source
        result.append(tagGossipSource)
        result.append(contentsOf: Varint.encode(UInt64(gossip.source.bytes.count)))
        result.append(gossip.source.bytes)

        // Field 5: hop_count
        result.append(tagGossipHopCount)
        result.append(contentsOf: Varint.encode(UInt64(gossip.hopCount)))

        return result
    }

    private static func encodeIHave(_ ihave: PlumtreeIHaveEntry) -> Data {
        var result = Data()

        // Field 1: message_id
        result.append(tagIHaveMessageID)
        result.append(contentsOf: Varint.encode(UInt64(ihave.messageID.bytes.count)))
        result.append(ihave.messageID.bytes)

        // Field 2: topic
        let topicBytes = Data(ihave.topic.utf8)
        result.append(tagIHaveTopic)
        result.append(contentsOf: Varint.encode(UInt64(topicBytes.count)))
        result.append(topicBytes)

        return result
    }

    private static func encodeGraft(_ graft: PlumtreeGraftRequest) -> Data {
        var result = Data()

        // Field 1: topic
        let topicBytes = Data(graft.topic.utf8)
        result.append(tagGraftTopic)
        result.append(contentsOf: Varint.encode(UInt64(topicBytes.count)))
        result.append(topicBytes)

        // Field 2: message_id (optional)
        if let msgID = graft.messageID {
            result.append(tagGraftMessageID)
            result.append(contentsOf: Varint.encode(UInt64(msgID.bytes.count)))
            result.append(msgID.bytes)
        }

        return result
    }

    private static func encodePrune(_ prune: PlumtreePruneRequest) -> Data {
        var result = Data()

        // Field 1: topic
        let topicBytes = Data(prune.topic.utf8)
        result.append(tagPruneTopic)
        result.append(contentsOf: Varint.encode(UInt64(topicBytes.count)))
        result.append(topicBytes)

        return result
    }

    // MARK: - Decoding

    /// Decodes a PlumtreeRPC from protobuf wire format.
    public static func decode(_ data: Data) throws -> PlumtreeRPC {
        guard !data.isEmpty else {
            throw PlumtreeError.decodingFailed("Empty data")
        }

        var gossipMessages: [PlumtreeGossip] = []
        var ihaveEntries: [PlumtreeIHaveEntry] = []
        var graftRequests: [PlumtreeGraftRequest] = []
        var pruneRequests: [PlumtreePruneRequest] = []

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
                throw PlumtreeError.decodingFailed("Field truncated")
            }

            let fieldData = Data(data[offset..<fieldEnd])
            offset = fieldEnd

            switch fieldNumber {
            case 1:
                let gossip = try decodeGossip(fieldData)
                gossipMessages.append(gossip)
            case 2:
                let ihave = try decodeIHave(fieldData)
                ihaveEntries.append(ihave)
            case 3:
                let graft = try decodeGraft(fieldData)
                graftRequests.append(graft)
            case 4:
                let prune = try decodePrune(fieldData)
                pruneRequests.append(prune)
            default:
                break
            }
        }

        return PlumtreeRPC(
            gossipMessages: gossipMessages,
            ihaveEntries: ihaveEntries,
            graftRequests: graftRequests,
            pruneRequests: pruneRequests
        )
    }

    private static func decodeGossip(_ data: Data) throws -> PlumtreeGossip {
        var messageID: PlumtreeMessageID?
        var topic: String?
        var payload = Data()
        var source: PeerID?
        var hopCount: UInt32 = 0

        var offset = data.startIndex

        while offset < data.endIndex {
            let (tag, tagBytes) = try Varint.decode(Data(data[offset...]))
            offset += tagBytes

            let fieldNumber = tag >> 3
            let wireType = tag & 0x07

            switch fieldNumber {
            case 1, 2, 3, 4: // length-delimited fields
                guard wireType == wireTypeLengthDelimited else {
                    offset = try skipField(in: data, at: offset, wireType: wireType)
                    continue
                }
                let (length, lengthBytes) = try Varint.decode(Data(data[offset...]))
                offset += lengthBytes
                let fieldEnd = offset + Int(length)
                guard fieldEnd <= data.endIndex else {
                    throw PlumtreeError.decodingFailed("Gossip field truncated")
                }
                let fieldData = Data(data[offset..<fieldEnd])
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
                let (value, valueBytes) = try Varint.decode(Data(data[offset...]))
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

    private static func decodeIHave(_ data: Data) throws -> PlumtreeIHaveEntry {
        var messageID: PlumtreeMessageID?
        var topic: String?

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
                throw PlumtreeError.decodingFailed("IHave field truncated")
            }
            let fieldData = Data(data[offset..<fieldEnd])
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

    private static func decodeGraft(_ data: Data) throws -> PlumtreeGraftRequest {
        var topic: String?
        var messageID: PlumtreeMessageID?

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
                throw PlumtreeError.decodingFailed("Graft field truncated")
            }
            let fieldData = Data(data[offset..<fieldEnd])
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

    private static func decodePrune(_ data: Data) throws -> PlumtreePruneRequest {
        var topic: String?

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
                throw PlumtreeError.decodingFailed("Prune field truncated")
            }
            let fieldData = Data(data[offset..<fieldEnd])
            offset = fieldEnd

            if fieldNumber == 1 {
                guard let str = String(data: fieldData, encoding: .utf8) else {
                    throw PlumtreeError.decodingFailed("Invalid topic UTF-8")
                }
                topic = str
            }
        }

        guard let topic else {
            throw PlumtreeError.decodingFailed("Missing topic in Prune")
        }

        return PlumtreePruneRequest(topic: topic)
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
            throw PlumtreeError.decodingFailed("Unknown wire type \(wireType)")
        }
        return newOffset
    }
}
