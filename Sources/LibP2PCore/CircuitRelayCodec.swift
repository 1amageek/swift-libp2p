/// Circuit Relay v2 message codec (Embedded-clean).
/// https://github.com/libp2p/specs/blob/master/relay/circuit-v2.md
///
/// Embedded-clean: no Foundation, no NIO, no `any`. This is the circuit-v2
/// protobuf wire codec over `[UInt8]`, expressed as raw value fields:
///
/// ```protobuf
/// message HopMessage  {
///   Type type = 1; Peer peer = 2; Reservation reservation = 3;
///   Limit limit = 4; Status status = 5;
/// }
/// message StopMessage {
///   Type type = 1; Peer peer = 2; Limit limit = 3; Status status = 4;
/// }
/// message Peer        { bytes id = 1; repeated bytes addrs = 2; }
/// message Reservation { uint64 expire = 1; repeated bytes addrs = 2; bytes voucher = 3; }
/// message Limit       { uint32 duration = 1; uint64 data = 2; }
/// ```
///
/// The domain types — `PeerID` (from `id` bytes), `Multiaddr` (from `addrs`
/// bytes), and the `Duration` of `Limit.duration` (here a raw `UInt32` of
/// seconds) — are reconstructed in the `P2PCircuitRelay` adapter; only the byte
/// framing lives here. Faithful transcription of the historical hand-rolled
/// protobuf path: field numbers/types preserved, and an all-nil `Limit` encodes
/// to nothing (the enclosing message omits the field).

/// A peer entry inside a relay message (raw byte fields).
public struct CircuitRelayPeerFields: Sendable, Equatable {
    public var id: [UInt8]
    public var addresses: [[UInt8]]

    public init(id: [UInt8], addresses: [[UInt8]] = []) {
        self.id = id
        self.addresses = addresses
    }
}

/// A reservation entry (raw fields).
public struct CircuitRelayReservationFields: Sendable, Equatable {
    public var expiration: UInt64
    public var addresses: [[UInt8]]
    public var voucher: [UInt8]?

    public init(expiration: UInt64 = 0, addresses: [[UInt8]] = [], voucher: [UInt8]? = nil) {
        self.expiration = expiration
        self.addresses = addresses
        self.voucher = voucher
    }
}

/// A circuit limit entry (raw fields). `durationSeconds` mirrors the wire's
/// `uint32` seconds; the adapter converts to/from `Duration`.
public struct CircuitRelayLimitFields: Sendable, Equatable {
    public var durationSeconds: UInt32?
    public var data: UInt64?

    public init(durationSeconds: UInt32? = nil, data: UInt64? = nil) {
        self.durationSeconds = durationSeconds
        self.data = data
    }

    /// Encodes the limit body. Returns `[]` when both fields are nil, matching
    /// the historical encoder (the enclosing message then omits the field).
    public func encode() -> [UInt8] {
        var out = [UInt8]()
        if let durationSeconds {
            out.append(CircuitRelayCodec.tagLimitDuration)
            out.append(contentsOf: Varint.encodeBytes(UInt64(durationSeconds)))
        }
        if let data {
            out.append(CircuitRelayCodec.tagLimitData)
            out.append(contentsOf: Varint.encodeBytes(data))
        }
        return out
    }
}

/// The decoded raw fields of a HopMessage.
public struct CircuitRelayHopFields: Sendable, Equatable {
    public var typeRawValue: UInt8
    public var peer: CircuitRelayPeerFields?
    public var reservation: CircuitRelayReservationFields?
    public var limit: CircuitRelayLimitFields?
    public var statusRawValue: UInt32?

    public init(
        typeRawValue: UInt8,
        peer: CircuitRelayPeerFields? = nil,
        reservation: CircuitRelayReservationFields? = nil,
        limit: CircuitRelayLimitFields? = nil,
        statusRawValue: UInt32? = nil
    ) {
        self.typeRawValue = typeRawValue
        self.peer = peer
        self.reservation = reservation
        self.limit = limit
        self.statusRawValue = statusRawValue
    }

    /// Encodes the HopMessage to protobuf wire format.
    public func encode() -> [UInt8] {
        var out = [UInt8]()
        out.append(CircuitRelayCodec.tagHopType)
        out.append(contentsOf: Varint.encodeBytes(UInt64(typeRawValue)))

        if let peer {
            CircuitRelayCodec.appendLD(&out, tag: CircuitRelayCodec.tagHopPeer, bytes: CircuitRelayCodec.encodePeer(peer))
        }
        if let reservation {
            CircuitRelayCodec.appendLD(&out, tag: CircuitRelayCodec.tagHopReservation, bytes: CircuitRelayCodec.encodeReservation(reservation))
        }
        if let limit {
            let limitData = limit.encode()
            if !limitData.isEmpty {
                CircuitRelayCodec.appendLD(&out, tag: CircuitRelayCodec.tagHopLimit, bytes: limitData)
            }
        }
        if let statusRawValue {
            out.append(CircuitRelayCodec.tagHopStatus)
            out.append(contentsOf: Varint.encodeBytes(UInt64(statusRawValue)))
        }
        return out
    }

    /// Decodes a HopMessage from protobuf wire format.
    public static func decode(from bytes: [UInt8]) throws(CircuitRelayCodecError) -> CircuitRelayHopFields {
        var typeRawValue: UInt8 = 0
        var peer: CircuitRelayPeerFields?
        var reservation: CircuitRelayReservationFields?
        var limit: CircuitRelayLimitFields?
        var statusRawValue: UInt32?

        var offset = 0
        while offset < bytes.count {
            let (fieldNumber, wireType) = try CircuitRelayCodec.readTag(bytes, at: &offset)
            switch (fieldNumber, wireType) {
            case (1, 0):
                typeRawValue = UInt8(truncatingIfNeeded: try CircuitRelayCodec.readVarint(bytes, at: &offset))
            case (2, 2):
                let end = try CircuitRelayCodec.readLength(bytes, at: &offset, limit: bytes.count)
                peer = try CircuitRelayCodec.decodePeer(bytes, from: offset, to: end)
                offset = end
            case (3, 2):
                let end = try CircuitRelayCodec.readLength(bytes, at: &offset, limit: bytes.count)
                reservation = try CircuitRelayCodec.decodeReservation(bytes, from: offset, to: end)
                offset = end
            case (4, 2):
                let end = try CircuitRelayCodec.readLength(bytes, at: &offset, limit: bytes.count)
                limit = try CircuitRelayCodec.decodeLimit(bytes, from: offset, to: end)
                offset = end
            case (5, 0):
                statusRawValue = UInt32(truncatingIfNeeded: try CircuitRelayCodec.readVarint(bytes, at: &offset))
            default:
                offset = try CircuitRelayCodec.skip(bytes, at: offset, wireType: wireType, limit: bytes.count)
            }
        }

        return CircuitRelayHopFields(
            typeRawValue: typeRawValue, peer: peer, reservation: reservation,
            limit: limit, statusRawValue: statusRawValue
        )
    }
}

/// The decoded raw fields of a StopMessage.
public struct CircuitRelayStopFields: Sendable, Equatable {
    public var typeRawValue: UInt8
    public var peer: CircuitRelayPeerFields?
    public var limit: CircuitRelayLimitFields?
    public var statusRawValue: UInt32?

    public init(
        typeRawValue: UInt8,
        peer: CircuitRelayPeerFields? = nil,
        limit: CircuitRelayLimitFields? = nil,
        statusRawValue: UInt32? = nil
    ) {
        self.typeRawValue = typeRawValue
        self.peer = peer
        self.limit = limit
        self.statusRawValue = statusRawValue
    }

    /// Encodes the StopMessage to protobuf wire format.
    public func encode() -> [UInt8] {
        var out = [UInt8]()
        out.append(CircuitRelayCodec.tagStopType)
        out.append(contentsOf: Varint.encodeBytes(UInt64(typeRawValue)))

        if let peer {
            CircuitRelayCodec.appendLD(&out, tag: CircuitRelayCodec.tagStopPeer, bytes: CircuitRelayCodec.encodePeer(peer))
        }
        if let limit {
            let limitData = limit.encode()
            if !limitData.isEmpty {
                CircuitRelayCodec.appendLD(&out, tag: CircuitRelayCodec.tagStopLimit, bytes: limitData)
            }
        }
        if let statusRawValue {
            out.append(CircuitRelayCodec.tagStopStatus)
            out.append(contentsOf: Varint.encodeBytes(UInt64(statusRawValue)))
        }
        return out
    }

    /// Decodes a StopMessage from protobuf wire format.
    public static func decode(from bytes: [UInt8]) throws(CircuitRelayCodecError) -> CircuitRelayStopFields {
        var typeRawValue: UInt8 = 0
        var peer: CircuitRelayPeerFields?
        var limit: CircuitRelayLimitFields?
        var statusRawValue: UInt32?

        var offset = 0
        while offset < bytes.count {
            let (fieldNumber, wireType) = try CircuitRelayCodec.readTag(bytes, at: &offset)
            switch (fieldNumber, wireType) {
            case (1, 0):
                typeRawValue = UInt8(truncatingIfNeeded: try CircuitRelayCodec.readVarint(bytes, at: &offset))
            case (2, 2):
                let end = try CircuitRelayCodec.readLength(bytes, at: &offset, limit: bytes.count)
                peer = try CircuitRelayCodec.decodePeer(bytes, from: offset, to: end)
                offset = end
            case (3, 2):
                let end = try CircuitRelayCodec.readLength(bytes, at: &offset, limit: bytes.count)
                limit = try CircuitRelayCodec.decodeLimit(bytes, from: offset, to: end)
                offset = end
            case (4, 0):
                statusRawValue = UInt32(truncatingIfNeeded: try CircuitRelayCodec.readVarint(bytes, at: &offset))
            default:
                offset = try CircuitRelayCodec.skip(bytes, at: offset, wireType: wireType, limit: bytes.count)
            }
        }

        return CircuitRelayStopFields(
            typeRawValue: typeRawValue, peer: peer, limit: limit, statusRawValue: statusRawValue
        )
    }
}

/// Shared field tags and low-level helpers for the Circuit Relay v2 codec.
public enum CircuitRelayCodec {

    @usableFromInline static let tagHopType: UInt8 = 0x08        // field 1, varint
    @usableFromInline static let tagHopPeer: UInt8 = 0x12        // field 2, ld
    @usableFromInline static let tagHopReservation: UInt8 = 0x1A // field 3, ld
    @usableFromInline static let tagHopLimit: UInt8 = 0x22       // field 4, ld
    @usableFromInline static let tagHopStatus: UInt8 = 0x28      // field 5, varint

    @usableFromInline static let tagStopType: UInt8 = 0x08       // field 1, varint
    @usableFromInline static let tagStopPeer: UInt8 = 0x12       // field 2, ld
    @usableFromInline static let tagStopLimit: UInt8 = 0x1A      // field 3, ld
    @usableFromInline static let tagStopStatus: UInt8 = 0x20     // field 4, varint

    @usableFromInline static let tagPeerID: UInt8 = 0x0A         // field 1, ld
    @usableFromInline static let tagPeerAddrs: UInt8 = 0x12      // field 2, ld

    @usableFromInline static let tagReservationExpire: UInt8 = 0x08  // field 1, varint
    @usableFromInline static let tagReservationAddrs: UInt8 = 0x12   // field 2, ld
    @usableFromInline static let tagReservationVoucher: UInt8 = 0x1A // field 3, ld

    @usableFromInline static let tagLimitDuration: UInt8 = 0x08  // field 1, varint
    @usableFromInline static let tagLimitData: UInt8 = 0x10      // field 2, varint

    // MARK: - Encoding helpers

    @inline(__always)
    static func appendLD(_ out: inout [UInt8], tag: UInt8, bytes: [UInt8]) {
        out.append(tag)
        out.append(contentsOf: Varint.encodeBytes(UInt64(bytes.count)))
        out.append(contentsOf: bytes)
    }

    static func encodePeer(_ peer: CircuitRelayPeerFields) -> [UInt8] {
        var out = [UInt8]()
        appendLD(&out, tag: tagPeerID, bytes: peer.id)
        for addr in peer.addresses {
            appendLD(&out, tag: tagPeerAddrs, bytes: addr)
        }
        return out
    }

    static func encodeReservation(_ reservation: CircuitRelayReservationFields) -> [UInt8] {
        var out = [UInt8]()
        out.append(tagReservationExpire)
        out.append(contentsOf: Varint.encodeBytes(reservation.expiration))
        for addr in reservation.addresses {
            appendLD(&out, tag: tagReservationAddrs, bytes: addr)
        }
        if let voucher = reservation.voucher {
            appendLD(&out, tag: tagReservationVoucher, bytes: voucher)
        }
        return out
    }

    // MARK: - Decoding sub-messages

    static func decodePeer(
        _ bytes: [UInt8], from start: Int, to end: Int
    ) throws(CircuitRelayCodecError) -> CircuitRelayPeerFields {
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
            case 2: addresses.append(Array(bytes[offset..<fieldEnd]))
            default: break
            }
            offset = fieldEnd
        }
        guard let id else {
            throw .missingPeerID
        }
        return CircuitRelayPeerFields(id: id, addresses: addresses)
    }

    static func decodeReservation(
        _ bytes: [UInt8], from start: Int, to end: Int
    ) throws(CircuitRelayCodecError) -> CircuitRelayReservationFields {
        var expiration: UInt64 = 0
        var addresses: [[UInt8]] = []
        var voucher: [UInt8]?
        var offset = start
        while offset < end {
            let (fieldNumber, wireType) = try readTag(bytes, at: &offset)
            switch (fieldNumber, wireType) {
            case (1, 0):
                expiration = try readVarint(bytes, at: &offset)
            case (2, 2):
                let fieldEnd = try readLength(bytes, at: &offset, limit: end)
                addresses.append(Array(bytes[offset..<fieldEnd]))
                offset = fieldEnd
            case (3, 2):
                let fieldEnd = try readLength(bytes, at: &offset, limit: end)
                voucher = Array(bytes[offset..<fieldEnd])
                offset = fieldEnd
            default:
                offset = try skip(bytes, at: offset, wireType: wireType, limit: end)
            }
        }
        return CircuitRelayReservationFields(expiration: expiration, addresses: addresses, voucher: voucher)
    }

    static func decodeLimit(
        _ bytes: [UInt8], from start: Int, to end: Int
    ) throws(CircuitRelayCodecError) -> CircuitRelayLimitFields {
        var durationSeconds: UInt32?
        var data: UInt64?
        var offset = start
        while offset < end {
            let (fieldNumber, wireType) = try readTag(bytes, at: &offset)
            guard wireType == 0 else {
                offset = try skip(bytes, at: offset, wireType: wireType, limit: end)
                continue
            }
            let value = try readVarint(bytes, at: &offset)
            switch fieldNumber {
            case 1: durationSeconds = UInt32(truncatingIfNeeded: value)
            case 2: data = value
            default: break
            }
        }
        return CircuitRelayLimitFields(durationSeconds: durationSeconds, data: data)
    }

    // MARK: - Low-level helpers

    @inline(__always)
    static func readTag(
        _ bytes: [UInt8], at offset: inout Int
    ) throws(CircuitRelayCodecError) -> (fieldNumber: UInt64, wireType: UInt64) {
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
    ) throws(CircuitRelayCodecError) -> UInt64 {
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
    ) throws(CircuitRelayCodecError) -> Int {
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
    ) throws(CircuitRelayCodecError) -> Int {
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

/// Errors from the Circuit Relay v2 message codec.
public enum CircuitRelayCodecError: Error, Equatable, Sendable {
    /// A field extends beyond the available bytes, or a varint is incomplete.
    case truncated
    /// A non-length-delimited field used an unsupported wire type.
    case unknownWireType(UInt64)
    /// A peer entry is missing its required `id` field.
    case missingPeerID
}
