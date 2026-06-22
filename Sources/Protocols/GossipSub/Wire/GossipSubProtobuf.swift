/// GossipSubProtobuf - Wire format encoding/decoding for GossipSub protocol
import Foundation
import NIOCore
import P2PCore

/// Protobuf encoding/decoding for GossipSub RPC messages.
///
/// Wire format follows the pubsub.proto specification:
/// https://github.com/libp2p/specs/blob/master/pubsub/README.md#the-rpc
public enum GossipSubProtobuf {

    // MARK: - Decoding Limits (DoS hardening)

    /// Caps applied while decoding an RPC to bound attacker-controlled work and
    /// memory. Repeated elements beyond these counts are dropped at decode time
    /// (not silently — the surplus simply never enters the parsed structure,
    /// which the higher layers treat as the bounded RPC).
    public struct DecodingLimits: Sendable {
        public var maxMessages: Int
        public var maxSubscriptions: Int
        public var maxIHave: Int
        public var maxIWant: Int
        public var maxGraft: Int
        public var maxPrune: Int
        public var maxIDontWant: Int
        /// Maximum protobuf nesting depth (stack-exhaustion guard).
        public var maxNestingDepth: Int

        public init(
            maxMessages: Int = 1000,
            maxSubscriptions: Int = 200,
            maxIHave: Int = 100,
            maxIWant: Int = 100,
            maxGraft: Int = 100,
            maxPrune: Int = 100,
            maxIDontWant: Int = 100,
            maxNestingDepth: Int = 16
        ) {
            self.maxMessages = maxMessages
            self.maxSubscriptions = maxSubscriptions
            self.maxIHave = maxIHave
            self.maxIWant = maxIWant
            self.maxGraft = maxGraft
            self.maxPrune = maxPrune
            self.maxIDontWant = maxIDontWant
            self.maxNestingDepth = maxNestingDepth
        }

        /// Default limits used when no configuration-derived limits are supplied.
        public static let `default` = DecodingLimits()
    }

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
        var buffer = ByteBufferAllocator().buffer(capacity: 0)
        encode(rpc, into: &buffer)
        return Data(buffer: buffer)
    }

    public static func encode(_ rpc: GossipSubRPC, into buffer: inout ByteBuffer) {
        // Estimate: subscriptions + messages + control overhead
        buffer.reserveCapacity(buffer.writerIndex + estimatedSize(of: rpc))
        let allocator = ByteBufferAllocator()
        var scratch = allocator.buffer(capacity: 0)

        // Field 1: subscriptions (repeated SubOpts)
        for sub in rpc.subscriptions {
            writeLengthDelimitedField(tagRPCSubscriptions, into: &buffer, scratch: &scratch) {
                encodeSubOpts(sub, into: &$0)
            }
        }

        // Field 2: publish (repeated Message)
        for message in rpc.messages {
            writeLengthDelimitedField(tagRPCMessages, into: &buffer, scratch: &scratch) {
                encodeMessage(message, into: &$0)
            }
        }

        // Field 3: control (optional ControlMessage)
        if let control = rpc.control, !control.isEmpty {
            writeLengthDelimitedField(tagRPCControl, into: &buffer, scratch: &scratch) {
                encodeControl(control, into: &$0)
            }
        }
    }

    private static func estimatedSize(of rpc: GossipSubRPC) -> Int {
        rpc.subscriptions.count * 32 + rpc.messages.count * 128 + 64
    }

    private static func encodeSubOpts(_ sub: GossipSubRPC.SubscriptionOpt, into buffer: inout ByteBuffer) {
        let topicBytes = sub.topic.utf8Bytes
        buffer.reserveCapacity(buffer.writerIndex + 4 + topicBytes.count)

        // Field 1: subscribe (bool as varint)
        buffer.writeInteger(tagSubOptsSubscribe)
        buffer.writeInteger(sub.subscribe ? UInt8(1) : UInt8(0))

        // Field 2: topicid (string)
        buffer.writeInteger(tagSubOptsTopic)
        Varint.encode(UInt64(topicBytes.count), into: &buffer)
        buffer.writeBytes(topicBytes)
    }

    private static func encodeMessage(_ message: GossipSubMessage, into buffer: inout ByteBuffer) {
        let topicBytes = message.topic.utf8Bytes
        // Estimate: tag+varint overhead per field + actual data sizes
        let estimatedSize = 32 + message.data.count + message.sequenceNumber.count
            + topicBytes.count + (message.signature?.count ?? 0) + (message.key?.count ?? 0)
        buffer.reserveCapacity(buffer.writerIndex + estimatedSize)

        // Field 1: from (optional bytes)
        if let source = message.source {
            let sourceBytes = source.bytes
            buffer.writeInteger(tagMessageFrom)
            Varint.encode(UInt64(sourceBytes.count), into: &buffer)
            buffer.writeBytes(sourceBytes)
        }

        // Field 2: data (bytes)
        buffer.writeInteger(tagMessageData)
        Varint.encode(UInt64(message.data.count), into: &buffer)
        buffer.writeBytes(message.data)

        // Field 3: seqno (bytes)
        if !message.sequenceNumber.isEmpty {
            buffer.writeInteger(tagMessageSeqno)
            Varint.encode(UInt64(message.sequenceNumber.count), into: &buffer)
            buffer.writeBytes(message.sequenceNumber)
        }

        // Field 4: topic (string) - required
        buffer.writeInteger(tagMessageTopic)
        Varint.encode(UInt64(topicBytes.count), into: &buffer)
        buffer.writeBytes(topicBytes)

        // Field 5: signature (optional bytes)
        if let sig = message.signature {
            buffer.writeInteger(tagMessageSignature)
            Varint.encode(UInt64(sig.count), into: &buffer)
            buffer.writeBytes(sig)
        }

        // Field 6: key (optional bytes)
        if let key = message.key {
            buffer.writeInteger(tagMessageKey)
            Varint.encode(UInt64(key.count), into: &buffer)
            buffer.writeBytes(key)
        }
    }

    private static func encodeControl(_ control: ControlMessageBatch, into buffer: inout ByteBuffer) {
        let estimatedSize = control.ihaves.count * 64 + control.iwants.count * 64
            + control.grafts.count * 32 + control.prunes.count * 48
            + control.idontwants.count * 64
        buffer.reserveCapacity(buffer.writerIndex + estimatedSize)
        let allocator = ByteBufferAllocator()
        var scratch = allocator.buffer(capacity: 0)

        // Field 1: ihave (repeated)
        for ihave in control.ihaves {
            writeLengthDelimitedField(tagControlIHave, into: &buffer, scratch: &scratch) {
                encodeIHave(ihave, into: &$0)
            }
        }

        // Field 2: iwant (repeated)
        for iwant in control.iwants {
            writeLengthDelimitedField(tagControlIWant, into: &buffer, scratch: &scratch) {
                encodeIWant(iwant, into: &$0)
            }
        }

        // Field 3: graft (repeated)
        for graft in control.grafts {
            writeLengthDelimitedField(tagControlGraft, into: &buffer, scratch: &scratch) {
                encodeGraft(graft, into: &$0)
            }
        }

        // Field 4: prune (repeated)
        for prune in control.prunes {
            writeLengthDelimitedField(tagControlPrune, into: &buffer, scratch: &scratch) {
                encodePrune(prune, into: &$0)
            }
        }

        // Field 5: idontwant (repeated, v1.2)
        for idontwant in control.idontwants {
            writeLengthDelimitedField(tagControlIDontWant, into: &buffer, scratch: &scratch) {
                encodeIDontWant(idontwant, into: &$0)
            }
        }
    }

    private static func encodeIHave(_ ihave: ControlMessage.IHave, into buffer: inout ByteBuffer) {
        let topicBytes = ihave.topic.utf8Bytes
        // Estimate: tag+varint+topic + per-messageID (tag+varint+~32 bytes)
        buffer.reserveCapacity(buffer.writerIndex + 4 + topicBytes.count + ihave.messageIDs.count * 36)

        // Field 1: topicID (string)
        buffer.writeInteger(tagIHaveTopic)
        Varint.encode(UInt64(topicBytes.count), into: &buffer)
        buffer.writeBytes(topicBytes)

        // Field 2: messageIDs (repeated bytes)
        for msgID in ihave.messageIDs {
            let bytes = msgID.bytes
            buffer.writeInteger(tagIHaveMessageIDs)
            Varint.encode(UInt64(bytes.count), into: &buffer)
            buffer.writeBytes(bytes)
        }
    }

    private static func encodeIWant(_ iwant: ControlMessage.IWant, into buffer: inout ByteBuffer) {
        // Estimate: per-messageID (tag+varint+~32 bytes)
        buffer.reserveCapacity(buffer.writerIndex + iwant.messageIDs.count * 36)

        // Field 1: messageIDs (repeated bytes)
        for msgID in iwant.messageIDs {
            let bytes = msgID.bytes
            buffer.writeInteger(tagIWantMessageIDs)
            Varint.encode(UInt64(bytes.count), into: &buffer)
            buffer.writeBytes(bytes)
        }
    }

    private static func encodeGraft(_ graft: ControlMessage.Graft, into buffer: inout ByteBuffer) {
        let topicBytes = graft.topic.utf8Bytes
        buffer.reserveCapacity(buffer.writerIndex + 4 + topicBytes.count)

        // Field 1: topicID (string)
        buffer.writeInteger(tagGraftTopic)
        Varint.encode(UInt64(topicBytes.count), into: &buffer)
        buffer.writeBytes(topicBytes)
    }

    private static func encodePrune(_ prune: ControlMessage.Prune, into buffer: inout ByteBuffer) {
        let topicBytes = prune.topic.utf8Bytes
        // Estimate: topic + peers + backoff
        buffer.reserveCapacity(buffer.writerIndex + 4 + topicBytes.count + prune.peers.count * 48 + 12)
        let allocator = ByteBufferAllocator()
        var scratch = allocator.buffer(capacity: 0)

        // Field 1: topicID (string)
        buffer.writeInteger(tagPruneTopic)
        Varint.encode(UInt64(topicBytes.count), into: &buffer)
        buffer.writeBytes(topicBytes)

        // Field 2: peers (repeated PeerInfo)
        for peer in prune.peers {
            writeLengthDelimitedField(tagPrunePeers, into: &buffer, scratch: &scratch) {
                encodePeerInfo(peer, into: &$0)
            }
        }

        // Field 3: backoff (optional uint64)
        if let backoff = prune.backoff {
            buffer.writeInteger(tagPruneBackoff)
            Varint.encode(backoff, into: &buffer)
        }
    }

    private static func encodePeerInfo(_ info: ControlMessage.Prune.PeerInfo, into buffer: inout ByteBuffer) {
        let peerIDBytes = info.peerID.bytes
        buffer.reserveCapacity(buffer.writerIndex + 4 + peerIDBytes.count + (info.signedPeerRecord?.count ?? 0) + 4)

        // Field 1: peerID (bytes)
        buffer.writeInteger(tagPeerInfoPeerID)
        Varint.encode(UInt64(peerIDBytes.count), into: &buffer)
        buffer.writeBytes(peerIDBytes)

        // Field 2: signedPeerRecord (optional bytes)
        if let record = info.signedPeerRecord {
            buffer.writeInteger(tagPeerInfoRecord)
            Varint.encode(UInt64(record.count), into: &buffer)
            buffer.writeBytes(record)
        }
    }

    private static func encodeIDontWant(_ idontwant: ControlMessage.IDontWant, into buffer: inout ByteBuffer) {
        // Estimate: per-messageID (tag+varint+~32 bytes)
        buffer.reserveCapacity(buffer.writerIndex + idontwant.messageIDs.count * 36)

        // Field 1: messageIDs (repeated bytes)
        for msgID in idontwant.messageIDs {
            let bytes = msgID.bytes
            buffer.writeInteger(tagIDontWantMessageIDs)
            Varint.encode(UInt64(bytes.count), into: &buffer)
            buffer.writeBytes(bytes)
        }
    }

    private static func writeLengthDelimitedField(
        _ tag: UInt8,
        into buffer: inout ByteBuffer,
        scratch: inout ByteBuffer,
        body: (inout ByteBuffer) -> Void
    ) {
        scratch.clear()
        body(&scratch)
        buffer.writeInteger(tag)
        Varint.encode(UInt64(scratch.readableBytes), into: &buffer)
        buffer.writeBuffer(&scratch)
    }

    // MARK: - Decoding

    /// Decodes a GossipSubRPC from protobuf wire format.
    public static func decode(_ data: Data, limits: DecodingLimits = .default) throws -> GossipSubRPC {
        try decode(data, offset: 0, end: data.count, limits: limits, depth: 0)
    }

    public static func decode(_ buffer: ByteBuffer, limits: DecodingLimits = .default) throws -> GossipSubRPC {
        try decode(Data(buffer: buffer), limits: limits)
    }

    private static func decodeSubOpts(_ data: Data) throws -> GossipSubRPC.SubscriptionOpt {
        try decodeSubOpts(data, offset: 0, end: data.count)
    }

    private static func decodeSubOpts(
        _ data: Data,
        offset startOffset: Int,
        end: Int
    ) throws -> GossipSubRPC.SubscriptionOpt {
        try data.withUnsafeBytes { bytes in
            var subscribe = false
            var topic: Topic?
            var offset = startOffset

            while offset < end {
                let (tag, tagBytes) = try Varint.decode(from: bytes, at: offset)
                offset += tagBytes

                let fieldNumber = tag >> 3
                let wireType = tag & 0x07

                switch fieldNumber {
                case 1:
                    guard wireType == wireTypeVarint else {
                        offset = try skipField(in: bytes, at: offset, wireType: wireType)
                        continue
                    }
                    let (value, valueBytes) = try Varint.decode(from: bytes, at: offset)
                    offset += valueBytes
                    subscribe = value != 0

                case 2:
                    guard wireType == wireTypeLengthDelimited else {
                        offset = try skipField(in: bytes, at: offset, wireType: wireType)
                        continue
                    }
                    let (length, lengthBytes) = try Varint.decode(from: bytes, at: offset)
                    offset += lengthBytes
                    let fieldEnd = offset + Int(length)
                    guard fieldEnd <= end else {
                        throw GossipSubError.invalidProtobuf("Field truncated")
                    }
                    if let str = String(bytes: data[fieldRange(in: data, offset: offset, end: fieldEnd)], encoding: .utf8) {
                        topic = Topic(str)
                    }
                    offset = fieldEnd

                default:
                    offset = try skipField(in: bytes, at: offset, wireType: wireType)
                }
            }

            guard let topic else {
                throw GossipSubError.invalidProtobuf("Missing topic in SubOpts")
            }

            return GossipSubRPC.SubscriptionOpt(subscribe: subscribe, topic: topic)
        }
    }

    private static func decodeMessage(_ data: Data) throws -> GossipSubMessage {
        try decodeMessage(data, offset: 0, end: data.count)
    }

    private static func decodeMessage(
        _ data: Data,
        offset startOffset: Int,
        end: Int
    ) throws -> GossipSubMessage {
        try data.withUnsafeBytes { bytes in
            var source: PeerID?
            var messageData = Data()
            var sequenceNumber = Data()
            var topic: Topic?
            var signature: Data?
            var key: Data?
            var offset = startOffset

            while offset < end {
                let (tag, tagBytes) = try Varint.decode(from: bytes, at: offset)
                offset += tagBytes

                let fieldNumber = tag >> 3
                let wireType = tag & 0x07

                guard wireType == wireTypeLengthDelimited else {
                    offset = try skipField(in: bytes, at: offset, wireType: wireType)
                    continue
                }

                let (length, lengthBytes) = try Varint.decode(from: bytes, at: offset)
                offset += lengthBytes
                let fieldEnd = offset + Int(length)
                guard fieldEnd <= end else {
                    throw GossipSubError.invalidProtobuf("Field truncated")
                }
                let fieldData = data[fieldRange(in: data, offset: offset, end: fieldEnd)]
                offset = fieldEnd

                switch fieldNumber {
                case 1:
                    source = try PeerID(bytes: Data(fieldData))
                case 2:
                    messageData = Data(fieldData)
                case 3:
                    sequenceNumber = Data(fieldData)
                case 4:
                    if let str = String(bytes: fieldData, encoding: .utf8) {
                        topic = Topic(str)
                    }
                case 5:
                    signature = Data(fieldData)
                case 6:
                    key = Data(fieldData)
                default:
                    break
                }
            }

            guard let topic else {
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
    }

    private static func decodeControl(_ data: Data) throws -> ControlMessageBatch {
        try decodeControl(data, offset: 0, end: data.count, limits: .default, depth: 0)
    }

    private static func decodeControl(
        _ data: Data,
        offset startOffset: Int,
        end: Int,
        limits: DecodingLimits,
        depth: Int
    ) throws -> ControlMessageBatch {
        guard depth < limits.maxNestingDepth else {
            throw GossipSubError.invalidProtobuf("Maximum nesting depth exceeded")
        }
        return try data.withUnsafeBytes { bytes in
            var batch = ControlMessageBatch()
            var offset = startOffset

            while offset < end {
                let (tag, tagBytes) = try Varint.decode(from: bytes, at: offset)
                offset += tagBytes

                let fieldNumber = tag >> 3
                let wireType = tag & 0x07

                guard wireType == wireTypeLengthDelimited else {
                    offset = try skipField(in: bytes, at: offset, wireType: wireType)
                    continue
                }

                let (length, lengthBytes) = try Varint.decode(from: bytes, at: offset)
                offset += lengthBytes
                let fieldEnd = offset + Int(length)
                guard fieldEnd <= end else {
                    throw GossipSubError.invalidProtobuf("Field truncated")
                }

                // Per-control-element caps: drop surplus repeated control entries.
                switch fieldNumber {
                case 1:
                    if batch.ihaves.count < limits.maxIHave {
                        batch.ihaves.append(try decodeIHave(data, offset: offset, end: fieldEnd))
                    }
                case 2:
                    if batch.iwants.count < limits.maxIWant {
                        batch.iwants.append(try decodeIWant(data, offset: offset, end: fieldEnd))
                    }
                case 3:
                    if batch.grafts.count < limits.maxGraft {
                        batch.grafts.append(try decodeGraft(data, offset: offset, end: fieldEnd))
                    }
                case 4:
                    if batch.prunes.count < limits.maxPrune {
                        batch.prunes.append(try decodePrune(data, offset: offset, end: fieldEnd))
                    }
                case 5:
                    if batch.idontwants.count < limits.maxIDontWant {
                        batch.idontwants.append(try decodeIDontWant(data, offset: offset, end: fieldEnd))
                    }
                default:
                    break
                }
                offset = fieldEnd
            }

            return batch
        }
    }

    private static func decodeIHave(_ data: Data) throws -> ControlMessage.IHave {
        try decodeIHave(data, offset: 0, end: data.count)
    }

    private static func decodeIHave(
        _ data: Data,
        offset startOffset: Int,
        end: Int
    ) throws -> ControlMessage.IHave {
        try data.withUnsafeBytes { bytes in
            var topic: Topic?
            var messageIDs: [MessageID] = []
            var offset = startOffset

            while offset < end {
                let (tag, tagBytes) = try Varint.decode(from: bytes, at: offset)
                offset += tagBytes

                let fieldNumber = tag >> 3
                let wireType = tag & 0x07

                guard wireType == wireTypeLengthDelimited else {
                    offset = try skipField(in: bytes, at: offset, wireType: wireType)
                    continue
                }

                let (length, lengthBytes) = try Varint.decode(from: bytes, at: offset)
                offset += lengthBytes
                let fieldEnd = offset + Int(length)
                guard fieldEnd <= end else {
                    throw GossipSubError.invalidProtobuf("Field truncated")
                }
                let fieldData = data[fieldRange(in: data, offset: offset, end: fieldEnd)]
                offset = fieldEnd

                switch fieldNumber {
                case 1:
                    if let str = String(bytes: fieldData, encoding: .utf8) {
                        topic = Topic(str)
                    }
                case 2:
                    messageIDs.append(MessageID(bytes: Data(fieldData)))
                default:
                    break
                }
            }

            guard let topic else {
                throw GossipSubError.invalidProtobuf("Missing topic in IHave")
            }

            return ControlMessage.IHave(topic: topic, messageIDs: messageIDs)
        }
    }

    private static func decodeIWant(_ data: Data) throws -> ControlMessage.IWant {
        try decodeIWant(data, offset: 0, end: data.count)
    }

    private static func decodeIWant(
        _ data: Data,
        offset startOffset: Int,
        end: Int
    ) throws -> ControlMessage.IWant {
        try data.withUnsafeBytes { bytes in
            var messageIDs: [MessageID] = []
            var offset = startOffset

            while offset < end {
                let (tag, tagBytes) = try Varint.decode(from: bytes, at: offset)
                offset += tagBytes

                let fieldNumber = tag >> 3
                let wireType = tag & 0x07

                guard wireType == wireTypeLengthDelimited else {
                    offset = try skipField(in: bytes, at: offset, wireType: wireType)
                    continue
                }

                let (length, lengthBytes) = try Varint.decode(from: bytes, at: offset)
                offset += lengthBytes
                let fieldEnd = offset + Int(length)
                guard fieldEnd <= end else {
                    throw GossipSubError.invalidProtobuf("Field truncated")
                }
                if fieldNumber == 1 {
                    messageIDs.append(MessageID(bytes: Data(data[fieldRange(in: data, offset: offset, end: fieldEnd)])))
                }
                offset = fieldEnd
            }

            return ControlMessage.IWant(messageIDs: messageIDs)
        }
    }

    private static func decodeGraft(_ data: Data) throws -> ControlMessage.Graft {
        try decodeGraft(data, offset: 0, end: data.count)
    }

    private static func decodeGraft(
        _ data: Data,
        offset startOffset: Int,
        end: Int
    ) throws -> ControlMessage.Graft {
        try data.withUnsafeBytes { bytes in
            var topic: Topic?
            var offset = startOffset

            while offset < end {
                let (tag, tagBytes) = try Varint.decode(from: bytes, at: offset)
                offset += tagBytes

                let fieldNumber = tag >> 3
                let wireType = tag & 0x07

                guard wireType == wireTypeLengthDelimited else {
                    offset = try skipField(in: bytes, at: offset, wireType: wireType)
                    continue
                }

                let (length, lengthBytes) = try Varint.decode(from: bytes, at: offset)
                offset += lengthBytes
                let fieldEnd = offset + Int(length)
                guard fieldEnd <= end else {
                    throw GossipSubError.invalidProtobuf("Field truncated")
                }
                if fieldNumber == 1,
                   let str = String(bytes: data[fieldRange(in: data, offset: offset, end: fieldEnd)], encoding: .utf8) {
                    topic = Topic(str)
                }
                offset = fieldEnd
            }

            guard let topic else {
                throw GossipSubError.invalidProtobuf("Missing topic in Graft")
            }

            return ControlMessage.Graft(topic: topic)
        }
    }

    private static func decodePrune(_ data: Data) throws -> ControlMessage.Prune {
        try decodePrune(data, offset: 0, end: data.count)
    }

    private static func decodePrune(
        _ data: Data,
        offset startOffset: Int,
        end: Int
    ) throws -> ControlMessage.Prune {
        try data.withUnsafeBytes { bytes in
            var topic: Topic?
            var peers: [ControlMessage.Prune.PeerInfo] = []
            var backoff: UInt64?
            var offset = startOffset

            while offset < end {
                let (tag, tagBytes) = try Varint.decode(from: bytes, at: offset)
                offset += tagBytes

                let fieldNumber = tag >> 3
                let wireType = tag & 0x07

                switch fieldNumber {
                case 1:
                    guard wireType == wireTypeLengthDelimited else {
                        offset = try skipField(in: bytes, at: offset, wireType: wireType)
                        continue
                    }
                    let (length, lengthBytes) = try Varint.decode(from: bytes, at: offset)
                    offset += lengthBytes
                    let fieldEnd = offset + Int(length)
                    guard fieldEnd <= end else {
                        throw GossipSubError.invalidProtobuf("Field truncated")
                    }
                    if let str = String(bytes: data[fieldRange(in: data, offset: offset, end: fieldEnd)], encoding: .utf8) {
                        topic = Topic(str)
                    }
                    offset = fieldEnd

                case 2:
                    guard wireType == wireTypeLengthDelimited else {
                        offset = try skipField(in: bytes, at: offset, wireType: wireType)
                        continue
                    }
                    let (length, lengthBytes) = try Varint.decode(from: bytes, at: offset)
                    offset += lengthBytes
                    let fieldEnd = offset + Int(length)
                    guard fieldEnd <= end else {
                        throw GossipSubError.invalidProtobuf("Field truncated")
                    }
                    peers.append(try decodePeerInfo(data, offset: offset, end: fieldEnd))
                    offset = fieldEnd

                case 3:
                    guard wireType == wireTypeVarint else {
                        offset = try skipField(in: bytes, at: offset, wireType: wireType)
                        continue
                    }
                    let (value, valueBytes) = try Varint.decode(from: bytes, at: offset)
                    offset += valueBytes
                    backoff = value

                default:
                    offset = try skipField(in: bytes, at: offset, wireType: wireType)
                }
            }

            guard let topic else {
                throw GossipSubError.invalidProtobuf("Missing topic in Prune")
            }

            return ControlMessage.Prune(topic: topic, peers: peers, backoff: backoff)
        }
    }

    private static func decodePeerInfo(_ data: Data) throws -> ControlMessage.Prune.PeerInfo {
        try decodePeerInfo(data, offset: 0, end: data.count)
    }

    private static func decodePeerInfo(
        _ data: Data,
        offset startOffset: Int,
        end: Int
    ) throws -> ControlMessage.Prune.PeerInfo {
        try data.withUnsafeBytes { bytes in
            var peerID: PeerID?
            var signedPeerRecord: Data?
            var offset = startOffset

            while offset < end {
                let (tag, tagBytes) = try Varint.decode(from: bytes, at: offset)
                offset += tagBytes

                let fieldNumber = tag >> 3
                let wireType = tag & 0x07

                guard wireType == wireTypeLengthDelimited else {
                    offset = try skipField(in: bytes, at: offset, wireType: wireType)
                    continue
                }

                let (length, lengthBytes) = try Varint.decode(from: bytes, at: offset)
                offset += lengthBytes
                let fieldEnd = offset + Int(length)
                guard fieldEnd <= end else {
                    throw GossipSubError.invalidProtobuf("Field truncated")
                }
                let fieldData = data[fieldRange(in: data, offset: offset, end: fieldEnd)]
                offset = fieldEnd

                switch fieldNumber {
                case 1:
                    peerID = try PeerID(bytes: Data(fieldData))
                case 2:
                    signedPeerRecord = Data(fieldData)
                default:
                    break
                }
            }

            guard let peerID else {
                throw GossipSubError.invalidProtobuf("Missing peerID in PeerInfo")
            }

            return ControlMessage.Prune.PeerInfo(peerID: peerID, signedPeerRecord: signedPeerRecord)
        }
    }

    private static func decodeIDontWant(_ data: Data) throws -> ControlMessage.IDontWant {
        try decodeIDontWant(data, offset: 0, end: data.count)
    }

    private static func decodeIDontWant(
        _ data: Data,
        offset startOffset: Int,
        end: Int
    ) throws -> ControlMessage.IDontWant {
        try data.withUnsafeBytes { bytes in
            var messageIDs: [MessageID] = []
            var offset = startOffset

            while offset < end {
                let (tag, tagBytes) = try Varint.decode(from: bytes, at: offset)
                offset += tagBytes

                let fieldNumber = tag >> 3
                let wireType = tag & 0x07

                guard wireType == wireTypeLengthDelimited else {
                    offset = try skipField(in: bytes, at: offset, wireType: wireType)
                    continue
                }

                let (length, lengthBytes) = try Varint.decode(from: bytes, at: offset)
                offset += lengthBytes
                let fieldEnd = offset + Int(length)
                guard fieldEnd <= end else {
                    throw GossipSubError.invalidProtobuf("Field truncated")
                }
                if fieldNumber == 1 {
                    messageIDs.append(MessageID(bytes: Data(data[fieldRange(in: data, offset: offset, end: fieldEnd)])))
                }
                offset = fieldEnd
            }

            return ControlMessage.IDontWant(messageIDs: messageIDs)
        }
    }

    private static func decode(
        _ data: Data,
        offset startOffset: Int,
        end: Int,
        limits: DecodingLimits,
        depth: Int
    ) throws -> GossipSubRPC {
        guard depth < limits.maxNestingDepth else {
            throw GossipSubError.invalidProtobuf("Maximum nesting depth exceeded")
        }
        return try data.withUnsafeBytes { bytes in
            var subscriptions: [GossipSubRPC.SubscriptionOpt] = []
            var messages: [GossipSubMessage] = []
            var control: ControlMessageBatch?
            var offset = startOffset

            while offset < end {
                let (tag, tagBytes) = try Varint.decode(from: bytes, at: offset)
                offset += tagBytes

                let fieldNumber = tag >> 3
                let wireType = tag & 0x07

                guard wireType == wireTypeLengthDelimited else {
                    offset = try skipField(in: bytes, at: offset, wireType: wireType)
                    continue
                }

                let (length, lengthBytes) = try Varint.decode(from: bytes, at: offset)
                offset += lengthBytes

                let fieldEnd = offset + Int(length)
                guard fieldEnd <= end else {
                    throw GossipSubError.invalidProtobuf("Field truncated")
                }

                switch fieldNumber {
                case 1:
                    // Cap repeated subscriptions; drop surplus.
                    if subscriptions.count < limits.maxSubscriptions {
                        subscriptions.append(try decodeSubOpts(data, offset: offset, end: fieldEnd))
                    }
                case 2:
                    // Cap repeated messages; drop surplus.
                    if messages.count < limits.maxMessages {
                        messages.append(try decodeMessage(data, offset: offset, end: fieldEnd))
                    }
                case 3:
                    control = try decodeControl(data, offset: offset, end: fieldEnd, limits: limits, depth: depth + 1)
                default:
                    break
                }

                offset = fieldEnd
            }

            return GossipSubRPC(
                subscriptions: subscriptions,
                messages: messages,
                control: control
            )
        }
    }

    // MARK: - Helpers

    private static func skipField(in buffer: UnsafeRawBufferPointer, at offset: Int, wireType: UInt64) throws -> Int {
        var newOffset = offset
        switch wireType {
        case 0:
            let (_, bytes) = try Varint.decode(from: buffer, at: newOffset)
            newOffset += bytes
        case 1:
            newOffset += 8
        case 2:
            let (length, lengthBytes) = try Varint.decode(from: buffer, at: newOffset)
            newOffset += lengthBytes + Int(length)
        case 5:
            newOffset += 4
        default:
            throw GossipSubError.invalidProtobuf("Unknown wire type \(wireType)")
        }
        guard newOffset <= buffer.count else {
            throw GossipSubError.invalidProtobuf("Field truncated")
        }
        return newOffset
    }

    private static func fieldRange(in data: Data, offset: Int, end: Int) -> Range<Data.Index> {
        let startIndex = data.index(data.startIndex, offsetBy: offset)
        let endIndex = data.index(data.startIndex, offsetBy: end)
        return startIndex..<endIndex
    }
}
