/// Subscription - GossipSub topic subscription management
import Foundation
import Synchronization

/// A subscription to a GossipSub topic.
///
/// Provides an async stream of messages received on the topic.
public final class Subscription: Sendable {
    /// The subscribed topic.
    public let topic: Topic

    /// Internal state protected by mutex.
    private let state: Mutex<SubscriptionState>

    private struct SubscriptionState: Sendable {
        var continuation: AsyncStream<GossipSubMessage>.Continuation?
        var isCancelled: Bool = false
    }

    /// The stream of messages for this subscription.
    public let messages: AsyncStream<GossipSubMessage>

    /// Creates a new subscription for a topic.
    ///
    /// - Parameter topic: The topic to subscribe to
    init(topic: Topic) {
        self.topic = topic

        var capturedContinuation: AsyncStream<GossipSubMessage>.Continuation?
        self.messages = AsyncStream { continuation in
            capturedContinuation = continuation
        }

        self.state = Mutex(SubscriptionState(continuation: capturedContinuation))
    }

    /// Delivers a message to this subscription.
    ///
    /// - Parameter message: The message to deliver
    func deliver(_ message: GossipSubMessage) {
        state.withLock { state in
            guard !state.isCancelled else { return }
            state.continuation?.yield(message)
        }
    }

    /// Cancels the subscription.
    ///
    /// After cancellation, no more messages will be delivered.
    public func cancel() {
        state.withLock { state in
            state.isCancelled = true
            state.continuation?.finish()
            state.continuation = nil
        }
    }

    /// Whether the subscription is still active.
    public var isActive: Bool {
        state.withLock { !$0.isCancelled }
    }

    deinit {
        cancel()
    }
}

// MARK: - SubscriptionSet

/// A set of subscriptions for multiple topics.
///
/// Manages subscriptions and message delivery across topics.
final class SubscriptionSet: Sendable {
    private let subscriptions: Mutex<[Topic: [Subscription]]>

    init() {
        self.subscriptions = Mutex([:])
    }

    /// Adds a subscription for a topic.
    ///
    /// - Parameter subscription: The subscription to add
    func add(_ subscription: Subscription) {
        subscriptions.withLock { subs in
            subs[subscription.topic, default: []].append(subscription)
        }
    }

    /// Removes a subscription.
    ///
    /// - Parameter subscription: The subscription to remove
    func remove(_ subscription: Subscription) {
        subscriptions.withLock { subs in
            if var topicSubs = subs[subscription.topic] {
                topicSubs.removeAll { $0 === subscription }
                if topicSubs.isEmpty {
                    subs.removeValue(forKey: subscription.topic)
                } else {
                    subs[subscription.topic] = topicSubs
                }
            }
        }
    }

    /// Delivers a message to all subscriptions for its topic.
    ///
    /// - Parameter message: The message to deliver
    func deliver(_ message: GossipSubMessage) {
        let subs = subscriptions.withLock { $0[message.topic] ?? [] }
        for sub in subs {
            sub.deliver(message)
        }
    }

    /// Returns all topics with active subscriptions.
    var subscribedTopics: [Topic] {
        subscriptions.withLock { Array($0.keys) }
    }

    /// Returns whether there are any subscriptions for a topic.
    ///
    /// - Parameter topic: The topic to check
    func hasSubscribers(for topic: Topic) -> Bool {
        subscriptions.withLock { subs in
            guard let topicSubs = subs[topic] else { return false }
            return topicSubs.contains { $0.isActive }
        }
    }

    /// Cleans up cancelled subscriptions.
    func cleanup() {
        subscriptions.withLock { subs in
            for (topic, topicSubs) in subs {
                let active = topicSubs.filter { $0.isActive }
                if active.isEmpty {
                    subs.removeValue(forKey: topic)
                } else {
                    subs[topic] = active
                }
            }
        }
    }

    /// Cancels all subscriptions.
    func cancelAll() {
        subscriptions.withLock { subs in
            for (_, topicSubs) in subs {
                for sub in topicSubs {
                    sub.cancel()
                }
            }
            subs.removeAll()
        }
    }
}
