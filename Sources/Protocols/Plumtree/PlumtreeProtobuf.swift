/// PlumtreeProtobuf - Wire format encoding/decoding for Plumtree protocol
///
/// The wire framing lives in the Embedded-clean ``PlumtreeRPCFields`` codec
/// (`LibP2PCore`); this adapter bridges the domain types — `PlumtreeMessageID`
/// and `PeerID` — to/from the codec's raw `[UInt8]` fields and restores the
/// historical `Data`/`ByteBuffer` API.
import Foundation
import NIOCore
import P2PCore

/// Protobuf encoding/decoding for Plumtree RPC messages.
public enum PlumtreeProtobuf {

    /// Maximum number of elements (per repeated field) accepted in a single RPC.
    ///
    /// Bounds the work an attacker can force per message and the fan-out of a
    /// single forwarded RPC, mitigating decode/forwarding amplification.
    public static let maxElementsPerRPC = PlumtreeRPCFields.maxElementsPerRPC

    // MARK: - Encoding

    /// Encodes a PlumtreeRPC to protobuf wire format.
    public static func encode(_ rpc: PlumtreeRPC) -> Data {
        Data(buildFields(rpc).encode())
    }

    public static func encode(_ rpc: PlumtreeRPC, into buffer: inout ByteBuffer) {
        buffer.writeBytes(buildFields(rpc).encode())
    }

    private static func buildFields(_ rpc: PlumtreeRPC) -> PlumtreeRPCFields {
        PlumtreeRPCFields(
            gossipMessages: rpc.gossipMessages.map {
                PlumtreeGossipFields(
                    messageID: [UInt8]($0.messageID.bytes),
                    topic: $0.topic,
                    data: [UInt8]($0.data),
                    source: [UInt8]($0.source.bytes),
                    hopCount: $0.hopCount
                )
            },
            ihaveEntries: rpc.ihaveEntries.map {
                PlumtreeIHaveFields(messageID: [UInt8]($0.messageID.bytes), topic: $0.topic)
            },
            graftRequests: rpc.graftRequests.map {
                PlumtreeGraftFields(topic: $0.topic, messageID: $0.messageID.map { id in [UInt8](id.bytes) })
            },
            pruneRequests: rpc.pruneRequests.map {
                PlumtreePruneFields(topic: $0.topic)
            }
        )
    }

    // MARK: - Decoding

    /// Decodes a PlumtreeRPC from protobuf wire format.
    public static func decode(_ data: Data) throws -> PlumtreeRPC {
        let fields: PlumtreeRPCFields
        do {
            fields = try PlumtreeRPCFields.decode(from: [UInt8](data))
        } catch {
            try rethrow(error)
        }

        let gossipMessages = try fields.gossipMessages.map { g -> PlumtreeGossip in
            PlumtreeGossip(
                messageID: PlumtreeMessageID(bytes: Data(g.messageID)),
                topic: g.topic,
                data: Data(g.data),
                source: try PeerID(bytes: Data(g.source)),
                hopCount: g.hopCount
            )
        }
        let ihaveEntries = fields.ihaveEntries.map {
            PlumtreeIHaveEntry(messageID: PlumtreeMessageID(bytes: Data($0.messageID)), topic: $0.topic)
        }
        let graftRequests = fields.graftRequests.map {
            PlumtreeGraftRequest(topic: $0.topic, messageID: $0.messageID.map { id in PlumtreeMessageID(bytes: Data(id)) })
        }
        let pruneRequests = fields.pruneRequests.map {
            PlumtreePruneRequest(topic: $0.topic)
        }

        return PlumtreeRPC(
            gossipMessages: gossipMessages,
            ihaveEntries: ihaveEntries,
            graftRequests: graftRequests,
            pruneRequests: pruneRequests
        )
    }

    public static func decode(_ buffer: ByteBuffer) throws -> PlumtreeRPC {
        try decode(Data(buffer: buffer))
    }

    /// Maps the cored codec's typed error to the adapter's error contract.
    private static func rethrow(_ error: PlumtreeCodecError) throws -> Never {
        switch error {
        case .empty:
            throw PlumtreeError.decodingFailed("Empty data")
        case .truncated:
            throw PlumtreeError.decodingFailed("Field truncated")
        case .unknownWireType(let wireType):
            throw PlumtreeError.decodingFailed("Unknown wire type \(wireType)")
        case .tooManyElements:
            throw PlumtreeError.decodingFailed("Too many elements in RPC")
        case .missingField:
            throw PlumtreeError.decodingFailed("Missing required field")
        case .invalidTopicUTF8:
            throw PlumtreeError.decodingFailed("Invalid topic UTF-8")
        }
    }
}
