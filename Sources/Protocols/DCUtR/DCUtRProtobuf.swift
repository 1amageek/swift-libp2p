/// DCUtRProtobuf - Wire format encoding/decoding for DCUtR protocol.
///
/// The wire framing lives in the Embedded-clean ``DCUtRFields`` codec
/// (`LibP2PCore`); this adapter bridges the domain `Multiaddr` values to/from the
/// codec's raw `[UInt8]` fields, restores the historical `Data`/`ByteBuffer`
/// API, and resolves the typed `DCUtRMessage` (rejecting an absent / unknown
/// type and any malformed observed multiaddr).
///
/// See: https://github.com/libp2p/specs/blob/master/relay/DCUtR.md

import Foundation
import NIOCore
import P2PCore

/// Protobuf encoding/decoding for DCUtR messages.
enum DCUtRProtobuf {

    /// Maximum number of observed addresses accepted per message (DoS bound).
    static let maxObservedAddresses = 64

    // MARK: - Encoding

    /// Encodes a DCUtRMessage to protobuf wire format.
    static func encode(_ message: DCUtRMessage) -> Data {
        Data(buildFields(message).encode())
    }

    static func encode(_ message: DCUtRMessage, into buffer: inout ByteBuffer) {
        buffer.writeBytes(buildFields(message).encode())
    }

    private static func buildFields(_ message: DCUtRMessage) -> DCUtRFields {
        DCUtRFields(
            typeRawValue: message.type.rawValue,
            observedAddresses: message.observedAddresses.map { [UInt8]($0.bytes) }
        )
    }

    // MARK: - Decoding

    /// Decodes a DCUtRMessage from protobuf wire format.
    static func decode(_ data: Data) throws -> DCUtRMessage {
        let fields: DCUtRFields
        do {
            fields = try DCUtRFields.decode(from: [UInt8](data), maxObservedAddresses: maxObservedAddresses)
        } catch {
            try rethrow(error)
        }

        // The type field is required and must be a known value. Defaulting an
        // unknown/absent type silently would let a peer steer protocol behavior.
        guard let typeValue = fields.typeRawValue else {
            throw DCUtRError.protocolViolation("HolePunch message missing type field")
        }
        guard let type = DCUtRMessageType(rawValue: typeValue) else {
            throw DCUtRError.unknownMessageType(typeValue)
        }

        // Surface invalid multiaddrs rather than silently dropping them:
        // a malformed address indicates a malformed/hostile message.
        var addresses: [Multiaddr] = []
        addresses.reserveCapacity(fields.observedAddresses.count)
        for addrBytes in fields.observedAddresses {
            do {
                addresses.append(try Multiaddr(bytes: Data(addrBytes)))
            } catch {
                throw DCUtRError.invalidAddress("Invalid observed multiaddr: \(error)")
            }
        }

        return DCUtRMessage(type: type, observedAddresses: addresses)
    }

    static func decode(_ buffer: ByteBuffer) throws -> DCUtRMessage {
        try decode(Data(buffer: buffer))
    }

    /// Maps the cored codec's typed error to the adapter's error contract.
    private static func rethrow(_ error: DCUtRCodecError) throws -> Never {
        switch error {
        case .truncated:
            throw DCUtRError.encodingError("Field extends beyond data")
        case .unknownWireType(let wireType):
            throw DCUtRError.encodingError("Unknown wire type \(wireType)")
        case .tooManyObservedAddresses(let max):
            throw DCUtRError.encodingError("Too many observed addresses (max \(max))")
        }
    }
}
