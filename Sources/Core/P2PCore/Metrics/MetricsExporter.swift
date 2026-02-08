/// MetricsExporter - Protocol and types for metrics collection
///
/// Defines the interface for exporting metrics from libp2p components.
/// Metrics follow the counter/gauge/histogram model compatible with
/// Prometheus and similar monitoring systems.

/// A metric name identifier.
///
/// Wraps a string name and provides type safety for metric identification.
/// Supports `ExpressibleByStringLiteral` for convenient inline usage.
public struct MetricName: Sendable, Hashable, ExpressibleByStringLiteral {
    /// The string name of the metric.
    public let name: String

    /// Creates a metric name from a string.
    public init(_ name: String) {
        self.name = name
    }

    /// Creates a metric name from a string literal.
    public init(stringLiteral value: String) {
        self.name = value
    }
}

/// The type of a metric.
public enum MetricType: Sendable {
    /// A monotonically increasing counter (e.g., total bytes sent).
    case counter
    /// A value that can go up and down (e.g., active connections).
    case gauge
    /// A distribution of observed values (e.g., request latencies).
    case histogram
}

/// Protocol for exporting metrics from libp2p components.
///
/// Implementations collect and expose metrics in a specific format
/// (e.g., Prometheus text exposition format).
public protocol MetricsExporter: Sendable {
    /// Increments a counter metric by the given amount.
    ///
    /// - Parameters:
    ///   - metric: The metric name to increment.
    ///   - by: The amount to increment by (must be non-negative).
    ///   - labels: Key-value pairs for dimensional data.
    func increment(_ metric: MetricName, by: Double, labels: [String: String])

    /// Sets a gauge metric to the given value.
    ///
    /// - Parameters:
    ///   - metric: The metric name to set.
    ///   - to: The value to set the gauge to.
    ///   - labels: Key-value pairs for dimensional data.
    func set(_ metric: MetricName, to: Double, labels: [String: String])

    /// Records an observation for a histogram metric.
    ///
    /// - Parameters:
    ///   - metric: The metric name to observe.
    ///   - value: The observed value.
    ///   - labels: Key-value pairs for dimensional data.
    func observe(_ metric: MetricName, value: Double, labels: [String: String])
}

// MARK: - Standard libp2p Metrics

/// Standard metric names for libp2p components.
public enum LibP2PMetrics {
    /// Total number of connections established (counter).
    public static let connectionsTotal: MetricName = "libp2p_connections_total"
    /// Number of currently active connections (gauge).
    public static let connectionsActive: MetricName = "libp2p_connections_active"
    /// Total bytes sent across all connections (counter).
    public static let bytesSentTotal: MetricName = "libp2p_bytes_sent_total"
    /// Total bytes received across all connections (counter).
    public static let bytesReceivedTotal: MetricName = "libp2p_bytes_received_total"
    /// Total number of streams opened (counter).
    public static let streamsOpenedTotal: MetricName = "libp2p_streams_opened_total"
    /// Total number of peers discovered (counter).
    public static let peersDiscoveredTotal: MetricName = "libp2p_peers_discovered_total"
}
