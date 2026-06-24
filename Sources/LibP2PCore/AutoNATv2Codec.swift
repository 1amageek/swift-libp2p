/// AutoNAT v2 message codec (Embedded-clean).
/// https://github.com/libp2p/specs/blob/master/autonat/autonat-v2.md
///
/// Embedded-clean: no Foundation, no NIO, no `any`. AutoNAT v2 uses nonce-based
/// reachability verification, with the nonce carried as a protobuf `fixed64`
/// (8 bytes little-endian). This is the v2 wire codec over `[UInt8]`, expressed
/// as raw value fields:
///
/// ```protobuf
/// message Message {
///   MessageType  type         = 1;   // varint (request=0, response=1, back=2)
///   DialRequest  dialRequest  = 2;   // length-delimited
///   DialResponse dialResponse = 3;   // length-delimited
///   DialBack     dialBack     = 4;   // length-delimited
/// }
/// message DialRequest  { bytes address = 1; fixed64 nonce = 2; }
/// message DialResponse { ResponseStatus status = 1; bytes address = 2; }
/// message DialBack     { fixed64 nonce = 1; }
/// ```
///
/// The domain `Multiaddr` values (from `address` bytes) are reconstructed in the
/// `P2PAutoNAT` adapter; only the byte framing lives here. Faithful
/// transcription of the historical hand-rolled codec: field numbers/wire types
/// (incl. the fixed64 nonce) and message-shape resolution preserved.

/// Message-type discriminant of an AutoNAT v2 message (field 1).
public enum AutoNATv2MessageKind: UInt64, Sendable, Equatable {
    case dialRequest = 0
    case dialResponse = 1
    case dialBack = 2
}

/// A DialRequest sub-message (raw fields).
public struct AutoNATv2DialRequestFields: Sendable, Equatable {
    public var address: [UInt8]
    public var nonce: UInt64

    public init(address: [UInt8], nonce: UInt64 = 0) {
        self.address = address
        self.nonce = nonce
    }
}

/// A DialResponse sub-message (raw fields).
public struct AutoNATv2DialResponseFields: Sendable, Equatable {
    public var statusRawValue: UInt32
    public var address: [UInt8]?

    public init(statusRawValue: UInt32 = 0, address: [UInt8]? = nil) {
        self.statusRawValue = statusRawValue
        self.address = address
    }
}

/// A DialBack sub-message (raw fields).
public struct AutoNATv2DialBackFields: Sendable, Equatable {
    public var nonce: UInt64

    public init(nonce: UInt64 = 0) {
        self.nonce = nonce
    }
}

/// The decoded raw fields of an AutoNAT v2 message. Exactly one sub-message is
/// expected per the message `kind`, resolved adapter-side.
public struct AutoNATv2Fields: Sendable, Equatable {
    public var kind: AutoNATv2MessageKind
    public var dialRequest: AutoNATv2DialRequestFields?
    public var dialResponse: AutoNATv2DialResponseFields?
    public var dialBack: AutoNATv2DialBackFields?

    public init(
        kind: AutoNATv2MessageKind,
        dialRequest: AutoNATv2DialRequestFields? = nil,
        dialResponse: AutoNATv2DialResponseFields? = nil,
        dialBack: AutoNATv2DialBackFields? = nil
    ) {
        self.kind = kind
        self.dialRequest = dialRequest
        self.dialResponse = dialResponse
        self.dialBack = dialBack
    }

    // MARK: - Field tags

    @usableFromInline static let tagType: UInt8 = 0x08          // field 1, varint
    @usableFromInline static let tagDialRequest: UInt8 = 0x12   // field 2, ld
    @usableFromInline static let tagDialResponse: UInt8 = 0x1A  // field 3, ld
    @usableFromInline static let tagDialBack: UInt8 = 0x22      // field 4, ld

    @usableFromInline static let tagReqAddress: UInt8 = 0x0A    // field 1, ld
    @usableFromInline static let tagReqNonce: UInt8 = 0x11      // field 2, fixed64

    @usableFromInline static let tagRespStatus: UInt8 = 0x08    // field 1, varint
    @usableFromInline static let tagRespAddress: UInt8 = 0x12   // field 2, ld

    @usableFromInline static let tagBackNonce: UInt8 = 0x09     // field 1, fixed64

    // MARK: - Encoding

    /// Encodes the fields to AutoNAT v2 protobuf wire format.
    public func encode() -> [UInt8] {
        var out = [UInt8]()
        out.append(AutoNATv2Fields.tagType)
        out.append(contentsOf: Varint.encodeBytes(kind.rawValue))

        switch kind {
        case .dialRequest:
            if let dialRequest {
                appendLD(&out, tag: AutoNATv2Fields.tagDialRequest, bytes: AutoNATv2Fields.encodeRequest(dialRequest))
            }
        case .dialResponse:
            if let dialResponse {
                appendLD(&out, tag: AutoNATv2Fields.tagDialResponse, bytes: AutoNATv2Fields.encodeResponse(dialResponse))
            }
        case .dialBack:
            if let dialBack {
                appendLD(&out, tag: AutoNATv2Fields.tagDialBack, bytes: AutoNATv2Fields.encodeBack(dialBack))
            }
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
    static func appendLD(_ out: inout [UInt8], tag: UInt8, bytes: [UInt8]) {
        out.append(tag)
        out.append(contentsOf: Varint.encodeBytes(UInt64(bytes.count)))
        out.append(contentsOf: bytes)
    }

    private static func encodeRequest(_ req: AutoNATv2DialRequestFields) -> [UInt8] {
        var out = [UInt8]()
        appendLD(&out, tag: tagReqAddress, bytes: req.address)
        out.append(tagReqNonce)
        out.append(contentsOf: encodeFixed64(req.nonce))
        return out
    }

    private static func encodeResponse(_ resp: AutoNATv2DialResponseFields) -> [UInt8] {
        var out = [UInt8]()
        out.append(tagRespStatus)
        out.append(contentsOf: Varint.encodeBytes(UInt64(resp.statusRawValue)))
        if let address = resp.address {
            appendLD(&out, tag: tagRespAddress, bytes: address)
        }
        return out
    }

    private static func encodeBack(_ back: AutoNATv2DialBackFields) -> [UInt8] {
        var out = [UInt8]()
        out.append(tagBackNonce)
        out.append(contentsOf: encodeFixed64(back.nonce))
        return out
    }

    /// Encodes a `UInt64` as 8 bytes little-endian (protobuf fixed64).
    @inline(__always)
    static func encodeFixed64(_ value: UInt64) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(8)
        var v = value
        for _ in 0..<8 {
            out.append(UInt8(truncatingIfNeeded: v))
            v >>= 8
        }
        return out
    }

    /// Decodes 8 bytes little-endian (protobuf fixed64) into a `UInt64`.
    @inline(__always)
    static func decodeFixed64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<8 {
            value |= UInt64(bytes[offset + i]) << (8 * i)
        }
        return value
    }

    // MARK: - Decoding

    /// Decodes an AutoNAT v2 message from protobuf wire format.
    public static func decode(from bytes: [UInt8]) throws(AutoNATv2CodecError) -> AutoNATv2Fields {
        var kind: AutoNATv2MessageKind = .dialRequest
        var dialRequest: AutoNATv2DialRequestFields?
        var dialResponse: AutoNATv2DialResponseFields?
        var dialBack: AutoNATv2DialBackFields?

        var offset = 0
        while offset < bytes.count {
            let (fieldNumber, wireType) = try readTag(bytes, at: &offset)
            switch (fieldNumber, wireType) {
            case (1, 0):
                let value = try readVarint(bytes, at: &offset)
                guard let mt = AutoNATv2MessageKind(rawValue: value) else {
                    throw .unknownMessageType(value)
                }
                kind = mt
            case (2, 2):
                let end = try readLength(bytes, at: &offset, limit: bytes.count)
                dialRequest = try decodeRequest(bytes, from: offset, to: end)
                offset = end
            case (3, 2):
                let end = try readLength(bytes, at: &offset, limit: bytes.count)
                dialResponse = try decodeResponse(bytes, from: offset, to: end)
                offset = end
            case (4, 2):
                let end = try readLength(bytes, at: &offset, limit: bytes.count)
                dialBack = try decodeBack(bytes, from: offset, to: end)
                offset = end
            default:
                offset = try skip(bytes, at: offset, wireType: wireType, limit: bytes.count)
            }
        }

        return AutoNATv2Fields(kind: kind, dialRequest: dialRequest, dialResponse: dialResponse, dialBack: dialBack)
    }

    private static func decodeRequest(
        _ bytes: [UInt8], from start: Int, to end: Int
    ) throws(AutoNATv2CodecError) -> AutoNATv2DialRequestFields {
        var address: [UInt8]?
        var nonce: UInt64 = 0
        var offset = start
        while offset < end {
            let (fieldNumber, wireType) = try readTag(bytes, at: &offset)
            switch (fieldNumber, wireType) {
            case (1, 2):
                let fieldEnd = try readLength(bytes, at: &offset, limit: end)
                address = Array(bytes[offset..<fieldEnd])
                offset = fieldEnd
            case (2, 1):
                guard offset + 8 <= end else {
                    throw .truncated
                }
                nonce = decodeFixed64(bytes, at: offset)
                offset += 8
            default:
                offset = try skip(bytes, at: offset, wireType: wireType, limit: end)
            }
        }
        guard let address else {
            throw .missingAddress
        }
        return AutoNATv2DialRequestFields(address: address, nonce: nonce)
    }

    private static func decodeResponse(
        _ bytes: [UInt8], from start: Int, to end: Int
    ) throws(AutoNATv2CodecError) -> AutoNATv2DialResponseFields {
        var statusRawValue: UInt32 = 0
        var address: [UInt8]?
        var offset = start
        while offset < end {
            let (fieldNumber, wireType) = try readTag(bytes, at: &offset)
            switch (fieldNumber, wireType) {
            case (1, 0):
                statusRawValue = UInt32(truncatingIfNeeded: try readVarint(bytes, at: &offset))
            case (2, 2):
                let fieldEnd = try readLength(bytes, at: &offset, limit: end)
                address = Array(bytes[offset..<fieldEnd])
                offset = fieldEnd
            default:
                offset = try skip(bytes, at: offset, wireType: wireType, limit: end)
            }
        }
        return AutoNATv2DialResponseFields(statusRawValue: statusRawValue, address: address)
    }

    private static func decodeBack(
        _ bytes: [UInt8], from start: Int, to end: Int
    ) throws(AutoNATv2CodecError) -> AutoNATv2DialBackFields {
        var nonce: UInt64 = 0
        var offset = start
        while offset < end {
            let (fieldNumber, wireType) = try readTag(bytes, at: &offset)
            switch (fieldNumber, wireType) {
            case (1, 1):
                guard offset + 8 <= end else {
                    throw .truncated
                }
                nonce = decodeFixed64(bytes, at: offset)
                offset += 8
            default:
                offset = try skip(bytes, at: offset, wireType: wireType, limit: end)
            }
        }
        return AutoNATv2DialBackFields(nonce: nonce)
    }

    // MARK: - Low-level helpers

    @inline(__always)
    static func readTag(
        _ bytes: [UInt8], at offset: inout Int
    ) throws(AutoNATv2CodecError) -> (fieldNumber: UInt64, wireType: UInt64) {
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
    ) throws(AutoNATv2CodecError) -> UInt64 {
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
    ) throws(AutoNATv2CodecError) -> Int {
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
    ) throws(AutoNATv2CodecError) -> Int {
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

/// Errors from the AutoNAT v2 message codec.
public enum AutoNATv2CodecError: Error, Equatable, Sendable {
    /// A field extends beyond the available bytes, or a varint is incomplete.
    case truncated
    /// A non-length-delimited field used an unsupported wire type.
    case unknownWireType(UInt64)
    /// The top-level message type discriminant was not a known value.
    case unknownMessageType(UInt64)
    /// A DialRequest is missing its required `address` field.
    case missingAddress
}
