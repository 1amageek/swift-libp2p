/// CircuitRelayProtobuf - Wire format encoding/decoding for Circuit Relay v2
///
/// The wire framing lives in the Embedded-clean ``CircuitRelayHopFields`` /
/// ``CircuitRelayStopFields`` codecs (`LibP2PCore`); this adapter bridges the
/// domain types — `PeerID`, `Multiaddr`, and the `Duration` of the circuit
/// limit — to/from the codecs' raw `[UInt8]` fields, and restores the
/// historical `Data`/`ByteBuffer` API.
///
/// See: https://github.com/libp2p/specs/blob/master/relay/circuit-v2.md

import Foundation
import NIOCore
import P2PCore

/// Protobuf encoding/decoding for Circuit Relay v2 messages.
enum CircuitRelayProtobuf {

    // MARK: - HopMessage

    /// Encodes a HopMessage to protobuf wire format.
    static func encode(_ message: HopMessage) -> Data {
        Data(buildHopFields(message).encode())
    }

    static func encode(_ message: HopMessage, into buffer: inout ByteBuffer) {
        buffer.writeBytes(buildHopFields(message).encode())
    }

    /// Decodes a HopMessage from protobuf wire format.
    static func decodeHop(_ data: Data) throws -> HopMessage {
        let fields: CircuitRelayHopFields
        do {
            fields = try CircuitRelayHopFields.decode(from: [UInt8](data))
        } catch {
            try rethrow(error)
        }
        return HopMessage(
            type: HopMessageType(rawValue: fields.typeRawValue) ?? .reserve,
            peer: try fields.peer.map(buildPeerInfo),
            reservation: try fields.reservation.map(buildReservation),
            limit: fields.limit.map(buildLimit),
            status: fields.statusRawValue.map { HopStatus(rawValue: $0) ?? .unknown }
        )
    }

    static func decodeHop(_ buffer: ByteBuffer) throws -> HopMessage {
        try decodeHop(Data(buffer: buffer))
    }

    private static func buildHopFields(_ message: HopMessage) -> CircuitRelayHopFields {
        CircuitRelayHopFields(
            typeRawValue: message.type.rawValue,
            peer: message.peer.map(buildPeerFields),
            reservation: message.reservation.map(buildReservationFields),
            limit: message.limit.map(buildLimitFields),
            statusRawValue: message.status?.rawValue
        )
    }

    // MARK: - StopMessage

    /// Encodes a StopMessage to protobuf wire format.
    static func encode(_ message: StopMessage) -> Data {
        Data(buildStopFields(message).encode())
    }

    static func encode(_ message: StopMessage, into buffer: inout ByteBuffer) {
        buffer.writeBytes(buildStopFields(message).encode())
    }

    /// Decodes a StopMessage from protobuf wire format.
    static func decodeStop(_ data: Data) throws -> StopMessage {
        let fields: CircuitRelayStopFields
        do {
            fields = try CircuitRelayStopFields.decode(from: [UInt8](data))
        } catch {
            try rethrow(error)
        }
        return StopMessage(
            type: StopMessageType(rawValue: fields.typeRawValue) ?? .connect,
            peer: try fields.peer.map(buildPeerInfo),
            limit: fields.limit.map(buildLimit),
            status: fields.statusRawValue.map { StopStatus(rawValue: $0) ?? .unknown }
        )
    }

    static func decodeStop(_ buffer: ByteBuffer) throws -> StopMessage {
        try decodeStop(Data(buffer: buffer))
    }

    private static func buildStopFields(_ message: StopMessage) -> CircuitRelayStopFields {
        CircuitRelayStopFields(
            typeRawValue: message.type.rawValue,
            peer: message.peer.map(buildPeerFields),
            limit: message.limit.map(buildLimitFields),
            statusRawValue: message.status?.rawValue
        )
    }

    // MARK: - Domain ↔ field bridging

    private static func buildPeerFields(_ peer: PeerInfo) -> CircuitRelayPeerFields {
        CircuitRelayPeerFields(
            id: [UInt8](peer.id.bytes),
            addresses: peer.addresses.map { [UInt8]($0.bytes) }
        )
    }

    private static func buildPeerInfo(_ fields: CircuitRelayPeerFields) throws -> PeerInfo {
        PeerInfo(
            id: try PeerID(bytes: Data(fields.id)),
            addresses: try fields.addresses.map { try Multiaddr(bytes: Data($0)) }
        )
    }

    private static func buildReservationFields(_ reservation: ReservationInfo) -> CircuitRelayReservationFields {
        CircuitRelayReservationFields(
            expiration: reservation.expiration,
            addresses: reservation.addresses.map { [UInt8]($0.bytes) },
            voucher: reservation.voucher.map { [UInt8]($0) }
        )
    }

    private static func buildReservation(_ fields: CircuitRelayReservationFields) throws -> ReservationInfo {
        ReservationInfo(
            expiration: fields.expiration,
            addresses: try fields.addresses.map { try Multiaddr(bytes: Data($0)) },
            voucher: fields.voucher.map { Data($0) }
        )
    }

    private static func buildLimitFields(_ limit: CircuitLimit) -> CircuitRelayLimitFields {
        CircuitRelayLimitFields(
            durationSeconds: limit.duration.map { UInt32($0.components.seconds) },
            data: limit.data
        )
    }

    private static func buildLimit(_ fields: CircuitRelayLimitFields) -> CircuitLimit {
        CircuitLimit(
            duration: fields.durationSeconds.map { Duration.seconds(Int64($0)) },
            data: fields.data
        )
    }

    /// Maps the cored codec's typed error to the adapter's error contract.
    private static func rethrow(_ error: CircuitRelayCodecError) throws -> Never {
        switch error {
        case .truncated:
            throw CircuitRelayError.encodingError("Field truncated")
        case .unknownWireType(let wireType):
            throw CircuitRelayError.encodingError("Unknown wire type \(wireType)")
        case .missingPeerID:
            throw CircuitRelayError.encodingError("Missing peer ID")
        case .voucherTooLarge(let size, let max):
            throw CircuitRelayError.encodingError("Voucher too large (\(size) > \(max))")
        }
    }
}
