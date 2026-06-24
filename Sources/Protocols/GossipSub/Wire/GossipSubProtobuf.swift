/// GossipSubProtobuf - Wire format encoding/decoding for GossipSub protocol
///
/// The wire framing lives in the Embedded-clean ``GossipSubRPCFields`` codec
/// (`LibP2PCore`); this adapter bridges the domain types — `PeerID`, `Topic`,
/// `MessageID`, and the assembled `GossipSubMessage` (whose ID is computed) —
/// to/from the codec's raw `[UInt8]` fields, and restores the historical
/// `Data`/`ByteBuffer` API.
///
/// Wire format follows the pubsub.proto specification:
/// https://github.com/libp2p/specs/blob/master/pubsub/README.md#the-rpc
import Foundation
import NIOCore
import P2PCore

/// Protobuf encoding/decoding for GossipSub RPC messages.
public enum GossipSubProtobuf {

    // MARK: - Decoding Limits (DoS hardening)

    /// Caps applied while decoding an RPC to bound attacker-controlled work and
    /// memory. Repeated elements beyond these counts are dropped at decode time
    /// (not silently — the surplus simply never enters the parsed structure,
    /// which the higher layers treat as the bounded RPC).
    ///
    /// This is a thin adapter mirror of the Embedded-clean
    /// ``GossipSubDecodingLimits`` core type, kept for source compatibility.
    public struct DecodingLimits: Sendable {
        public var maxMessages: Int
        public var maxSubscriptions: Int
        public var maxIHave: Int
        public var maxIWant: Int
        public var maxGraft: Int
        public var maxPrune: Int
        public var maxIDontWant: Int
        /// Maximum protobuf nesting depth (stack-exhaustion guard).
        public var maxNestingDepth: Int

        public init(
            maxMessages: Int = 1000,
            maxSubscriptions: Int = 200,
            maxIHave: Int = 100,
            maxIWant: Int = 100,
            maxGraft: Int = 100,
            maxPrune: Int = 100,
            maxIDontWant: Int = 100,
            maxNestingDepth: Int = 16
        ) {
            self.maxMessages = maxMessages
            self.maxSubscriptions = maxSubscriptions
            self.maxIHave = maxIHave
            self.maxIWant = maxIWant
            self.maxGraft = maxGraft
            self.maxPrune = maxPrune
            self.maxIDontWant = maxIDontWant
            self.maxNestingDepth = maxNestingDepth
        }

        /// Default limits used when no configuration-derived limits are supplied.
        public static let `default` = DecodingLimits()

        /// Bridges to the Embedded-clean core limits.
        fileprivate var core: GossipSubDecodingLimits {
            GossipSubDecodingLimits(
                maxMessages: maxMessages,
                maxSubscriptions: maxSubscriptions,
                maxIHave: maxIHave,
                maxIWant: maxIWant,
                maxGraft: maxGraft,
                maxPrune: maxPrune,
                maxIDontWant: maxIDontWant,
                maxNestingDepth: maxNestingDepth
            )
        }
    }

    // MARK: - Encoding

    /// Encodes a GossipSubRPC to protobuf wire format.
    public static func encode(_ rpc: GossipSubRPC) -> Data {
        Data(buildFields(rpc).encode())
    }

    public static func encode(_ rpc: GossipSubRPC, into buffer: inout ByteBuffer) {
        buffer.writeBytes(buildFields(rpc).encode())
    }

    /// Bridges a `GossipSubRPC` (domain types) into the cored raw-byte fields.
    private static func buildFields(_ rpc: GossipSubRPC) -> GossipSubRPCFields {
        GossipSubRPCFields(
            subscriptions: rpc.subscriptions.map {
                GossipSubSubOptFields(subscribe: $0.subscribe, topic: $0.topic.value)
            },
            messages: rpc.messages.map(buildMessageFields),
            control: rpc.control.map(buildControlFields)
        )
    }

    private static func buildMessageFields(_ message: GossipSubMessage) -> GossipSubMessageFields {
        GossipSubMessageFields(
            from: message.source.map { [UInt8]($0.bytes) },
            data: [UInt8](message.data),
            seqno: [UInt8](message.sequenceNumber),
            topic: message.topic.value,
            signature: message.signature.map { [UInt8]($0) },
            key: message.key.map { [UInt8]($0) }
        )
    }

    private static func buildControlFields(_ control: ControlMessageBatch) -> GossipSubControlFields {
        GossipSubControlFields(
            ihaves: control.ihaves.map {
                GossipSubIHaveFields(topic: $0.topic.value, messageIDs: $0.messageIDs.map { id in [UInt8](id.bytes) })
            },
            iwants: control.iwants.map {
                GossipSubIWantFields(messageIDs: $0.messageIDs.map { id in [UInt8](id.bytes) })
            },
            grafts: control.grafts.map {
                GossipSubGraftFields(topic: $0.topic.value)
            },
            prunes: control.prunes.map { prune in
                GossipSubPruneFields(
                    topic: prune.topic.value,
                    peers: prune.peers.map {
                        GossipSubPeerInfoFields(
                            peerID: [UInt8]($0.peerID.bytes),
                            signedPeerRecord: $0.signedPeerRecord.map { record in [UInt8](record) }
                        )
                    },
                    backoff: prune.backoff
                )
            },
            idontwants: control.idontwants.map {
                GossipSubIDontWantFields(messageIDs: $0.messageIDs.map { id in [UInt8](id.bytes) })
            }
        )
    }

    // MARK: - Decoding

    /// Decodes a GossipSubRPC from protobuf wire format.
    public static func decode(_ data: Data, limits: DecodingLimits = .default) throws -> GossipSubRPC {
        let fields: GossipSubRPCFields
        do {
            fields = try GossipSubRPCFields.decode(from: [UInt8](data), limits: limits.core)
        } catch {
            try rethrow(error)
        }

        let subscriptions = fields.subscriptions.map {
            GossipSubRPC.SubscriptionOpt(subscribe: $0.subscribe, topic: Topic($0.topic))
        }
        let messages = try fields.messages.map(buildMessage)
        let control = try fields.control.map(buildControl)

        return GossipSubRPC(subscriptions: subscriptions, messages: messages, control: control)
    }

    public static func decode(_ buffer: ByteBuffer, limits: DecodingLimits = .default) throws -> GossipSubRPC {
        try decode(Data(buffer: buffer), limits: limits)
    }

    private static func buildMessage(_ fields: GossipSubMessageFields) throws -> GossipSubMessage {
        let source = try fields.from.map { try PeerID(bytes: Data($0)) }
        // The default-ID constructor recomputes the message ID from source+seqno,
        // matching the historical decode path.
        return GossipSubMessage(
            source: source,
            data: Data(fields.data),
            sequenceNumber: Data(fields.seqno),
            topic: Topic(fields.topic),
            signature: fields.signature.map { Data($0) },
            key: fields.key.map { Data($0) }
        )
    }

    private static func buildControl(_ fields: GossipSubControlFields) throws -> ControlMessageBatch {
        var batch = ControlMessageBatch()
        batch.ihaves = fields.ihaves.map {
            ControlMessage.IHave(topic: Topic($0.topic), messageIDs: $0.messageIDs.map { MessageID(bytes: Data($0)) })
        }
        batch.iwants = fields.iwants.map {
            ControlMessage.IWant(messageIDs: $0.messageIDs.map { MessageID(bytes: Data($0)) })
        }
        batch.grafts = fields.grafts.map {
            ControlMessage.Graft(topic: Topic($0.topic))
        }
        batch.prunes = try fields.prunes.map { prune in
            let peers = try prune.peers.map {
                ControlMessage.Prune.PeerInfo(
                    peerID: try PeerID(bytes: Data($0.peerID)),
                    signedPeerRecord: $0.signedPeerRecord.map { record in Data(record) }
                )
            }
            return ControlMessage.Prune(topic: Topic(prune.topic), peers: peers, backoff: prune.backoff)
        }
        batch.idontwants = fields.idontwants.map {
            ControlMessage.IDontWant(messageIDs: $0.messageIDs.map { MessageID(bytes: Data($0)) })
        }
        return batch
    }

    /// Maps the cored codec's typed error to the adapter's error contract.
    private static func rethrow(_ error: GossipSubCodecError) throws -> Never {
        switch error {
        case .truncated:
            throw GossipSubError.invalidProtobuf("Field truncated")
        case .unknownWireType(let wireType):
            throw GossipSubError.invalidProtobuf("Unknown wire type \(wireType)")
        case .missingTopic:
            throw GossipSubError.invalidProtobuf("Missing topic")
        case .missingPeerID:
            throw GossipSubError.invalidProtobuf("Missing peerID in PeerInfo")
        case .maxNestingDepthExceeded:
            throw GossipSubError.invalidProtobuf("Maximum nesting depth exceeded")
        }
    }
}
