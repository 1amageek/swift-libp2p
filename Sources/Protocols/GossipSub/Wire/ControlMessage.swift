/// ControlMessage - GossipSub control messages for mesh management
import Foundation
import P2PCore

/// Control messages for GossipSub mesh management.
///
/// These messages are used to manage mesh membership and gossip state.
public enum ControlMessage: Sendable, Hashable {
    /// GRAFT: Request to add sender to mesh for a topic.
    case graft(Graft)

    /// PRUNE: Notify removal from mesh for a topic.
    case prune(Prune)

    /// IHAVE: Advertise message IDs the sender has.
    case ihave(IHave)

    /// IWANT: Request messages by their IDs.
    case iwant(IWant)

    /// IDONTWANT: Request not to receive certain messages (v1.2).
    case idontwant(IDontWant)
}

// MARK: - Control Message Types

extension ControlMessage {
    /// GRAFT message: Request to join a peer's mesh.
    ///
    /// Sent when a node wants to be added to the mesh for a topic.
    public struct Graft: Sendable, Hashable {
        /// The topic to graft into.
        public let topic: Topic

        public init(topic: Topic) {
            self.topic = topic
        }
    }

    /// PRUNE message: Notify removal from mesh.
    ///
    /// Sent when a node removes a peer from its mesh.
    public struct Prune: Sendable, Hashable {
        /// The topic being pruned from.
        public let topic: Topic

        /// Peer exchange: suggested peers to connect to (v1.1).
        public let peers: [PeerInfo]

        /// Backoff period in seconds before re-grafting (v1.1).
        public let backoff: UInt64?

        public init(topic: Topic, peers: [PeerInfo] = [], backoff: UInt64? = nil) {
            self.topic = topic
            self.peers = peers
            self.backoff = backoff
        }

        /// Peer information for peer exchange.
        public struct PeerInfo: Sendable, Hashable {
            /// The peer ID.
            public let peerID: PeerID

            /// Signed peer record (optional).
            public let signedPeerRecord: Data?

            public init(peerID: PeerID, signedPeerRecord: Data? = nil) {
                self.peerID = peerID
                self.signedPeerRecord = signedPeerRecord
            }
        }
    }

    /// IHAVE message: Advertise available messages.
    ///
    /// Sent during gossip to inform peers about messages we have.
    public struct IHave: Sendable, Hashable {
        /// The topic the messages belong to.
        public let topic: Topic

        /// The IDs of messages we have.
        public let messageIDs: [MessageID]

        public init(topic: Topic, messageIDs: [MessageID]) {
            self.topic = topic
            self.messageIDs = messageIDs
        }
    }

    /// IWANT message: Request messages by ID.
    ///
    /// Sent in response to IHAVE to request specific messages.
    public struct IWant: Sendable, Hashable {
        /// The IDs of messages we want.
        public let messageIDs: [MessageID]

        public init(messageIDs: [MessageID]) {
            self.messageIDs = messageIDs
        }
    }

    /// IDONTWANT message: Request not to receive messages (v1.2).
    ///
    /// Sent to prevent receiving duplicate large messages.
    public struct IDontWant: Sendable, Hashable {
        /// The IDs of messages we don't want.
        public let messageIDs: [MessageID]

        public init(messageIDs: [MessageID]) {
            self.messageIDs = messageIDs
        }
    }
}

// MARK: - ControlMessageBatch

/// A batch of control messages to send in a single RPC.
public struct ControlMessageBatch: Sendable {
    /// All GRAFT messages.
    public var grafts: [ControlMessage.Graft]

    /// All PRUNE messages.
    public var prunes: [ControlMessage.Prune]

    /// All IHAVE messages.
    public var ihaves: [ControlMessage.IHave]

    /// All IWANT messages.
    public var iwants: [ControlMessage.IWant]

    /// All IDONTWANT messages (v1.2).
    public var idontwants: [ControlMessage.IDontWant]

    /// Creates an empty batch.
    public init() {
        self.grafts = []
        self.prunes = []
        self.ihaves = []
        self.iwants = []
        self.idontwants = []
    }

    /// Whether the batch is empty.
    public var isEmpty: Bool {
        grafts.isEmpty && prunes.isEmpty && ihaves.isEmpty && iwants.isEmpty && idontwants.isEmpty
    }

    /// Adds a control message to the batch.
    public mutating func add(_ message: ControlMessage) {
        switch message {
        case .graft(let graft):
            grafts.append(graft)
        case .prune(let prune):
            prunes.append(prune)
        case .ihave(let ihave):
            ihaves.append(ihave)
        case .iwant(let iwant):
            iwants.append(iwant)
        case .idontwant(let idontwant):
            idontwants.append(idontwant)
        }
    }
}
