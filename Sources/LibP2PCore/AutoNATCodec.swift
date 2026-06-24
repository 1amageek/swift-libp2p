/// AutoNAT v1 message codec (Embedded-clean).
/// https://github.com/libp2p/specs/blob/master/autonat/README.md
///
/// Embedded-clean: no Foundation, no NIO, no `any`. This is the AutoNAT v1
/// protobuf wire codec over `[UInt8]`, expressed as raw value fields:
///
/// ```protobuf
/// message Message {
///   MessageType  type         = 1;   // varint
///   Dial         dial         = 2;   // length-delimited
///   DialResponse dialResponse = 3;   // length-delimited
/// }
/// message Dial         { PeerInfo peer = 1; }
/// message PeerInfo     { bytes id = 1; repeated bytes addrs = 2; }
/// message DialResponse { ResponseStatus status = 1; string statusText = 2; bytes addr = 3; }
/// ```
///
/// The domain types — `PeerID` (from `id` bytes) and `Multiaddr` (from `addrs` /
/// `addr` bytes) — are reconstructed in the `P2PAutoNAT` adapter; only the byte
/// framing lives here. Faithful transcription of the historical hand-rolled
/// protobuf path: field numbers/types preserved.

/// PeerInfo inside an AutoNAT message (raw byte fields).
public struct AutoNATPeerInfoFields: Sendable, Equatable {
    public var id: [UInt8]?
    public var addresses: [[UInt8]]

    public init(id: [UInt8]? = nil, addresses: [[UInt8]] = []) {
        self.id = id
        self.addresses = addresses
    }
}

/// The dial-response sub-message of an AutoNAT message (raw fields).
public struct AutoNATDialResponseFields: Sendable, Equatable {
    public var statusRawValue: UInt32
    public var statusText: String?
    public var address: [UInt8]?

    public init(statusRawValue: UInt32 = 0, statusText: String? = nil, address: [UInt8]? = nil) {
        self.statusRawValue = statusRawValue
        self.statusText = statusText
        self.address = address
    }
}

/// The decoded raw fields of an AutoNAT message.
///
/// `dialPeer` is the PeerInfo carried by a DIAL message (field 2 → Dial.peer);
/// `dialResponse` is the DIAL_RESPONSE sub-message (field 3). Exactly one is
/// expected per the message `type`, resolved adapter-side.
public struct AutoNATFields: Sendable, Equatable {
    public var typeRawValue: UInt32
    public var dialPeer: AutoNATPeerInfoFields?
    public var dialResponse: AutoNATDialResponseFields?

    public init(
        typeRawValue: UInt32,
        dialPeer: AutoNATPeerInfoFields? = nil,
        dialResponse: AutoNATDialResponseFields? = nil
    ) {
        self.typeRawValue = typeRawValue
        self.dialPeer = dialPeer
        self.dialResponse = dialResponse
    }

    // MARK: - Field tags

    @usableFromInline static let tagType: UInt8 = 0x08          // field 1, varint
    @usableFromInline static let tagDial: UInt8 = 0x12          // field 2, ld
    @usableFromInline static let tagDialResponse: UInt8 = 0x1A  // field 3, ld

    @usableFromInline static let tagDialPeer: UInt8 = 0x0A      // field 1, ld

    @usableFromInline static let tagPeerInfoID: UInt8 = 0x0A    // field 1, ld
    @usableFromInline static let tagPeerInfoAddrs: UInt8 = 0x12 // field 2, ld

    @usableFromInline static let tagResponseStatus: UInt8 = 0x08     // field 1, varint
    @usableFromInline static let tagResponseStatusText: UInt8 = 0x12 // field 2, ld
    @usableFromInline static let tagResponseAddr: UInt8 = 0x1A       // field 3, ld

    // MARK: - Encoding

    /// Encodes the fields to AutoNAT v1 protobuf wire format.
    public func encode() -> [UInt8] {
        var out = [UInt8]()
        out.append(AutoNATFields.tagType)
        out.append(contentsOf: Varint.encodeBytes(UInt64(typeRawValue)))

        if let dialPeer {
            // Dial { PeerInfo peer = 1 }
            var dial = [UInt8]()
            AutoNATFields.appendLD(&dial, tag: AutoNATFields.tagDialPeer, bytes: AutoNATFields.encodePeerInfo(dialPeer))
            AutoNATFields.appendLD(&out, tag: AutoNATFields.tagDial, bytes: dial)
        }
        if let dialResponse {
            AutoNATFields.appendLD(&out, tag: AutoNATFields.tagDialResponse, bytes: AutoNATFields.encodeResponse(dialResponse))
        }
        return out
    }

    @inline(__always)
    static func appendLD(_ out: inout [UInt8], tag: UInt8, bytes: [UInt8]) {
        out.append(tag)
        out.append(contentsOf: Varint.encodeBytes(UInt64(bytes.count)))
        out.append(contentsOf: bytes)
    }

    private static func encodePeerInfo(_ peer: AutoNATPeerInfoFields) -> [UInt8] {
        var out = [UInt8]()
        if let id = peer.id {
            appendLD(&out, tag: tagPeerInfoID, bytes: id)
        }
        for addr in peer.addresses {
            appendLD(&out, tag: tagPeerInfoAddrs, bytes: addr)
        }
        return out
    }

    private static func encodeResponse(_ response: AutoNATDialResponseFields) -> [UInt8] {
        var out = [UInt8]()
        out.append(tagResponseStatus)
        out.append(contentsOf: Varint.encodeBytes(UInt64(response.statusRawValue)))
        if let statusText = response.statusText {
            appendLD(&out, tag: tagResponseStatusText, bytes: [UInt8](statusText.utf8))
        }
        if let address = response.address {
            appendLD(&out, tag: tagResponseAddr, bytes: address)
        }
        return out
    }

    // MARK: - Decoding

    /// Decodes an AutoNAT v1 message from protobuf wire format.
    public static func decode(from bytes: [UInt8]) throws(AutoNATCodecError) -> AutoNATFields {
        var typeRawValue: UInt32 = 0
        var dialPeer: AutoNATPeerInfoFields?
        var dialResponse: AutoNATDialResponseFields?

        var offset = 0
        while offset < bytes.count {
            let (fieldNumber, wireType) = try readTag(bytes, at: &offset)
            switch (fieldNumber, wireType) {
            case (1, 0):
                typeRawValue = UInt32(truncatingIfNeeded: try readVarint(bytes, at: &offset))
            case (2, 2):
                let end = try readLength(bytes, at: &offset, limit: bytes.count)
                dialPeer = try decodeDial(bytes, from: offset, to: end)
                offset = end
            case (3, 2):
                let end = try readLength(bytes, at: &offset, limit: bytes.count)
                dialResponse = try decodeResponse(bytes, from: offset, to: end)
                offset = end
            default:
                offset = try skip(bytes, at: offset, wireType: wireType, limit: bytes.count)
            }
        }
        return AutoNATFields(typeRawValue: typeRawValue, dialPeer: dialPeer, dialResponse: dialResponse)
    }

    private static func decodeDial(
        _ bytes: [UInt8], from start: Int, to end: Int
    ) throws(AutoNATCodecError) -> AutoNATPeerInfoFields {
        var peer: AutoNATPeerInfoFields?
        var offset = start
        while offset < end {
            let (fieldNumber, wireType) = try readTag(bytes, at: &offset)
            switch (fieldNumber, wireType) {
            case (1, 2):
                let fieldEnd = try readLength(bytes, at: &offset, limit: end)
                peer = try decodePeerInfo(bytes, from: offset, to: fieldEnd)
                offset = fieldEnd
            default:
                offset = try skip(bytes, at: offset, wireType: wireType, limit: end)
            }
        }
        guard let peer else {
            throw .missingPeer
        }
        return peer
    }

    /// Per-`PeerInfo` cap on the repeated `addresses` field. Bounds an AutoNAT v1
    /// dial request advertising an unbounded number of addresses.
    private static let maxAddressesPerPeer = 256

    private static func decodePeerInfo(
        _ bytes: [UInt8], from start: Int, to end: Int
    ) throws(AutoNATCodecError) -> AutoNATPeerInfoFields {
        var id: [UInt8]?
        var addresses: [[UInt8]] = []
        var offset = start
        while offset < end {
            let (fieldNumber, wireType) = try readTag(bytes, at: &offset)
            guard wireType == 2 else {
                offset = try skip(bytes, at: offset, wireType: wireType, limit: end)
                continue
            }
            let fieldEnd = try readLength(bytes, at: &offset, limit: end)
            switch fieldNumber {
            case 1: id = Array(bytes[offset..<fieldEnd])
            case 2:
                // Per-PeerInfo cap on the repeated addresses field.
                if addresses.count < maxAddressesPerPeer {
                    addresses.append(Array(bytes[offset..<fieldEnd]))
                }
            default: break
            }
            offset = fieldEnd
        }
        return AutoNATPeerInfoFields(id: id, addresses: addresses)
    }

    private static func decodeResponse(
        _ bytes: [UInt8], from start: Int, to end: Int
    ) throws(AutoNATCodecError) -> AutoNATDialResponseFields {
        var statusRawValue: UInt32 = 0
        var statusText: String?
        var address: [UInt8]?
        var offset = start
        while offset < end {
            let (fieldNumber, wireType) = try readTag(bytes, at: &offset)
            switch (fieldNumber, wireType) {
            case (1, 0):
                statusRawValue = UInt32(truncatingIfNeeded: try readVarint(bytes, at: &offset))
            case (2, 2):
                let fieldEnd = try readLength(bytes, at: &offset, limit: end)
                statusText = decodeUTF8Strict(Array(bytes[offset..<fieldEnd]))
                offset = fieldEnd
            case (3, 2):
                let fieldEnd = try readLength(bytes, at: &offset, limit: end)
                address = Array(bytes[offset..<fieldEnd])
                offset = fieldEnd
            default:
                offset = try skip(bytes, at: offset, wireType: wireType, limit: end)
            }
        }
        return AutoNATDialResponseFields(statusRawValue: statusRawValue, statusText: statusText, address: address)
    }

    // MARK: - Low-level helpers

    @inline(__always)
    static func readTag(
        _ bytes: [UInt8], at offset: inout Int
    ) throws(AutoNATCodecError) -> (fieldNumber: UInt64, wireType: UInt64) {
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
    ) throws(AutoNATCodecError) -> UInt64 {
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
    ) throws(AutoNATCodecError) -> Int {
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
    ) throws(AutoNATCodecError) -> Int {
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

/// Errors from the AutoNAT v1 message codec.
public enum AutoNATCodecError: Error, Equatable, Sendable {
    /// A field extends beyond the available bytes, or a varint is incomplete.
    case truncated
    /// A non-length-delimited field used an unsupported wire type.
    case unknownWireType(UInt64)
    /// A DIAL message is missing its `peer` field.
    case missingPeer
}
