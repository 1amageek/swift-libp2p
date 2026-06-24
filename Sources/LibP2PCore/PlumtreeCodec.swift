/// Plumtree RPC message codec (Embedded-clean).
///
/// Hand-written protobuf following the same pattern as the GossipSub codec.
///
/// Embedded-clean: no Foundation, no NIO, no `any`. This is the Plumtree RPC
/// protobuf wire codec over `[UInt8]`, expressed as raw value fields:
///
/// ```protobuf
/// message RPC {
///   repeated Gossip gossip = 1; repeated IHave ihave = 2;
///   repeated Graft graft = 3;  repeated Prune prune = 4;
/// }
/// message Gossip { bytes message_id = 1; string topic = 2; bytes data = 3; bytes source = 4; uint32 hop_count = 5; }
/// message IHave  { bytes message_id = 1; string topic = 2; }
/// message Graft  { string topic = 1; bytes message_id = 2; }
/// message Prune  { string topic = 1; }
/// ```
///
/// The domain types — `PlumtreeMessageID` (from `message_id` bytes) and `PeerID`
/// (from `source` bytes) — are reconstructed in the `P2PPlumtree` adapter; only
/// the byte framing lives here. Faithful transcription of the historical
/// hand-rolled protobuf path: field numbers/types preserved, plus the 0.2.0
/// `maxElements` cap, the required-field invariants, the strict-UTF-8 topic
/// rejection, and the hop-count saturation.

/// A gossip payload (raw byte fields).
public struct PlumtreeGossipFields: Sendable, Equatable {
    public var messageID: [UInt8]
    public var topic: String
    public var data: [UInt8]
    public var source: [UInt8]
    public var hopCount: UInt32

    public init(messageID: [UInt8], topic: String, data: [UInt8], source: [UInt8], hopCount: UInt32) {
        self.messageID = messageID
        self.topic = topic
        self.data = data
        self.source = source
        self.hopCount = hopCount
    }
}

/// An IHAVE entry (raw fields).
public struct PlumtreeIHaveFields: Sendable, Equatable {
    public var messageID: [UInt8]
    public var topic: String

    public init(messageID: [UInt8], topic: String) {
        self.messageID = messageID
        self.topic = topic
    }
}

/// A GRAFT request (raw fields).
public struct PlumtreeGraftFields: Sendable, Equatable {
    public var topic: String
    public var messageID: [UInt8]?

    public init(topic: String, messageID: [UInt8]? = nil) {
        self.topic = topic
        self.messageID = messageID
    }
}

/// A PRUNE request (raw fields).
public struct PlumtreePruneFields: Sendable, Equatable {
    public var topic: String

    public init(topic: String) {
        self.topic = topic
    }
}

/// The decoded raw fields of a Plumtree RPC.
public struct PlumtreeRPCFields: Sendable, Equatable {
    public var gossipMessages: [PlumtreeGossipFields]
    public var ihaveEntries: [PlumtreeIHaveFields]
    public var graftRequests: [PlumtreeGraftFields]
    public var pruneRequests: [PlumtreePruneFields]

    public init(
        gossipMessages: [PlumtreeGossipFields] = [],
        ihaveEntries: [PlumtreeIHaveFields] = [],
        graftRequests: [PlumtreeGraftFields] = [],
        pruneRequests: [PlumtreePruneFields] = []
    ) {
        self.gossipMessages = gossipMessages
        self.ihaveEntries = ihaveEntries
        self.graftRequests = graftRequests
        self.pruneRequests = pruneRequests
    }

    // MARK: - Field tags

    @usableFromInline static let tagRPCGossip: UInt8 = 0x0A   // field 1, wt 2
    @usableFromInline static let tagRPCIHave: UInt8 = 0x12     // field 2, wt 2
    @usableFromInline static let tagRPCGraft: UInt8 = 0x1A     // field 3, wt 2
    @usableFromInline static let tagRPCPrune: UInt8 = 0x22     // field 4, wt 2

    @usableFromInline static let tagGossipMessageID: UInt8 = 0x0A // field 1, wt 2
    @usableFromInline static let tagGossipTopic: UInt8 = 0x12     // field 2, wt 2
    @usableFromInline static let tagGossipData: UInt8 = 0x1A      // field 3, wt 2
    @usableFromInline static let tagGossipSource: UInt8 = 0x22    // field 4, wt 2
    @usableFromInline static let tagGossipHopCount: UInt8 = 0x28  // field 5, wt 0

    @usableFromInline static let tagIHaveMessageID: UInt8 = 0x0A  // field 1, wt 2
    @usableFromInline static let tagIHaveTopic: UInt8 = 0x12      // field 2, wt 2

    @usableFromInline static let tagGraftTopic: UInt8 = 0x0A      // field 1, wt 2
    @usableFromInline static let tagGraftMessageID: UInt8 = 0x12  // field 2, wt 2

    @usableFromInline static let tagPruneTopic: UInt8 = 0x0A      // field 1, wt 2

    // MARK: - Encoding

    /// Encodes the RPC fields to Plumtree protobuf wire format.
    public func encode() -> [UInt8] {
        var out = [UInt8]()
        for gossip in gossipMessages {
            appendLD(&out, tag: PlumtreeRPCFields.tagRPCGossip, bytes: PlumtreeRPCFields.encodeGossip(gossip))
        }
        for ihave in ihaveEntries {
            appendLD(&out, tag: PlumtreeRPCFields.tagRPCIHave, bytes: PlumtreeRPCFields.encodeIHave(ihave))
        }
        for graft in graftRequests {
            appendLD(&out, tag: PlumtreeRPCFields.tagRPCGraft, bytes: PlumtreeRPCFields.encodeGraft(graft))
        }
        for prune in pruneRequests {
            appendLD(&out, tag: PlumtreeRPCFields.tagRPCPrune, bytes: PlumtreeRPCFields.encodePrune(prune))
        }
        return out
    }

    @inline(__always)
    private func appendLD(_ out: inout [UInt8], tag: UInt8, bytes: [UInt8]) {
        PlumtreeRPCFields.appendLD(&out, tag: tag, bytes: bytes)
    }

    @inline(__always)
    static func appendLD(_ out: inout [UInt8], tag: UInt8, bytes: [UInt8]) {
        out.append(tag)
        out.append(contentsOf: Varint.encodeBytes(UInt64(bytes.count)))
        out.append(contentsOf: bytes)
    }

    private static func encodeGossip(_ gossip: PlumtreeGossipFields) -> [UInt8] {
        var out = [UInt8]()
        appendLD(&out, tag: tagGossipMessageID, bytes: gossip.messageID)
        appendLD(&out, tag: tagGossipTopic, bytes: [UInt8](gossip.topic.utf8))
        appendLD(&out, tag: tagGossipData, bytes: gossip.data)
        appendLD(&out, tag: tagGossipSource, bytes: gossip.source)
        out.append(tagGossipHopCount)
        out.append(contentsOf: Varint.encodeBytes(UInt64(gossip.hopCount)))
        return out
    }

    private static func encodeIHave(_ ihave: PlumtreeIHaveFields) -> [UInt8] {
        var out = [UInt8]()
        appendLD(&out, tag: tagIHaveMessageID, bytes: ihave.messageID)
        appendLD(&out, tag: tagIHaveTopic, bytes: [UInt8](ihave.topic.utf8))
        return out
    }

    private static func encodeGraft(_ graft: PlumtreeGraftFields) -> [UInt8] {
        var out = [UInt8]()
        appendLD(&out, tag: tagGraftTopic, bytes: [UInt8](graft.topic.utf8))
        if let msgID = graft.messageID {
            appendLD(&out, tag: tagGraftMessageID, bytes: msgID)
        }
        return out
    }

    private static func encodePrune(_ prune: PlumtreePruneFields) -> [UInt8] {
        var out = [UInt8]()
        appendLD(&out, tag: tagPruneTopic, bytes: [UInt8](prune.topic.utf8))
        return out
    }

    // MARK: - Decoding

    /// Maximum number of elements (per repeated field) accepted in a single RPC.
    ///
    /// Bounds the work an attacker can force per message and the fan-out of a
    /// single forwarded RPC, mitigating decode/forwarding amplification.
    public static let maxElementsPerRPC = 1024

    /// Decodes a Plumtree RPC from protobuf wire format.
    ///
    /// - Throws: `PlumtreeCodecError` on empty input, truncated framing,
    ///   exceeding `maxElementsPerRPC`, missing required fields, or a topic that
    ///   is not valid UTF-8.
    public static func decode(from bytes: [UInt8]) throws(PlumtreeCodecError) -> PlumtreeRPCFields {
        guard !bytes.isEmpty else {
            throw .empty
        }

        var gossipMessages: [PlumtreeGossipFields] = []
        var ihaveEntries: [PlumtreeIHaveFields] = []
        var graftRequests: [PlumtreeGraftFields] = []
        var pruneRequests: [PlumtreePruneFields] = []

        var offset = 0
        while offset < bytes.count {
            let (fieldNumber, wireType) = try readTag(bytes, at: &offset)
            guard wireType == 2 else {
                offset = try skip(bytes, at: offset, wireType: wireType, limit: bytes.count)
                continue
            }
            let fieldEnd = try readLength(bytes, at: &offset, limit: bytes.count)

            switch fieldNumber {
            case 1:
                guard gossipMessages.count < maxElementsPerRPC else {
                    throw .tooManyElements
                }
                gossipMessages.append(try decodeGossip(bytes, from: offset, to: fieldEnd))
            case 2:
                guard ihaveEntries.count < maxElementsPerRPC else {
                    throw .tooManyElements
                }
                ihaveEntries.append(try decodeIHave(bytes, from: offset, to: fieldEnd))
            case 3:
                guard graftRequests.count < maxElementsPerRPC else {
                    throw .tooManyElements
                }
                graftRequests.append(try decodeGraft(bytes, from: offset, to: fieldEnd))
            case 4:
                guard pruneRequests.count < maxElementsPerRPC else {
                    throw .tooManyElements
                }
                pruneRequests.append(try decodePrune(bytes, from: offset, to: fieldEnd))
            default:
                break
            }
            offset = fieldEnd
        }

        return PlumtreeRPCFields(
            gossipMessages: gossipMessages,
            ihaveEntries: ihaveEntries,
            graftRequests: graftRequests,
            pruneRequests: pruneRequests
        )
    }

    private static func decodeGossip(
        _ bytes: [UInt8], from start: Int, to end: Int
    ) throws(PlumtreeCodecError) -> PlumtreeGossipFields {
        var messageID: [UInt8]?
        var topic: String?
        var data: [UInt8] = []
        var source: [UInt8]?
        var hopCount: UInt32 = 0

        var offset = start
        while offset < end {
            let (fieldNumber, wireType) = try readTag(bytes, at: &offset)
            switch fieldNumber {
            case 1, 2, 3, 4:
                guard wireType == 2 else {
                    offset = try skip(bytes, at: offset, wireType: wireType, limit: end)
                    continue
                }
                let fieldEnd = try readLength(bytes, at: &offset, limit: end)
                let value = Array(bytes[offset..<fieldEnd])
                offset = fieldEnd
                switch fieldNumber {
                case 1: messageID = value
                case 2:
                    guard let str = decodeUTF8Strict(value) else {
                        throw .invalidTopicUTF8
                    }
                    topic = str
                case 3: data = value
                case 4: source = value
                default: break
                }
            case 5:
                guard wireType == 0 else {
                    offset = try skip(bytes, at: offset, wireType: wireType, limit: end)
                    continue
                }
                let value = try readVarint(bytes, at: &offset)
                // Saturate rather than trap on an attacker-supplied oversized value.
                hopCount = value > UInt64(UInt32.max) ? UInt32.max : UInt32(value)
            default:
                offset = try skip(bytes, at: offset, wireType: wireType, limit: end)
            }
        }

        guard let messageID else {
            throw .missingField
        }
        guard let topic else {
            throw .missingField
        }
        guard let source else {
            throw .missingField
        }
        return PlumtreeGossipFields(messageID: messageID, topic: topic, data: data, source: source, hopCount: hopCount)
    }

    private static func decodeIHave(
        _ bytes: [UInt8], from start: Int, to end: Int
    ) throws(PlumtreeCodecError) -> PlumtreeIHaveFields {
        var messageID: [UInt8]?
        var topic: String?
        var offset = start
        while offset < end {
            let (fieldNumber, wireType) = try readTag(bytes, at: &offset)
            guard wireType == 2 else {
                offset = try skip(bytes, at: offset, wireType: wireType, limit: end)
                continue
            }
            let fieldEnd = try readLength(bytes, at: &offset, limit: end)
            let value = Array(bytes[offset..<fieldEnd])
            offset = fieldEnd
            switch fieldNumber {
            case 1: messageID = value
            case 2:
                guard let str = decodeUTF8Strict(value) else {
                    throw .invalidTopicUTF8
                }
                topic = str
            default: break
            }
        }
        guard let messageID else {
            throw .missingField
        }
        guard let topic else {
            throw .missingField
        }
        return PlumtreeIHaveFields(messageID: messageID, topic: topic)
    }

    private static func decodeGraft(
        _ bytes: [UInt8], from start: Int, to end: Int
    ) throws(PlumtreeCodecError) -> PlumtreeGraftFields {
        var topic: String?
        var messageID: [UInt8]?
        var offset = start
        while offset < end {
            let (fieldNumber, wireType) = try readTag(bytes, at: &offset)
            guard wireType == 2 else {
                offset = try skip(bytes, at: offset, wireType: wireType, limit: end)
                continue
            }
            let fieldEnd = try readLength(bytes, at: &offset, limit: end)
            let value = Array(bytes[offset..<fieldEnd])
            offset = fieldEnd
            switch fieldNumber {
            case 1:
                guard let str = decodeUTF8Strict(value) else {
                    throw .invalidTopicUTF8
                }
                topic = str
            case 2: messageID = value
            default: break
            }
        }
        guard let topic else {
            throw .missingField
        }
        return PlumtreeGraftFields(topic: topic, messageID: messageID)
    }

    private static func decodePrune(
        _ bytes: [UInt8], from start: Int, to end: Int
    ) throws(PlumtreeCodecError) -> PlumtreePruneFields {
        var topic: String?
        var offset = start
        while offset < end {
            let (fieldNumber, wireType) = try readTag(bytes, at: &offset)
            guard wireType == 2 else {
                offset = try skip(bytes, at: offset, wireType: wireType, limit: end)
                continue
            }
            let fieldEnd = try readLength(bytes, at: &offset, limit: end)
            if fieldNumber == 1 {
                guard let str = decodeUTF8Strict(Array(bytes[offset..<fieldEnd])) else {
                    throw .invalidTopicUTF8
                }
                topic = str
            }
            offset = fieldEnd
        }
        guard let topic else {
            throw .missingField
        }
        return PlumtreePruneFields(topic: topic)
    }

    // MARK: - Low-level helpers

    @inline(__always)
    static func readTag(
        _ bytes: [UInt8], at offset: inout Int
    ) throws(PlumtreeCodecError) -> (fieldNumber: UInt64, wireType: UInt64) {
        let tag: UInt64
        let tagBytes: Int
        do {
            (tag, tagBytes) = try Varint.decode(from: bytes, at: offset)
        } catch {
            throw .truncated
        }
        offset += tagBytes
        return (tag >> 3, tag & 0x07)
    }

    @inline(__always)
    static func readVarint(
        _ bytes: [UInt8], at offset: inout Int
    ) throws(PlumtreeCodecError) -> UInt64 {
        let value: UInt64
        let valueBytes: Int
        do {
            (value, valueBytes) = try Varint.decode(from: bytes, at: offset)
        } catch {
            throw .truncated
        }
        offset += valueBytes
        return value
    }

    @inline(__always)
    static func readLength(
        _ bytes: [UInt8], at offset: inout Int, limit: Int
    ) throws(PlumtreeCodecError) -> Int {
        let lengthValue: UInt64
        let lengthBytes: Int
        do {
            (lengthValue, lengthBytes) = try Varint.decode(from: bytes, at: offset)
        } catch {
            throw .truncated
        }
        offset += lengthBytes
        let length: Int
        do {
            length = try Varint.toInt(lengthValue)
        } catch {
            throw .truncated
        }
        let fieldEnd = offset + length
        guard fieldEnd <= limit, fieldEnd >= offset else {
            throw .truncated
        }
        return fieldEnd
    }

    static func skip(
        _ bytes: [UInt8], at offset: Int, wireType: UInt64, limit: Int
    ) throws(PlumtreeCodecError) -> Int {
        var newOffset = offset
        switch wireType {
        case 0:
            let bytesRead: Int
            do {
                (_, bytesRead) = try Varint.decode(from: bytes, at: newOffset)
            } catch {
                throw .truncated
            }
            newOffset += bytesRead
        case 1:
            newOffset += 8
        case 2:
            let lengthValue: UInt64
            let lengthBytes: Int
            do {
                (lengthValue, lengthBytes) = try Varint.decode(from: bytes, at: newOffset)
            } catch {
                throw .truncated
            }
            let length: Int
            do {
                length = try Varint.toInt(lengthValue)
            } catch {
                throw .truncated
            }
            guard length <= limit - newOffset else {
                throw .truncated
            }
            newOffset += lengthBytes + length
        case 5:
            newOffset += 4
        default:
            throw .unknownWireType(wireType)
        }
        guard newOffset <= limit else {
            throw .truncated
        }
        return newOffset
    }
}

/// Errors from the Plumtree RPC codec.
public enum PlumtreeCodecError: Error, Equatable, Sendable {
    /// The input was empty.
    case empty
    /// A field extends beyond the available bytes, or a varint is incomplete.
    case truncated
    /// A non-length-delimited field used an unsupported wire type.
    case unknownWireType(UInt64)
    /// A repeated field exceeded `maxElementsPerRPC`.
    case tooManyElements
    /// A required field (message_id / topic / source) was absent.
    case missingField
    /// A topic field was not valid UTF-8.
    case invalidTopicUTF8
}
