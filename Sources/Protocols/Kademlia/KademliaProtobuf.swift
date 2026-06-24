/// KademliaProtobuf - Wire format encoding/decoding for Kademlia DHT.
///
/// The wire framing lives in the Embedded-clean ``KademliaFields`` codec
/// (`LibP2PCore`); this adapter bridges the domain types — `PeerID` and
/// `Multiaddr` — to/from the codec's raw `[UInt8]` fields, restores the
/// historical `Data`/`ByteBuffer` API, and resolves the typed `KademliaMessage`
/// shape from the message type plus field presence.
///
/// See: https://github.com/libp2p/specs/tree/master/kad-dht

import Foundation
import P2PCore
import NIOCore

/// Protobuf encoding/decoding for Kademlia messages.
enum KademliaProtobuf {

    /// Maximum number of peers accepted per repeated field (closerPeers /
    /// providerPeers) at decode time. Bounds an attacker's ability to inject a
    /// huge Sybil/eclipse peer list in a single response. Set generously to
    /// ~k so legitimate responses are unaffected.
    static let maxPeersPerMessage = KademliaProtocol.kValue * 2

    // MARK: - Message Encoding

    /// Encodes a KademliaMessage to protobuf wire format.
    static func encode(_ message: KademliaMessage) -> Data {
        Data(buildFields(message).encode())
    }

    static func encode(_ message: KademliaMessage, into data: inout Data) {
        data.append(contentsOf: buildFields(message).encode())
    }

    static func encode(_ message: KademliaMessage, into buffer: inout ByteBuffer) {
        buffer.writeBytes(buildFields(message).encode())
    }

    /// Bridges a `KademliaMessage` (domain types) into the cored raw-byte fields.
    private static func buildFields(_ message: KademliaMessage) -> KademliaFields {
        KademliaFields(
            typeRawValue: message.type.rawValue,
            key: message.key.map { [UInt8]($0) },
            record: message.record.map(buildRecordFields),
            closerPeers: message.closerPeers.map(buildPeerFields),
            providerPeers: message.providerPeers.map(buildPeerFields)
        )
    }

    private static func buildPeerFields(_ peer: KademliaPeer) -> KademliaPeerFields {
        KademliaPeerFields(
            id: [UInt8](peer.id.bytes),
            addresses: peer.addresses.map { [UInt8]($0.bytes) },
            connectionTypeRawValue: peer.connectionType.rawValue
        )
    }

    private static func buildRecordFields(_ record: KademliaRecord) -> KademliaRecordFields {
        KademliaRecordFields(
            key: [UInt8](record.key),
            value: [UInt8](record.value),
            timeReceived: record.timeReceived
        )
    }

    // MARK: - Message Decoding

    /// Decodes a KademliaMessage from protobuf wire format.
    static func decode(_ data: Data) throws -> KademliaMessage {
        let fields: KademliaFields
        do {
            fields = try KademliaFields.decode(from: [UInt8](data), maxPeers: maxPeersPerMessage)
        } catch {
            try rethrow(error)
        }

        let type = KademliaMessageType(rawValue: fields.typeRawValue) ?? .findNode
        let key = fields.key.map { Data($0) }
        let record = try fields.record.map(buildRecord)
        let closerPeers = try fields.closerPeers.map(buildPeer)
        let providerPeers = try fields.providerPeers.map(buildPeer)

        switch type {
        case .findNode:
            if closerPeers.isEmpty, let key {
                return .findNode(key: key)
            }
            return .findNodeResponse(closerPeers: closerPeers)

        case .getValue:
            if record != nil || !closerPeers.isEmpty {
                return .getValueResponse(record: record, closerPeers: closerPeers)
            }
            guard let key else {
                throw KademliaError.encodingError("Missing key in GET_VALUE")
            }
            return .getValue(key: key)

        case .putValue:
            guard let record else {
                throw KademliaError.encodingError("Missing record in PUT_VALUE")
            }
            return .putValue(record: record)

        case .addProvider:
            guard let key else {
                throw KademliaError.encodingError("Missing key in ADD_PROVIDER")
            }
            return .addProvider(key: key, providers: providerPeers)

        case .getProviders:
            if !providerPeers.isEmpty || !closerPeers.isEmpty {
                return .getProvidersResponse(providers: providerPeers, closerPeers: closerPeers)
            }
            guard let key else {
                throw KademliaError.encodingError("Missing key in GET_PROVIDERS")
            }
            return .getProviders(key: key)

        case .ping:
            throw KademliaError.protocolViolation("PING is deprecated")
        }
    }

    static func decode(_ buffer: ByteBuffer) throws -> KademliaMessage {
        try decode(Data(buffer: buffer))
    }

    private static func buildPeer(_ fields: KademliaPeerFields) throws -> KademliaPeer {
        let peerID = try PeerID(bytes: Data(fields.id))
        let addresses = try fields.addresses.map { try Multiaddr(bytes: Data($0)) }
        let connectionType = KademliaPeerConnectionType(rawValue: fields.connectionTypeRawValue) ?? .notConnected
        return KademliaPeer(id: peerID, addresses: addresses, connectionType: connectionType)
    }

    private static func buildRecord(_ fields: KademliaRecordFields) throws -> KademliaRecord {
        KademliaRecord(key: Data(fields.key), value: Data(fields.value), timeReceived: fields.timeReceived)
    }

    /// Maps the cored codec's typed error to the adapter's error contract.
    private static func rethrow(_ error: KademliaCodecError) throws -> Never {
        switch error {
        case .truncated:
            throw KademliaError.encodingError("Field truncated")
        case .unknownWireType(let wireType):
            throw KademliaError.encodingError("Unknown wire type \(wireType)")
        case .missingPeerID:
            throw KademliaError.encodingError("Missing peer ID")
        case .missingRecordField:
            throw KademliaError.encodingError("Missing key or value in record")
        case .recordValueTooLarge(let size, let max):
            throw KademliaError.encodingError("Record value too large (\(size) > \(max))")
        }
    }
}
