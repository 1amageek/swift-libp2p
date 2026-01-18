/// GossipSubRPC - Wire protocol message types for GossipSub
import Foundation
import P2PCore

/// An RPC message in the GossipSub protocol.
///
/// RPC messages carry subscriptions, published messages, and control messages.
public struct GossipSubRPC: Sendable {
    /// Subscription changes.
    public var subscriptions: [SubscriptionOpt]

    /// Published messages.
    public var messages: [GossipSubMessage]

    /// Control messages (mesh management).
    public var control: ControlMessageBatch?

    /// Creates an empty RPC.
    public init() {
        self.subscriptions = []
        self.messages = []
        self.control = nil
    }

    /// Creates an RPC with the given components.
    public init(
        subscriptions: [SubscriptionOpt] = [],
        messages: [GossipSubMessage] = [],
        control: ControlMessageBatch? = nil
    ) {
        self.subscriptions = subscriptions
        self.messages = messages
        self.control = control
    }

    /// Whether the RPC is empty.
    public var isEmpty: Bool {
        subscriptions.isEmpty && messages.isEmpty && (control?.isEmpty ?? true)
    }
}

// MARK: - SubscriptionOpt

extension GossipSubRPC {
    /// A subscription option (subscribe or unsubscribe from a topic).
    public struct SubscriptionOpt: Sendable, Hashable {
        /// Whether this is a subscribe (true) or unsubscribe (false).
        public let subscribe: Bool

        /// The topic ID.
        public let topic: Topic

        /// Creates a subscribe action.
        public static func subscribe(to topic: Topic) -> SubscriptionOpt {
            SubscriptionOpt(subscribe: true, topic: topic)
        }

        /// Creates an unsubscribe action.
        public static func unsubscribe(from topic: Topic) -> SubscriptionOpt {
            SubscriptionOpt(subscribe: false, topic: topic)
        }

        public init(subscribe: Bool, topic: Topic) {
            self.subscribe = subscribe
            self.topic = topic
        }
    }
}

// MARK: - RPC Builder

extension GossipSubRPC {
    /// Builder for constructing RPC messages.
    public struct Builder {
        private var rpc: GossipSubRPC

        /// Creates a new builder.
        public init() {
            self.rpc = GossipSubRPC()
        }

        /// Adds a subscription.
        public func subscribe(to topic: Topic) -> Builder {
            var copy = self
            copy.rpc.subscriptions.append(.subscribe(to: topic))
            return copy
        }

        /// Adds an unsubscription.
        public func unsubscribe(from topic: Topic) -> Builder {
            var copy = self
            copy.rpc.subscriptions.append(.unsubscribe(from: topic))
            return copy
        }

        /// Adds a message to publish.
        public func publish(_ message: GossipSubMessage) -> Builder {
            var copy = self
            copy.rpc.messages.append(message)
            return copy
        }

        /// Adds a control message.
        public func control(_ message: ControlMessage) -> Builder {
            var copy = self
            if copy.rpc.control == nil {
                copy.rpc.control = ControlMessageBatch()
            }
            copy.rpc.control?.add(message)
            return copy
        }

        /// Adds a GRAFT control message.
        public func graft(topic: Topic) -> Builder {
            control(.graft(.init(topic: topic)))
        }

        /// Adds a PRUNE control message.
        public func prune(
            topic: Topic,
            peers: [ControlMessage.Prune.PeerInfo] = [],
            backoff: UInt64? = nil
        ) -> Builder {
            control(.prune(.init(topic: topic, peers: peers, backoff: backoff)))
        }

        /// Adds an IHAVE control message.
        public func ihave(topic: Topic, messageIDs: [MessageID]) -> Builder {
            control(.ihave(.init(topic: topic, messageIDs: messageIDs)))
        }

        /// Adds an IWANT control message.
        public func iwant(messageIDs: [MessageID]) -> Builder {
            control(.iwant(.init(messageIDs: messageIDs)))
        }

        /// Builds the RPC message.
        public func build() -> GossipSubRPC {
            rpc
        }
    }

    /// Creates a new builder.
    public static func builder() -> Builder {
        Builder()
    }
}

// MARK: - Protocol IDs

/// GossipSub protocol identifiers.
public enum GossipSubProtocolID {
    /// MeshSub v1.0 (base GossipSub).
    public static let meshsub10 = "/meshsub/1.0.0"

    /// MeshSub v1.1 (peer exchange, backoff).
    public static let meshsub11 = "/meshsub/1.1.0"

    /// MeshSub v1.2 (IDONTWANT).
    public static let meshsub12 = "/meshsub/1.2.0"

    /// FloodSub v1.0 (backward compatibility).
    public static let floodsub = "/floodsub/1.0.0"

    /// All supported protocol IDs in order of preference.
    public static let all: [String] = [meshsub12, meshsub11, meshsub10, floodsub]
}
