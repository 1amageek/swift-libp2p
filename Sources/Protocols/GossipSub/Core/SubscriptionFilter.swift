/// SubscriptionFilter - Filters topic subscriptions (local and remote).
import Foundation
import P2PCore

/// Filters topic subscriptions (local and remote).
public protocol TopicSubscriptionFilter: Sendable {
    /// Whether the local node can subscribe to this topic.
    func canSubscribe(to topic: Topic) -> Bool

    /// Filters incoming remote subscriptions.
    /// Returns the set of subscriptions that should be accepted.
    /// Throwing discards the entire RPC from that peer.
    func filterIncomingSubscriptions(
        _ subscriptions: [GossipSubRPC.SubscriptionOpt],
        currentlySubscribed: Set<Topic>
    ) throws -> [GossipSubRPC.SubscriptionOpt]
}

/// Default: accept all subscriptions.
public struct AllowAllSubscriptionFilter: TopicSubscriptionFilter {
    public init() {}

    public func canSubscribe(to topic: Topic) -> Bool { true }

    public func filterIncomingSubscriptions(
        _ subscriptions: [GossipSubRPC.SubscriptionOpt],
        currentlySubscribed: Set<Topic>
    ) throws -> [GossipSubRPC.SubscriptionOpt] {
        subscriptions
    }
}

/// Only accept subscriptions for whitelisted topics.
public struct WhitelistSubscriptionFilter: TopicSubscriptionFilter {
    private let allowedTopics: Set<Topic>

    public init(allowedTopics: Set<Topic>) {
        self.allowedTopics = allowedTopics
    }

    public func canSubscribe(to topic: Topic) -> Bool {
        allowedTopics.contains(topic)
    }

    public func filterIncomingSubscriptions(
        _ subscriptions: [GossipSubRPC.SubscriptionOpt],
        currentlySubscribed: Set<Topic>
    ) throws -> [GossipSubRPC.SubscriptionOpt] {
        subscriptions.filter { allowedTopics.contains($0.topic) }
    }
}

/// Limits the maximum number of subscriptions per peer.
public struct MaxCountSubscriptionFilter: TopicSubscriptionFilter {
    private let inner: any TopicSubscriptionFilter
    private let maxSubscriptionsPerPeer: Int
    private let maxSubscriptionsPerRequest: Int

    public init(
        inner: any TopicSubscriptionFilter = AllowAllSubscriptionFilter(),
        maxSubscriptionsPerPeer: Int = 1000,
        maxSubscriptionsPerRequest: Int = 100
    ) {
        self.inner = inner
        self.maxSubscriptionsPerPeer = maxSubscriptionsPerPeer
        self.maxSubscriptionsPerRequest = maxSubscriptionsPerRequest
    }

    public func canSubscribe(to topic: Topic) -> Bool {
        inner.canSubscribe(to: topic)
    }

    public func filterIncomingSubscriptions(
        _ subscriptions: [GossipSubRPC.SubscriptionOpt],
        currentlySubscribed: Set<Topic>
    ) throws -> [GossipSubRPC.SubscriptionOpt] {
        guard subscriptions.count <= maxSubscriptionsPerRequest else {
            throw GossipSubError.tooManySubscriptions(
                count: subscriptions.count,
                limit: maxSubscriptionsPerRequest
            )
        }

        let newSubscribeCount = subscriptions.filter {
            $0.subscribe && !currentlySubscribed.contains($0.topic)
        }.count
        guard currentlySubscribed.count + newSubscribeCount <= maxSubscriptionsPerPeer else {
            throw GossipSubError.tooManySubscriptions(
                count: currentlySubscribed.count + newSubscribeCount,
                limit: maxSubscriptionsPerPeer
            )
        }

        return try inner.filterIncomingSubscriptions(subscriptions, currentlySubscribed: currentlySubscribed)
    }
}
