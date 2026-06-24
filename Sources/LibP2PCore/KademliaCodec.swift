/// Kademlia DHT message codec (Embedded-clean).
/// https://github.com/libp2p/specs/tree/master/kad-dht
///
/// Embedded-clean: no Foundation, no NIO, no `any`. This is the Kademlia
/// protobuf wire codec over `[UInt8]`, expressed as raw value fields:
///
/// ```protobuf
/// message Message {
///   MessageType type            = 1;   // varint
///   bytes       key             = 10;  // length-delimited
///   Record      record          = 3;   // length-delimited
///   repeated Peer closerPeers   = 8;   // length-delimited (repeated)
///   repeated Peer providerPeers = 9;   // length-delimited (repeated)
/// }
/// message Peer {
///   bytes          id         = 1;   // length-delimited (binary PeerID)
///   repeated bytes addrs      = 2;   // length-delimited (binary multiaddrs)
///   ConnectionType connection = 3;   // varint
/// }
/// message Record {
///   bytes  key          = 1;   // length-delimited
///   bytes  value        = 2;   // length-delimited
///   string timeReceived = 5;   // length-delimited (string)
/// }
/// ```
///
/// The domain types — `PeerID` (from `id` bytes via `PeerIDFraming`) and
/// `Multiaddr` (from `addrs` bytes via `MultiaddrCodec`) — are reconstructed in
/// the `P2PKademlia` adapter; only the byte framing lives here. The codec is a
/// faithful transcription of the historical hand-rolled protobuf path, including
/// the wire field numbers and the 0.2.0 `maxPeers` repeated-field DoS bound.

/// A peer entry inside a Kademlia message (raw byte fields).
///
/// `id` is a binary PeerID; `addresses` are binary multiaddrs. The adapter
/// reconstructs the domain types via the cored `PeerIDFraming`/`MultiaddrCodec`.
public struct KademliaPeerFields: Sendable, Equatable {

    /// The peer ID, binary-encoded (field 1).
    public var id: [UInt8]

    /// The peer's addresses, each a binary multiaddr (field 2, repeated).
    public var addresses: [[UInt8]]

    /// Connection status raw value (field 3).
    public var connectionTypeRawValue: UInt32

    public init(id: [UInt8], addresses: [[UInt8]] = [], connectionTypeRawValue: UInt32 = 0) {
        self.id = id
        self.addresses = addresses
        self.connectionTypeRawValue = connectionTypeRawValue
    }
}

/// A DHT record (raw byte fields).
public struct KademliaRecordFields: Sendable, Equatable {

    /// The record key (field 1).
    public var key: [UInt8]

    /// The record value (field 2).
    public var value: [UInt8]

    /// The received timestamp, an ISO-8601 string (field 5).
    public var timeReceived: String?

    public init(key: [UInt8], value: [UInt8], timeReceived: String? = nil) {
        self.key = key
        self.value = value
        self.timeReceived = timeReceived
    }
}

/// The decoded raw fields of a Kademlia message.
///
/// String fields are strictly UTF-8 decoded. Byte fields stay raw; the adapter
/// parses them into `PeerID`/`Multiaddr`/`Data` and resolves the typed message
/// shape from `type` and field presence.
public struct KademliaFields: Sendable, Equatable {

    /// The message type raw value (field 1).
    public var typeRawValue: UInt32

    /// The lookup key (field 10).
    public var key: [UInt8]?

    /// The record (field 3).
    public var record: KademliaRecordFields?

    /// Closer peers (field 8, repeated).
    public var closerPeers: [KademliaPeerFields]

    /// Provider peers (field 9, repeated).
    public var providerPeers: [KademliaPeerFields]

    public init(
        typeRawValue: UInt32,
        key: [UInt8]? = nil,
        record: KademliaRecordFields? = nil,
        closerPeers: [KademliaPeerFields] = [],
        providerPeers: [KademliaPeerFields] = []
    ) {
        self.typeRawValue = typeRawValue
        self.key = key
        self.record = record
        self.closerPeers = closerPeers
        self.providerPeers = providerPeers
    }

    // MARK: - Field tags

    @usableFromInline static let tagType: UInt8 = 0x08          // field 1, varint
    @usableFromInline static let tagKey: UInt8 = 0x52           // field 10, length-delimited
    @usableFromInline static let tagRecord: UInt8 = 0x1A        // field 3, length-delimited
    @usableFromInline static let tagCloserPeers: UInt8 = 0x42   // field 8, length-delimited
    @usableFromInline static let tagProviderPeers: UInt8 = 0x4A // field 9, length-delimited

    @usableFromInline static let tagPeerID: UInt8 = 0x0A        // field 1, length-delimited
    @usableFromInline static let tagPeerAddrs: UInt8 = 0x12     // field 2, length-delimited
    @usableFromInline static let tagPeerConnection: UInt8 = 0x18 // field 3, varint

    @usableFromInline static let tagRecordKey: UInt8 = 0x0A     // field 1, length-delimited
    @usableFromInline static let tagRecordValue: UInt8 = 0x12   // field 2, length-delimited
    @usableFromInline static let tagRecordTime: UInt8 = 0x2A    // field 5, length-delimited

    // MARK: - Encoding

    /// Encodes the fields to Kademlia protobuf wire format.
    ///
    /// Field order matches the historical encoder (type, key, record,
    /// closerPeers, providerPeers).
    public func encode() -> [UInt8] {
        var result = [UInt8]()

        result.append(KademliaFields.tagType)
        result.append(contentsOf: Varint.encodeBytes(UInt64(typeRawValue)))

        if let key {
            appendLengthDelimited(&result, tag: KademliaFields.tagKey, bytes: key)
        }

        if let record {
            appendLengthDelimited(&result, tag: KademliaFields.tagRecord, bytes: KademliaFields.encodeRecord(record))
        }

        for peer in closerPeers {
            appendLengthDelimited(&result, tag: KademliaFields.tagCloserPeers, bytes: KademliaFields.encodePeer(peer))
        }

        for peer in providerPeers {
            appendLengthDelimited(&result, tag: KademliaFields.tagProviderPeers, bytes: KademliaFields.encodePeer(peer))
        }

        return result
    }

    @inline(__always)
    private func appendLengthDelimited(_ out: inout [UInt8], tag: UInt8, bytes: [UInt8]) {
        out.append(tag)
        out.append(contentsOf: Varint.encodeBytes(UInt64(bytes.count)))
        out.append(contentsOf: bytes)
    }

    private static func encodePeer(_ peer: KademliaPeerFields) -> [UInt8] {
        var out = [UInt8]()
        out.append(tagPeerID)
        out.append(contentsOf: Varint.encodeBytes(UInt64(peer.id.count)))
        out.append(contentsOf: peer.id)

        for addr in peer.addresses {
            out.append(tagPeerAddrs)
            out.append(contentsOf: Varint.encodeBytes(UInt64(addr.count)))
            out.append(contentsOf: addr)
        }

        out.append(tagPeerConnection)
        out.append(contentsOf: Varint.encodeBytes(UInt64(peer.connectionTypeRawValue)))
        return out
    }

    private static func encodeRecord(_ record: KademliaRecordFields) -> [UInt8] {
        var out = [UInt8]()
        out.append(tagRecordKey)
        out.append(contentsOf: Varint.encodeBytes(UInt64(record.key.count)))
        out.append(contentsOf: record.key)

        out.append(tagRecordValue)
        out.append(contentsOf: Varint.encodeBytes(UInt64(record.value.count)))
        out.append(contentsOf: record.value)

        if let time = record.timeReceived {
            let timeBytes = [UInt8](time.utf8)
            out.append(tagRecordTime)
            out.append(contentsOf: Varint.encodeBytes(UInt64(timeBytes.count)))
            out.append(contentsOf: timeBytes)
        }
        return out
    }

    // MARK: - Decoding

    /// Decodes a Kademlia message from protobuf wire format.
    ///
    /// - Parameters:
    ///   - bytes: The protobuf-encoded message.
    ///   - maxPeers: Repeated-field cap for `closerPeers` / `providerPeers`. Once
    ///     reached, surplus entries are dropped while the offset still advances
    ///     (a 0.2.0 DoS bound against Sybil/eclipse peer-list injection).
    /// - Throws: `KademliaCodecError` on truncated / malformed framing.
    public static func decode(
        from bytes: [UInt8],
        maxPeers: Int
    ) throws(KademliaCodecError) -> KademliaFields {
        var typeRawValue: UInt32 = 0
        var key: [UInt8]?
        var record: KademliaRecordFields?
        var closerPeers: [KademliaPeerFields] = []
        var providerPeers: [KademliaPeerFields] = []

        var offset = 0
        while offset < bytes.count {
            let tag: UInt64
            let tagBytes: Int
            do {
                (tag, tagBytes) = try Varint.decode(from: bytes, at: offset)
            } catch {
                throw .truncated
            }
            offset += tagBytes

            let fieldNumber = tag >> 3
            let wireType = tag & 0x07

            switch (fieldNumber, wireType) {
            case (1, 0):
                let value: UInt64
                let valueBytes: Int
                do {
                    (value, valueBytes) = try Varint.decode(from: bytes, at: offset)
                } catch {
                    throw .truncated
                }
                offset += valueBytes
                typeRawValue = UInt32(truncatingIfNeeded: value)

            case (10, 2):
                let end = try KademliaFields.readLength(bytes, at: &offset)
                key = Array(bytes[offset..<end])
                offset = end

            case (3, 2):
                let end = try KademliaFields.readLength(bytes, at: &offset)
                record = try KademliaFields.decodeRecord(bytes, from: offset, to: end)
                offset = end

            case (8, 2):
                let end = try KademliaFields.readLength(bytes, at: &offset)
                if closerPeers.count < maxPeers {
                    closerPeers.append(try KademliaFields.decodePeer(bytes, from: offset, to: end))
                }
                offset = end

            case (9, 2):
                let end = try KademliaFields.readLength(bytes, at: &offset)
                if providerPeers.count < maxPeers {
                    providerPeers.append(try KademliaFields.decodePeer(bytes, from: offset, to: end))
                }
                offset = end

            default:
                offset = try KademliaFields.skipField(wireType: wireType, bytes: bytes, offset: offset, limit: bytes.count)
            }
        }

        return KademliaFields(
            typeRawValue: typeRawValue,
            key: key,
            record: record,
            closerPeers: closerPeers,
            providerPeers: providerPeers
        )
    }

    private static func decodePeer(
        _ bytes: [UInt8], from start: Int, to end: Int
    ) throws(KademliaCodecError) -> KademliaPeerFields {
        var id: [UInt8]?
        var addresses: [[UInt8]] = []
        var connectionTypeRawValue: UInt32 = 0

        var offset = start
        while offset < end {
            let tag: UInt64
            let tagBytes: Int
            do {
                (tag, tagBytes) = try Varint.decode(from: bytes, at: offset)
            } catch {
                throw .truncated
            }
            offset += tagBytes

            let fieldNumber = tag >> 3
            let wireType = tag & 0x07

            switch (fieldNumber, wireType) {
            case (1, 2):
                let fieldEnd = try KademliaFields.readLength(bytes, at: &offset, limit: end)
                id = Array(bytes[offset..<fieldEnd])
                offset = fieldEnd

            case (2, 2):
                let fieldEnd = try KademliaFields.readLength(bytes, at: &offset, limit: end)
                addresses.append(Array(bytes[offset..<fieldEnd]))
                offset = fieldEnd

            case (3, 0):
                let value: UInt64
                let valueBytes: Int
                do {
                    (value, valueBytes) = try Varint.decode(from: bytes, at: offset)
                } catch {
                    throw .truncated
                }
                offset += valueBytes
                connectionTypeRawValue = UInt32(truncatingIfNeeded: value)

            default:
                offset = try KademliaFields.skipField(wireType: wireType, bytes: bytes, offset: offset, limit: end)
            }
        }

        guard let id else {
            throw .missingPeerID
        }
        return KademliaPeerFields(id: id, addresses: addresses, connectionTypeRawValue: connectionTypeRawValue)
    }

    private static func decodeRecord(
        _ bytes: [UInt8], from start: Int, to end: Int
    ) throws(KademliaCodecError) -> KademliaRecordFields {
        var key: [UInt8]?
        var value: [UInt8]?
        var timeReceived: String?

        var offset = start
        while offset < end {
            let tag: UInt64
            let tagBytes: Int
            do {
                (tag, tagBytes) = try Varint.decode(from: bytes, at: offset)
            } catch {
                throw .truncated
            }
            offset += tagBytes

            let fieldNumber = tag >> 3
            let wireType = tag & 0x07

            guard wireType == 2 else {
                offset = try KademliaFields.skipField(wireType: wireType, bytes: bytes, offset: offset, limit: end)
                continue
            }

            let fieldEnd = try KademliaFields.readLength(bytes, at: &offset, limit: end)
            switch fieldNumber {
            case 1: key = Array(bytes[offset..<fieldEnd])
            case 2: value = Array(bytes[offset..<fieldEnd])
            case 5: timeReceived = decodeUTF8Strict(Array(bytes[offset..<fieldEnd]))
            default: break
            }
            offset = fieldEnd
        }

        guard let key, let value else {
            throw .missingRecordField
        }
        return KademliaRecordFields(key: key, value: value, timeReceived: timeReceived)
    }

    // MARK: - Helpers

    /// Reads a length prefix at `offset`, advancing `offset` past it, and returns
    /// the field-end index. `limit` bounds the field within an enclosing message.
    @inline(__always)
    private static func readLength(
        _ bytes: [UInt8], at offset: inout Int, limit: Int? = nil
    ) throws(KademliaCodecError) -> Int {
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
        let end = offset + length
        let bound = limit ?? bytes.count
        guard end <= bound, end >= offset else {
            throw .truncated
        }
        return end
    }

    private static func skipField(
        wireType: UInt64, bytes: [UInt8], offset: Int, limit: Int
    ) throws(KademliaCodecError) -> Int {
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

/// Errors from the Kademlia message codec.
public enum KademliaCodecError: Error, Equatable, Sendable {
    /// A field extends beyond the available bytes, or a varint is incomplete.
    case truncated
    /// A non-length-delimited field used an unsupported wire type.
    case unknownWireType(UInt64)
    /// A peer entry is missing its required `id` field.
    case missingPeerID
    /// A record is missing its required `key` or `value` field.
    case missingRecordField
}
