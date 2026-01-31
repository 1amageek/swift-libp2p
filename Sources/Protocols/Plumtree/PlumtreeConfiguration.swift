/// PlumtreeConfiguration - Configuration parameters for Plumtree protocol

/// Configuration for the Plumtree epidemic broadcast tree protocol.
public struct PlumtreeConfiguration: Sendable {

    /// Timeout before grafting a peer that sent IHave.
    ///
    /// When we receive an IHave for a message we haven't seen,
    /// we wait this long before sending GRAFT to the IHave sender.
    public var ihaveTimeout: Duration

    /// Delay for batching IHave notifications.
    ///
    /// IHave entries are collected and flushed at this interval
    /// to reduce per-message overhead on lazy links.
    public var lazyPushDelay: Duration

    /// Maximum number of IHave entries per flush batch.
    public var maxIHaveBatchSize: Int

    /// Maximum message payload size in bytes.
    public var maxMessageSize: Int

    /// How long to remember seen message IDs for deduplication.
    public var seenTTL: Duration

    /// Maximum number of entries in the seen message cache.
    public var maxSeenEntries: Int

    /// How long to store full messages for GRAFT re-sends.
    public var messageStoreTTL: Duration

    /// Maximum number of messages stored for GRAFT re-sends.
    public var maxStoredMessages: Int

    /// Creates a configuration with the specified parameters.
    public init(
        ihaveTimeout: Duration = .seconds(3),
        lazyPushDelay: Duration = .milliseconds(200),
        maxIHaveBatchSize: Int = 50,
        maxMessageSize: Int = 4 * 1024 * 1024,
        seenTTL: Duration = .seconds(120),
        maxSeenEntries: Int = 10000,
        messageStoreTTL: Duration = .seconds(60),
        maxStoredMessages: Int = 1000
    ) {
        self.ihaveTimeout = ihaveTimeout
        self.lazyPushDelay = lazyPushDelay
        self.maxIHaveBatchSize = maxIHaveBatchSize
        self.maxMessageSize = maxMessageSize
        self.seenTTL = seenTTL
        self.maxSeenEntries = maxSeenEntries
        self.messageStoreTTL = messageStoreTTL
        self.maxStoredMessages = maxStoredMessages
    }
}

// MARK: - Presets

extension PlumtreeConfiguration {

    /// Default production configuration.
    public static var `default`: PlumtreeConfiguration {
        PlumtreeConfiguration()
    }

    /// Configuration for testing with shorter timeouts.
    public static var testing: PlumtreeConfiguration {
        PlumtreeConfiguration(
            ihaveTimeout: .milliseconds(500),
            lazyPushDelay: .milliseconds(50),
            seenTTL: .seconds(10),
            messageStoreTTL: .seconds(10)
        )
    }
}
