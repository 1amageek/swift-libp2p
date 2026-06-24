/// GossipSub RPC message codec (Embedded-clean).
/// https://github.com/libp2p/specs/blob/master/pubsub/README.md#the-rpc
///
/// Embedded-clean: no Foundation, no NIO, no `any`. This is the pubsub RPC
/// protobuf wire codec over `[UInt8]`, expressed as raw value fields:
///
/// ```protobuf
/// message RPC {
///   repeated SubOpts        subscriptions = 1;
///   repeated Message        publish       = 2;
///   optional ControlMessage control       = 3;
/// }
/// message SubOpts  { optional bool subscribe = 1; optional string topicid = 2; }
/// message Message  {
///   optional bytes  from      = 1;  optional bytes data = 2;
///   optional bytes  seqno     = 3;  optional string topic = 4;
///   optional bytes  signature = 5;  optional bytes key   = 6;
/// }
/// message ControlMessage {
///   repeated ControlIHave     ihave     = 1;
///   repeated ControlIWant     iwant     = 2;
///   repeated ControlGraft     graft     = 3;
///   repeated ControlPrune     prune     = 4;
///   repeated ControlIDontWant idontwant = 5;
/// }
/// ```
///
/// The domain types — `PeerID` (from `from` / PeerInfo `peerID`), `Topic`
/// (from the topic strings), `MessageID` (from the messageID bytes), and the
/// assembled `GossipSubMessage` (whose ID is computed) — are reconstructed in
/// the `P2PGossipSub` adapter; only the byte framing lives here. The codec is a
/// faithful transcription of the historical hand-rolled protobuf path, including
/// the per-field DoS caps and the protobuf nesting-depth guard.

// MARK: - Decoding Limits (DoS hardening)

/// Caps applied while decoding an RPC to bound attacker-controlled work and
/// memory. Repeated elements beyond these counts are dropped at decode time (the
/// surplus simply never enters the parsed structure, which higher layers treat
/// as the bounded RPC). `maxNestingDepth` guards against protobuf-nesting
/// stack exhaustion.
public struct GossipSubDecodingLimits: Sendable {
    public var maxMessages: Int
    public var maxSubscriptions: Int
    public var maxIHave: Int
    public var maxIWant: Int
    public var maxGraft: Int
    public var maxPrune: Int
    public var maxIDontWant: Int
    public var maxNestingDepth: Int
    /// Per-control-entry cap on the inner `messageIDs` array (IHAVE / IWANT /
    /// IDONTWANT). Bounds a single control entry advertising an unbounded number
    /// of message IDs.
    public var maxMessageIDsPerControl: Int
    /// Per-PRUNE cap on the inner `peers` array (peer-exchange entries). Bounds a
    /// single PRUNE carrying an unbounded peer-exchange list.
    public var maxPeersPerPrune: Int

    public init(
        maxMessages: Int = 1000,
        maxSubscriptions: Int = 200,
        maxIHave: Int = 100,
        maxIWant: Int = 100,
        maxGraft: Int = 100,
        maxPrune: Int = 100,
        maxIDontWant: Int = 100,
        maxNestingDepth: Int = 16,
        maxMessageIDsPerControl: Int = 1000,
        maxPeersPerPrune: Int = 100
    ) {
        self.maxMessages = maxMessages
        self.maxSubscriptions = maxSubscriptions
        self.maxIHave = maxIHave
        self.maxIWant = maxIWant
        self.maxGraft = maxGraft
        self.maxPrune = maxPrune
        self.maxIDontWant = maxIDontWant
        self.maxNestingDepth = maxNestingDepth
        self.maxMessageIDsPerControl = maxMessageIDsPerControl
        self.maxPeersPerPrune = maxPeersPerPrune
    }

    public static let `default` = GossipSubDecodingLimits()
}

// MARK: - Field value types

/// A subscription option (raw fields).
public struct GossipSubSubOptFields: Sendable, Equatable {
    public var subscribe: Bool
    public var topic: String

    public init(subscribe: Bool, topic: String) {
        self.subscribe = subscribe
        self.topic = topic
    }
}

/// A published message (raw byte fields).
public struct GossipSubMessageFields: Sendable, Equatable {
    public var from: [UInt8]?
    public var data: [UInt8]
    public var seqno: [UInt8]
    public var topic: String
    public var signature: [UInt8]?
    public var key: [UInt8]?

    public init(
        from: [UInt8]? = nil,
        data: [UInt8] = [],
        seqno: [UInt8] = [],
        topic: String,
        signature: [UInt8]? = nil,
        key: [UInt8]? = nil
    ) {
        self.from = from
        self.data = data
        self.seqno = seqno
        self.topic = topic
        self.signature = signature
        self.key = key
    }
}

/// An IHAVE control entry (raw fields).
public struct GossipSubIHaveFields: Sendable, Equatable {
    public var topic: String
    public var messageIDs: [[UInt8]]

    public init(topic: String, messageIDs: [[UInt8]]) {
        self.topic = topic
        self.messageIDs = messageIDs
    }
}

/// An IWANT control entry (raw fields).
public struct GossipSubIWantFields: Sendable, Equatable {
    public var messageIDs: [[UInt8]]

    public init(messageIDs: [[UInt8]]) {
        self.messageIDs = messageIDs
    }
}

/// A GRAFT control entry (raw fields).
public struct GossipSubGraftFields: Sendable, Equatable {
    public var topic: String

    public init(topic: String) {
        self.topic = topic
    }
}

/// A peer-exchange entry inside a PRUNE (raw byte fields).
public struct GossipSubPeerInfoFields: Sendable, Equatable {
    public var peerID: [UInt8]
    public var signedPeerRecord: [UInt8]?

    public init(peerID: [UInt8], signedPeerRecord: [UInt8]? = nil) {
        self.peerID = peerID
        self.signedPeerRecord = signedPeerRecord
    }
}

/// A PRUNE control entry (raw fields).
public struct GossipSubPruneFields: Sendable, Equatable {
    public var topic: String
    public var peers: [GossipSubPeerInfoFields]
    public var backoff: UInt64?

    public init(topic: String, peers: [GossipSubPeerInfoFields] = [], backoff: UInt64? = nil) {
        self.topic = topic
        self.peers = peers
        self.backoff = backoff
    }
}

/// An IDONTWANT control entry (raw fields).
public struct GossipSubIDontWantFields: Sendable, Equatable {
    public var messageIDs: [[UInt8]]

    public init(messageIDs: [[UInt8]]) {
        self.messageIDs = messageIDs
    }
}

/// The control sub-message of an RPC (raw fields).
public struct GossipSubControlFields: Sendable, Equatable {
    public var ihaves: [GossipSubIHaveFields]
    public var iwants: [GossipSubIWantFields]
    public var grafts: [GossipSubGraftFields]
    public var prunes: [GossipSubPruneFields]
    public var idontwants: [GossipSubIDontWantFields]

    public init(
        ihaves: [GossipSubIHaveFields] = [],
        iwants: [GossipSubIWantFields] = [],
        grafts: [GossipSubGraftFields] = [],
        prunes: [GossipSubPruneFields] = [],
        idontwants: [GossipSubIDontWantFields] = []
    ) {
        self.ihaves = ihaves
        self.iwants = iwants
        self.grafts = grafts
        self.prunes = prunes
        self.idontwants = idontwants
    }

    public var isEmpty: Bool {
        ihaves.isEmpty && iwants.isEmpty && grafts.isEmpty && prunes.isEmpty && idontwants.isEmpty
    }
}

/// The decoded raw fields of a GossipSub RPC.
public struct GossipSubRPCFields: Sendable, Equatable {
    public var subscriptions: [GossipSubSubOptFields]
    public var messages: [GossipSubMessageFields]
    public var control: GossipSubControlFields?

    public init(
        subscriptions: [GossipSubSubOptFields] = [],
        messages: [GossipSubMessageFields] = [],
        control: GossipSubControlFields? = nil
    ) {
        self.subscriptions = subscriptions
        self.messages = messages
        self.control = control
    }

    // MARK: - Field tags

    @usableFromInline static let tagRPCSubscriptions: UInt8 = 0x0A  // field 1, wt 2
    @usableFromInline static let tagRPCMessages: UInt8 = 0x12       // field 2, wt 2
    @usableFromInline static let tagRPCControl: UInt8 = 0x1A        // field 3, wt 2

    @usableFromInline static let tagSubOptsSubscribe: UInt8 = 0x08  // field 1, wt 0
    @usableFromInline static let tagSubOptsTopic: UInt8 = 0x12      // field 2, wt 2

    @usableFromInline static let tagMessageFrom: UInt8 = 0x0A       // field 1, wt 2
    @usableFromInline static let tagMessageData: UInt8 = 0x12       // field 2, wt 2
    @usableFromInline static let tagMessageSeqno: UInt8 = 0x1A      // field 3, wt 2
    @usableFromInline static let tagMessageTopic: UInt8 = 0x22      // field 4, wt 2
    @usableFromInline static let tagMessageSignature: UInt8 = 0x2A  // field 5, wt 2
    @usableFromInline static let tagMessageKey: UInt8 = 0x32        // field 6, wt 2

    @usableFromInline static let tagControlIHave: UInt8 = 0x0A      // field 1, wt 2
    @usableFromInline static let tagControlIWant: UInt8 = 0x12      // field 2, wt 2
    @usableFromInline static let tagControlGraft: UInt8 = 0x1A      // field 3, wt 2
    @usableFromInline static let tagControlPrune: UInt8 = 0x22      // field 4, wt 2
    @usableFromInline static let tagControlIDontWant: UInt8 = 0x2A  // field 5, wt 2

    @usableFromInline static let tagIHaveTopic: UInt8 = 0x0A        // field 1, wt 2
    @usableFromInline static let tagIHaveMessageIDs: UInt8 = 0x12   // field 2, wt 2
    @usableFromInline static let tagIWantMessageIDs: UInt8 = 0x0A   // field 1, wt 2
    @usableFromInline static let tagGraftTopic: UInt8 = 0x0A        // field 1, wt 2
    @usableFromInline static let tagPruneTopic: UInt8 = 0x0A        // field 1, wt 2
    @usableFromInline static let tagPrunePeers: UInt8 = 0x12        // field 2, wt 2
    @usableFromInline static let tagPruneBackoff: UInt8 = 0x18      // field 3, wt 0
    @usableFromInline static let tagIDontWantMessageIDs: UInt8 = 0x0A // field 1, wt 2
    @usableFromInline static let tagPeerInfoPeerID: UInt8 = 0x0A    // field 1, wt 2
    @usableFromInline static let tagPeerInfoRecord: UInt8 = 0x12    // field 2, wt 2

    // MARK: - Encoding

    /// Encodes the RPC fields to pubsub protobuf wire format.
    ///
    /// Field order matches the historical encoder (subscriptions, messages,
    /// control). An empty control sub-message is omitted.
    public func encode() -> [UInt8] {
        var out = [UInt8]()

        for sub in subscriptions {
            appendLD(&out, tag: GossipSubRPCFields.tagRPCSubscriptions, bytes: GossipSubRPCFields.encodeSubOpts(sub))
        }
        for message in messages {
            appendLD(&out, tag: GossipSubRPCFields.tagRPCMessages, bytes: GossipSubRPCFields.encodeMessage(message))
        }
        if let control, !control.isEmpty {
            appendLD(&out, tag: GossipSubRPCFields.tagRPCControl, bytes: GossipSubRPCFields.encodeControl(control))
        }

        return out
    }

    @inline(__always)
    private func appendLD(_ out: inout [UInt8], tag: UInt8, bytes: [UInt8]) {
        out.append(tag)
        out.append(contentsOf: Varint.encodeBytes(UInt64(bytes.count)))
        out.append(contentsOf: bytes)
    }

    @inline(__always)
    private static func appendLD(_ out: inout [UInt8], tag: UInt8, bytes: [UInt8]) {
        out.append(tag)
        out.append(contentsOf: Varint.encodeBytes(UInt64(bytes.count)))
        out.append(contentsOf: bytes)
    }

    private static func encodeSubOpts(_ sub: GossipSubSubOptFields) -> [UInt8] {
        var out = [UInt8]()
        // Field 1: subscribe (bool as single-byte varint)
        out.append(tagSubOptsSubscribe)
        out.append(sub.subscribe ? 1 : 0)
        // Field 2: topicid (string)
        let topicBytes = [UInt8](sub.topic.utf8)
        out.append(tagSubOptsTopic)
        out.append(contentsOf: Varint.encodeBytes(UInt64(topicBytes.count)))
        out.append(contentsOf: topicBytes)
        return out
    }

    private static func encodeMessage(_ message: GossipSubMessageFields) -> [UInt8] {
        var out = [UInt8]()
        if let from = message.from {
            appendLD(&out, tag: tagMessageFrom, bytes: from)
        }
        appendLD(&out, tag: tagMessageData, bytes: message.data)
        if !message.seqno.isEmpty {
            appendLD(&out, tag: tagMessageSeqno, bytes: message.seqno)
        }
        appendLD(&out, tag: tagMessageTopic, bytes: [UInt8](message.topic.utf8))
        if let signature = message.signature {
            appendLD(&out, tag: tagMessageSignature, bytes: signature)
        }
        if let key = message.key {
            appendLD(&out, tag: tagMessageKey, bytes: key)
        }
        return out
    }

    private static func encodeControl(_ control: GossipSubControlFields) -> [UInt8] {
        var out = [UInt8]()
        for ihave in control.ihaves {
            appendLD(&out, tag: tagControlIHave, bytes: encodeIHave(ihave))
        }
        for iwant in control.iwants {
            appendLD(&out, tag: tagControlIWant, bytes: encodeIWant(iwant))
        }
        for graft in control.grafts {
            appendLD(&out, tag: tagControlGraft, bytes: encodeGraft(graft))
        }
        for prune in control.prunes {
            appendLD(&out, tag: tagControlPrune, bytes: encodePrune(prune))
        }
        for idontwant in control.idontwants {
            appendLD(&out, tag: tagControlIDontWant, bytes: encodeIDontWant(idontwant))
        }
        return out
    }

    private static func encodeIHave(_ ihave: GossipSubIHaveFields) -> [UInt8] {
        var out = [UInt8]()
        appendLD(&out, tag: tagIHaveTopic, bytes: [UInt8](ihave.topic.utf8))
        for msgID in ihave.messageIDs {
            appendLD(&out, tag: tagIHaveMessageIDs, bytes: msgID)
        }
        return out
    }

    private static func encodeIWant(_ iwant: GossipSubIWantFields) -> [UInt8] {
        var out = [UInt8]()
        for msgID in iwant.messageIDs {
            appendLD(&out, tag: tagIWantMessageIDs, bytes: msgID)
        }
        return out
    }

    private static func encodeGraft(_ graft: GossipSubGraftFields) -> [UInt8] {
        var out = [UInt8]()
        appendLD(&out, tag: tagGraftTopic, bytes: [UInt8](graft.topic.utf8))
        return out
    }

    private static func encodePrune(_ prune: GossipSubPruneFields) -> [UInt8] {
        var out = [UInt8]()
        appendLD(&out, tag: tagPruneTopic, bytes: [UInt8](prune.topic.utf8))
        for peer in prune.peers {
            appendLD(&out, tag: tagPrunePeers, bytes: encodePeerInfo(peer))
        }
        if let backoff = prune.backoff {
            out.append(tagPruneBackoff)
            out.append(contentsOf: Varint.encodeBytes(backoff))
        }
        return out
    }

    private static func encodePeerInfo(_ info: GossipSubPeerInfoFields) -> [UInt8] {
        var out = [UInt8]()
        appendLD(&out, tag: tagPeerInfoPeerID, bytes: info.peerID)
        if let record = info.signedPeerRecord {
            appendLD(&out, tag: tagPeerInfoRecord, bytes: record)
        }
        return out
    }

    private static func encodeIDontWant(_ idontwant: GossipSubIDontWantFields) -> [UInt8] {
        var out = [UInt8]()
        for msgID in idontwant.messageIDs {
            appendLD(&out, tag: tagIDontWantMessageIDs, bytes: msgID)
        }
        return out
    }

    // MARK: - Decoding

    /// Decodes a GossipSub RPC from pubsub protobuf wire format.
    ///
    /// - Parameters:
    ///   - bytes: The protobuf-encoded RPC.
    ///   - limits: Per-field caps and the nesting-depth guard (0.2.0 DoS bounds).
    /// - Throws: `GossipSubCodecError` on truncated / malformed framing, or when
    ///   the nesting-depth guard is exceeded.
    public static func decode(
        from bytes: [UInt8],
        limits: GossipSubDecodingLimits = .default
    ) throws(GossipSubCodecError) -> GossipSubRPCFields {
        try decodeRPC(bytes, from: 0, to: bytes.count, limits: limits, depth: 0)
    }

    private static func decodeRPC(
        _ bytes: [UInt8], from start: Int, to end: Int,
        limits: GossipSubDecodingLimits, depth: Int
    ) throws(GossipSubCodecError) -> GossipSubRPCFields {
        guard depth < limits.maxNestingDepth else {
            throw .maxNestingDepthExceeded
        }
        var subscriptions: [GossipSubSubOptFields] = []
        var messages: [GossipSubMessageFields] = []
        var control: GossipSubControlFields?

        var offset = start
        while offset < end {
            let (fieldNumber, wireType) = try readTag(bytes, at: &offset)
            guard wireType == 2 else {
                offset = try skip(bytes, at: offset, wireType: wireType, limit: end)
                continue
            }
            let fieldEnd = try readLength(bytes, at: &offset, limit: end)

            switch fieldNumber {
            case 1:
                if subscriptions.count < limits.maxSubscriptions {
                    subscriptions.append(try decodeSubOpts(bytes, from: offset, to: fieldEnd))
                }
            case 2:
                if messages.count < limits.maxMessages {
                    messages.append(try decodeMessage(bytes, from: offset, to: fieldEnd))
                }
            case 3:
                control = try decodeControl(bytes, from: offset, to: fieldEnd, limits: limits, depth: depth + 1)
            default:
                break
            }
            offset = fieldEnd
        }

        return GossipSubRPCFields(subscriptions: subscriptions, messages: messages, control: control)
    }

    private static func decodeSubOpts(
        _ bytes: [UInt8], from start: Int, to end: Int
    ) throws(GossipSubCodecError) -> GossipSubSubOptFields {
        var subscribe = false
        var topic: String?
        var offset = start
        while offset < end {
            let (fieldNumber, wireType) = try readTag(bytes, at: &offset)
            switch fieldNumber {
            case 1:
                guard wireType == 0 else {
                    offset = try skip(bytes, at: offset, wireType: wireType, limit: end)
                    continue
                }
                let value = try readVarint(bytes, at: &offset)
                subscribe = value != 0
            case 2:
                guard wireType == 2 else {
                    offset = try skip(bytes, at: offset, wireType: wireType, limit: end)
                    continue
                }
                let fieldEnd = try readLength(bytes, at: &offset, limit: end)
                if let str = decodeUTF8Strict(Array(bytes[offset..<fieldEnd])) {
                    topic = str
                }
                offset = fieldEnd
            default:
                offset = try skip(bytes, at: offset, wireType: wireType, limit: end)
            }
        }
        guard let topic else {
            throw .missingTopic
        }
        return GossipSubSubOptFields(subscribe: subscribe, topic: topic)
    }

    private static func decodeMessage(
        _ bytes: [UInt8], from start: Int, to end: Int
    ) throws(GossipSubCodecError) -> GossipSubMessageFields {
        var from: [UInt8]?
        var data: [UInt8] = []
        var seqno: [UInt8] = []
        var topic: String?
        var signature: [UInt8]?
        var key: [UInt8]?

        var offset = start
        while offset < end {
            let (fieldNumber, wireType) = try readTag(bytes, at: &offset)
            guard wireType == 2 else {
                offset = try skip(bytes, at: offset, wireType: wireType, limit: end)
                continue
            }
            let fieldEnd = try readLength(bytes, at: &offset, limit: end)
            switch fieldNumber {
            case 1: from = Array(bytes[offset..<fieldEnd])
            case 2: data = Array(bytes[offset..<fieldEnd])
            case 3: seqno = Array(bytes[offset..<fieldEnd])
            case 4:
                if let str = decodeUTF8Strict(Array(bytes[offset..<fieldEnd])) {
                    topic = str
                }
            case 5: signature = Array(bytes[offset..<fieldEnd])
            case 6: key = Array(bytes[offset..<fieldEnd])
            default: break
            }
            offset = fieldEnd
        }
        guard let topic else {
            throw .missingTopic
        }
        return GossipSubMessageFields(
            from: from, data: data, seqno: seqno, topic: topic, signature: signature, key: key
        )
    }

    private static func decodeControl(
        _ bytes: [UInt8], from start: Int, to end: Int,
        limits: GossipSubDecodingLimits, depth: Int
    ) throws(GossipSubCodecError) -> GossipSubControlFields {
        guard depth < limits.maxNestingDepth else {
            throw .maxNestingDepthExceeded
        }
        var control = GossipSubControlFields()
        var offset = start
        while offset < end {
            let (fieldNumber, wireType) = try readTag(bytes, at: &offset)
            guard wireType == 2 else {
                offset = try skip(bytes, at: offset, wireType: wireType, limit: end)
                continue
            }
            let fieldEnd = try readLength(bytes, at: &offset, limit: end)
            switch fieldNumber {
            case 1:
                if control.ihaves.count < limits.maxIHave {
                    control.ihaves.append(try decodeIHave(
                        bytes, from: offset, to: fieldEnd,
                        maxMessageIDs: limits.maxMessageIDsPerControl
                    ))
                }
            case 2:
                if control.iwants.count < limits.maxIWant {
                    control.iwants.append(try decodeIWant(
                        bytes, from: offset, to: fieldEnd,
                        maxMessageIDs: limits.maxMessageIDsPerControl
                    ))
                }
            case 3:
                if control.grafts.count < limits.maxGraft {
                    control.grafts.append(try decodeGraft(bytes, from: offset, to: fieldEnd))
                }
            case 4:
                if control.prunes.count < limits.maxPrune {
                    control.prunes.append(try decodePrune(
                        bytes, from: offset, to: fieldEnd,
                        maxPeers: limits.maxPeersPerPrune
                    ))
                }
            case 5:
                if control.idontwants.count < limits.maxIDontWant {
                    control.idontwants.append(try decodeIDontWant(
                        bytes, from: offset, to: fieldEnd,
                        maxMessageIDs: limits.maxMessageIDsPerControl
                    ))
                }
            default:
                break
            }
            offset = fieldEnd
        }
        return control
    }

    private static func decodeIHave(
        _ bytes: [UInt8], from start: Int, to end: Int, maxMessageIDs: Int
    ) throws(GossipSubCodecError) -> GossipSubIHaveFields {
        var topic: String?
        var messageIDs: [[UInt8]] = []
        var offset = start
        while offset < end {
            let (fieldNumber, wireType) = try readTag(bytes, at: &offset)
            guard wireType == 2 else {
                offset = try skip(bytes, at: offset, wireType: wireType, limit: end)
                continue
            }
            let fieldEnd = try readLength(bytes, at: &offset, limit: end)
            switch fieldNumber {
            case 1:
                if let str = decodeUTF8Strict(Array(bytes[offset..<fieldEnd])) {
                    topic = str
                }
            case 2:
                // Per-IHAVE cap: bound the inner messageID list (mirror the
                // outer control caps).
                if messageIDs.count < maxMessageIDs {
                    messageIDs.append(Array(bytes[offset..<fieldEnd]))
                }
            default: break
            }
            offset = fieldEnd
        }
        guard let topic else {
            throw .missingTopic
        }
        return GossipSubIHaveFields(topic: topic, messageIDs: messageIDs)
    }

    private static func decodeIWant(
        _ bytes: [UInt8], from start: Int, to end: Int, maxMessageIDs: Int
    ) throws(GossipSubCodecError) -> GossipSubIWantFields {
        var messageIDs: [[UInt8]] = []
        var offset = start
        while offset < end {
            let (fieldNumber, wireType) = try readTag(bytes, at: &offset)
            guard wireType == 2 else {
                offset = try skip(bytes, at: offset, wireType: wireType, limit: end)
                continue
            }
            let fieldEnd = try readLength(bytes, at: &offset, limit: end)
            if fieldNumber == 1 {
                // Per-IWANT cap: bound the inner messageID list.
                if messageIDs.count < maxMessageIDs {
                    messageIDs.append(Array(bytes[offset..<fieldEnd]))
                }
            }
            offset = fieldEnd
        }
        return GossipSubIWantFields(messageIDs: messageIDs)
    }

    private static func decodeGraft(
        _ bytes: [UInt8], from start: Int, to end: Int
    ) throws(GossipSubCodecError) -> GossipSubGraftFields {
        var topic: String?
        var offset = start
        while offset < end {
            let (fieldNumber, wireType) = try readTag(bytes, at: &offset)
            guard wireType == 2 else {
                offset = try skip(bytes, at: offset, wireType: wireType, limit: end)
                continue
            }
            let fieldEnd = try readLength(bytes, at: &offset, limit: end)
            if fieldNumber == 1, let str = decodeUTF8Strict(Array(bytes[offset..<fieldEnd])) {
                topic = str
            }
            offset = fieldEnd
        }
        guard let topic else {
            throw .missingTopic
        }
        return GossipSubGraftFields(topic: topic)
    }

    private static func decodePrune(
        _ bytes: [UInt8], from start: Int, to end: Int, maxPeers: Int
    ) throws(GossipSubCodecError) -> GossipSubPruneFields {
        var topic: String?
        var peers: [GossipSubPeerInfoFields] = []
        var backoff: UInt64?
        var offset = start
        while offset < end {
            let (fieldNumber, wireType) = try readTag(bytes, at: &offset)
            switch fieldNumber {
            case 1:
                guard wireType == 2 else {
                    offset = try skip(bytes, at: offset, wireType: wireType, limit: end)
                    continue
                }
                let fieldEnd = try readLength(bytes, at: &offset, limit: end)
                if let str = decodeUTF8Strict(Array(bytes[offset..<fieldEnd])) {
                    topic = str
                }
                offset = fieldEnd
            case 2:
                guard wireType == 2 else {
                    offset = try skip(bytes, at: offset, wireType: wireType, limit: end)
                    continue
                }
                let fieldEnd = try readLength(bytes, at: &offset, limit: end)
                // Per-PRUNE cap: bound the inner peer-exchange list.
                if peers.count < maxPeers {
                    peers.append(try decodePeerInfo(bytes, from: offset, to: fieldEnd))
                }
                offset = fieldEnd
            case 3:
                guard wireType == 0 else {
                    offset = try skip(bytes, at: offset, wireType: wireType, limit: end)
                    continue
                }
                backoff = try readVarint(bytes, at: &offset)
            default:
                offset = try skip(bytes, at: offset, wireType: wireType, limit: end)
            }
        }
        guard let topic else {
            throw .missingTopic
        }
        return GossipSubPruneFields(topic: topic, peers: peers, backoff: backoff)
    }

    private static func decodePeerInfo(
        _ bytes: [UInt8], from start: Int, to end: Int
    ) throws(GossipSubCodecError) -> GossipSubPeerInfoFields {
        var peerID: [UInt8]?
        var signedPeerRecord: [UInt8]?
        var offset = start
        while offset < end {
            let (fieldNumber, wireType) = try readTag(bytes, at: &offset)
            guard wireType == 2 else {
                offset = try skip(bytes, at: offset, wireType: wireType, limit: end)
                continue
            }
            let fieldEnd = try readLength(bytes, at: &offset, limit: end)
            switch fieldNumber {
            case 1: peerID = Array(bytes[offset..<fieldEnd])
            case 2: signedPeerRecord = Array(bytes[offset..<fieldEnd])
            default: break
            }
            offset = fieldEnd
        }
        guard let peerID else {
            throw .missingPeerID
        }
        return GossipSubPeerInfoFields(peerID: peerID, signedPeerRecord: signedPeerRecord)
    }

    private static func decodeIDontWant(
        _ bytes: [UInt8], from start: Int, to end: Int, maxMessageIDs: Int
    ) throws(GossipSubCodecError) -> GossipSubIDontWantFields {
        var messageIDs: [[UInt8]] = []
        var offset = start
        while offset < end {
            let (fieldNumber, wireType) = try readTag(bytes, at: &offset)
            guard wireType == 2 else {
                offset = try skip(bytes, at: offset, wireType: wireType, limit: end)
                continue
            }
            let fieldEnd = try readLength(bytes, at: &offset, limit: end)
            if fieldNumber == 1 {
                // Per-IDONTWANT cap: bound the inner messageID list.
                if messageIDs.count < maxMessageIDs {
                    messageIDs.append(Array(bytes[offset..<fieldEnd]))
                }
            }
            offset = fieldEnd
        }
        return GossipSubIDontWantFields(messageIDs: messageIDs)
    }

    // MARK: - Low-level helpers

    @inline(__always)
    private static func readTag(
        _ bytes: [UInt8], at offset: inout Int
    ) throws(GossipSubCodecError) -> (fieldNumber: UInt64, wireType: UInt64) {
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
    private static func readVarint(
        _ bytes: [UInt8], at offset: inout Int
    ) throws(GossipSubCodecError) -> UInt64 {
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
    private static func readLength(
        _ bytes: [UInt8], at offset: inout Int, limit: Int
    ) throws(GossipSubCodecError) -> Int {
        let lengthValue: UInt64
        let lengthBytes: Int
        do {
            (lengthValue, lengthBytes) = try Varint.decode(from: bytes, at: offset)
        } catch {
            throw .truncated
        }
        offset += lengthBytes
        // Use the throwing conversion: Int(UInt64) traps on values in
        // (Int.max, UInt64.max], which Varint.decode accepts. An attacker
        // could otherwise crash the process before the bound check below.
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

    private static func skip(
        _ bytes: [UInt8], at offset: Int, wireType: UInt64, limit: Int
    ) throws(GossipSubCodecError) -> Int {
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
            // Throwing conversion avoids a trap on out-of-Int-range lengths.
            let length: Int
            do {
                length = try Varint.toInt(lengthValue)
            } catch {
                throw .truncated
            }
            // Validate the declared length fits before advancing past it,
            // so the addition itself cannot overflow.
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

/// Errors from the GossipSub RPC codec.
public enum GossipSubCodecError: Error, Equatable, Sendable {
    /// A field extends beyond the available bytes, or a varint is incomplete.
    case truncated
    /// A non-length-delimited field used an unsupported wire type.
    case unknownWireType(UInt64)
    /// A sub-message that requires a topic is missing it (or it was malformed UTF-8).
    case missingTopic
    /// A PeerInfo entry is missing its required `peerID` field.
    case missingPeerID
    /// The protobuf nesting depth exceeded the configured guard.
    case maxNestingDepthExceeded
}
