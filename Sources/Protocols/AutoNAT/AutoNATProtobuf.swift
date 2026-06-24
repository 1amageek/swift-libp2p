/// AutoNATProtobuf - Wire format encoding/decoding for AutoNAT v1
///
/// The wire framing lives in the Embedded-clean ``AutoNATFields`` codec
/// (`LibP2PCore`); this adapter bridges the domain types — `PeerID` and
/// `Multiaddr` — to/from the codec's raw `[UInt8]` fields, restores the
/// historical `Data`/`ByteBuffer` API, and resolves the typed `AutoNATMessage`
/// shape from the message type.
///
/// See: https://github.com/libp2p/specs/blob/master/autonat/README.md

import Foundation
import NIOCore
import P2PCore

/// Protobuf encoding/decoding for AutoNAT messages.
enum AutoNATProtobuf {

    // MARK: - Encoding

    /// Encodes an AutoNATMessage to protobuf wire format.
    static func encode(_ message: AutoNATMessage) -> Data {
        Data(buildFields(message).encode())
    }

    static func encode(_ message: AutoNATMessage, into buffer: inout ByteBuffer) {
        buffer.writeBytes(buildFields(message).encode())
    }

    private static func buildFields(_ message: AutoNATMessage) -> AutoNATFields {
        AutoNATFields(
            typeRawValue: message.type.rawValue,
            dialPeer: message.dial.map { buildPeerFields($0.peer) },
            dialResponse: message.dialResponse.map(buildResponseFields)
        )
    }

    private static func buildPeerFields(_ peer: AutoNATPeerInfo) -> AutoNATPeerInfoFields {
        AutoNATPeerInfoFields(
            id: peer.id.map { [UInt8]($0.bytes) },
            addresses: peer.addresses.map { [UInt8]($0.bytes) }
        )
    }

    private static func buildResponseFields(_ response: AutoNATDialResponse) -> AutoNATDialResponseFields {
        AutoNATDialResponseFields(
            statusRawValue: response.status.rawValue,
            statusText: response.statusText,
            address: response.address.map { [UInt8]($0.bytes) }
        )
    }

    // MARK: - Decoding

    /// Decodes an AutoNATMessage from protobuf wire format.
    static func decode(_ data: Data) throws -> AutoNATMessage {
        let fields: AutoNATFields
        do {
            fields = try AutoNATFields.decode(from: [UInt8](data))
        } catch {
            try rethrow(error)
        }

        let type = AutoNATMessageType(rawValue: fields.typeRawValue) ?? .dial
        switch type {
        case .dial:
            guard let dialPeer = fields.dialPeer else {
                throw AutoNATError.protocolViolation("Missing dial in DIAL message")
            }
            return .dial(peer: try buildPeerInfo(dialPeer))

        case .dialResponse:
            guard let response = fields.dialResponse else {
                throw AutoNATError.protocolViolation("Missing dialResponse in DIAL_RESPONSE message")
            }
            return .dialResponse(try buildResponse(response))
        }
    }

    static func decode(_ buffer: ByteBuffer) throws -> AutoNATMessage {
        try decode(Data(buffer: buffer))
    }

    private static func buildPeerInfo(_ fields: AutoNATPeerInfoFields) throws -> AutoNATPeerInfo {
        AutoNATPeerInfo(
            id: try fields.id.map { try PeerID(bytes: Data($0)) },
            addresses: try fields.addresses.map { try Multiaddr(bytes: Data($0)) }
        )
    }

    private static func buildResponse(_ fields: AutoNATDialResponseFields) throws -> AutoNATDialResponse {
        AutoNATDialResponse(
            status: AutoNATResponseStatus(rawValue: fields.statusRawValue),
            statusText: fields.statusText,
            address: try fields.address.map { try Multiaddr(bytes: Data($0)) }
        )
    }

    /// Maps the cored codec's typed error to the adapter's error contract.
    private static func rethrow(_ error: AutoNATCodecError) throws -> Never {
        switch error {
        case .truncated:
            throw AutoNATError.protocolViolation("Field truncated")
        case .unknownWireType(let wireType):
            throw AutoNATError.protocolViolation("Unknown wire type \(wireType)")
        case .missingPeer:
            throw AutoNATError.protocolViolation("Missing peer in Dial")
        }
    }
}
