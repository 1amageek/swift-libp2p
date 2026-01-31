/// Configuration for the CYCLON peer sampling protocol.

/// Parameters controlling CYCLON's shuffle behavior.
public struct CYCLONConfiguration: Sendable {

    /// Size of the partial view (number of peers to track).
    public var cacheSize: Int

    /// Number of entries to exchange per shuffle.
    public var shuffleLength: Int

    /// Interval between shuffle operations.
    public var shufflePeriod: Duration

    /// Timeout for a single shuffle request/response exchange.
    public var shuffleTimeout: Duration

    /// Maximum age before a peer entry is considered stale.
    public var maxAge: UInt64

    public init(
        cacheSize: Int = 20,
        shuffleLength: Int = 10,
        shufflePeriod: Duration = .seconds(5),
        shuffleTimeout: Duration = .seconds(10),
        maxAge: UInt64 = 100
    ) {
        self.cacheSize = cacheSize
        self.shuffleLength = shuffleLength
        self.shufflePeriod = shufflePeriod
        self.shuffleTimeout = shuffleTimeout
        self.maxAge = maxAge
    }

    /// Default configuration.
    public static let `default` = CYCLONConfiguration()

    /// Testing configuration with faster shuffle cycles.
    public static let testing = CYCLONConfiguration(
        cacheSize: 5,
        shuffleLength: 3,
        shufflePeriod: .milliseconds(500),
        shuffleTimeout: .seconds(2),
        maxAge: 20
    )
}
