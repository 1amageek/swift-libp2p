/// PrometheusExporter - Prometheus text exposition format metrics exporter
///
/// Thread-safe via `Mutex`. Collects counters, gauges, and histograms,
/// and produces the Prometheus text exposition format via `scrape()`.

import Synchronization

/// Exports metrics in Prometheus text exposition format.
///
/// Supports counter, gauge, and histogram metric types. All operations
/// are thread-safe and designed for high-frequency recording.
///
/// Usage:
/// ```swift
/// let exporter = PrometheusExporter()
/// exporter.register(.counter, name: LibP2PMetrics.connectionsTotal, help: "Total connections")
/// exporter.increment(LibP2PMetrics.connectionsTotal, by: 1, labels: ["transport": "tcp"])
/// let output = exporter.scrape()
/// ```
public final class PrometheusExporter: MetricsExporter, Sendable {

    private let state: Mutex<ExporterState>

    /// Default histogram bucket boundaries.
    public static let defaultBuckets: [Double] = [
        0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0
    ]

    private struct ExporterState: Sendable {
        var registrations: [MetricName: MetricRegistration] = [:]
        var counters: [MetricKey: Double] = [:]
        var gauges: [MetricKey: Double] = [:]
        var histograms: [MetricKey: HistogramData] = [:]
    }

    /// Registration info for a metric.
    private struct MetricRegistration: Sendable {
        let type: MetricType
        let help: String
        let buckets: [Double]  // Only used for histograms
    }

    /// Key that uniquely identifies a metric time series (name + labels).
    private struct MetricKey: Hashable, Sendable {
        let name: MetricName
        let labels: [String: String]
    }

    /// Histogram data for a single time series.
    private struct HistogramData: Sendable {
        var bucketCounts: [Double: UInt64]  // upper bound -> cumulative count
        var sum: Double
        var count: UInt64
        let boundaries: [Double]

        init(boundaries: [Double]) {
            self.boundaries = boundaries.sorted()
            self.bucketCounts = [:]
            for b in self.boundaries {
                self.bucketCounts[b] = 0
            }
            self.sum = 0
            self.count = 0
        }
    }

    /// Creates a new Prometheus exporter.
    public init() {
        self.state = Mutex(ExporterState())
    }

    // MARK: - Registration

    /// Registers a metric with its type and help text.
    ///
    /// Registration is optional but recommended. Registered metrics include
    /// `# HELP` and `# TYPE` annotations in the scrape output.
    ///
    /// - Parameters:
    ///   - type: The metric type (counter, gauge, histogram).
    ///   - name: The metric name.
    ///   - help: Human-readable description.
    ///   - buckets: Histogram bucket boundaries (ignored for counter/gauge).
    public func register(
        _ type: MetricType,
        name: MetricName,
        help: String,
        buckets: [Double] = PrometheusExporter.defaultBuckets
    ) {
        state.withLock { s in
            s.registrations[name] = MetricRegistration(
                type: type,
                help: help,
                buckets: buckets.sorted()
            )
        }
    }

    // MARK: - MetricsExporter

    /// Increments a counter metric.
    ///
    /// Negative values are ignored (counters only increase).
    public func increment(_ metric: MetricName, by value: Double, labels: [String: String]) {
        guard value >= 0 else { return }
        let key = MetricKey(name: metric, labels: labels)
        state.withLock { s in
            s.counters[key, default: 0] += value
        }
    }

    /// Sets a gauge metric to the given value.
    public func set(_ metric: MetricName, to value: Double, labels: [String: String]) {
        let key = MetricKey(name: metric, labels: labels)
        state.withLock { s in
            s.gauges[key] = value
        }
    }

    /// Records an observation for a histogram metric.
    public func observe(_ metric: MetricName, value: Double, labels: [String: String]) {
        let key = MetricKey(name: metric, labels: labels)
        state.withLock { s in
            let boundaries = s.registrations[metric]?.buckets
                ?? PrometheusExporter.defaultBuckets
            if s.histograms[key] == nil {
                s.histograms[key] = HistogramData(boundaries: boundaries)
            }
            s.histograms[key]!.sum += value
            s.histograms[key]!.count += 1
            for boundary in s.histograms[key]!.boundaries {
                if value <= boundary {
                    s.histograms[key]!.bucketCounts[boundary, default: 0] += 1
                }
            }
        }
    }

    // MARK: - Scrape

    /// Produces the Prometheus text exposition format output.
    ///
    /// Includes `# HELP` and `# TYPE` lines for registered metrics,
    /// followed by metric values. Unregistered metrics are still included
    /// but without annotations.
    ///
    /// - Returns: A string in Prometheus text exposition format.
    public func scrape() -> String {
        state.withLock { s in
            var output = ""

            // Collect all metric names that have data
            var metricNames: [MetricName] = []
            var seen = Set<MetricName>()

            for key in s.counters.keys {
                if seen.insert(key.name).inserted {
                    metricNames.append(key.name)
                }
            }
            for key in s.gauges.keys {
                if seen.insert(key.name).inserted {
                    metricNames.append(key.name)
                }
            }
            for key in s.histograms.keys {
                if seen.insert(key.name).inserted {
                    metricNames.append(key.name)
                }
            }

            // Sort for deterministic output
            metricNames.sort { $0.name < $1.name }

            for metricName in metricNames {
                // Write HELP and TYPE if registered
                if let reg = s.registrations[metricName] {
                    output += "# HELP \(metricName.name) \(reg.help)\n"
                    output += "# TYPE \(metricName.name) \(Self.prometheusTypeName(reg.type))\n"
                }

                // Write counter values
                let counterKeys = s.counters.keys
                    .filter { $0.name == metricName }
                    .sorted { Self.labelsString($0.labels) < Self.labelsString($1.labels) }
                for key in counterKeys {
                    let labelsStr = Self.labelsString(key.labels)
                    let value = s.counters[key]!
                    output += "\(metricName.name)\(labelsStr) \(Self.formatValue(value))\n"
                }

                // Write gauge values
                let gaugeKeys = s.gauges.keys
                    .filter { $0.name == metricName }
                    .sorted { Self.labelsString($0.labels) < Self.labelsString($1.labels) }
                for key in gaugeKeys {
                    let labelsStr = Self.labelsString(key.labels)
                    let value = s.gauges[key]!
                    output += "\(metricName.name)\(labelsStr) \(Self.formatValue(value))\n"
                }

                // Write histogram values
                let histKeys = s.histograms.keys
                    .filter { $0.name == metricName }
                    .sorted { Self.labelsString($0.labels) < Self.labelsString($1.labels) }
                for key in histKeys {
                    let hist = s.histograms[key]!
                    let baseLabelPairs = Self.labelPairs(key.labels)

                    // Cumulative bucket lines
                    for boundary in hist.boundaries {
                        let count = hist.bucketCounts[boundary, default: 0]
                        var bucketLabels = baseLabelPairs
                        bucketLabels.append("le=\"\(Self.formatValue(boundary))\"")
                        output += "\(metricName.name)_bucket{\(bucketLabels.joined(separator: ","))} \(count)\n"
                    }
                    // +Inf bucket
                    var infLabels = baseLabelPairs
                    infLabels.append("le=\"+Inf\"")
                    output += "\(metricName.name)_bucket{\(infLabels.joined(separator: ","))} \(hist.count)\n"

                    // Sum and count
                    let labelsStr = Self.labelsString(key.labels)
                    output += "\(metricName.name)_sum\(labelsStr) \(Self.formatValue(hist.sum))\n"
                    output += "\(metricName.name)_count\(labelsStr) \(hist.count)\n"
                }
            }

            return output
        }
    }

    // MARK: - Reset

    /// Resets all collected metric values.
    ///
    /// Registrations are preserved; only data is cleared.
    public func reset() {
        state.withLock { s in
            s.counters.removeAll()
            s.gauges.removeAll()
            s.histograms.removeAll()
        }
    }

    // MARK: - Helpers

    /// Formats label pairs as a Prometheus labels string.
    ///
    /// Returns `{key1="value1",key2="value2"}` or empty string if no labels.
    private static func labelsString(_ labels: [String: String]) -> String {
        guard !labels.isEmpty else { return "" }
        let pairs = labelPairs(labels)
        return "{\(pairs.joined(separator: ","))}"
    }

    /// Produces sorted label pairs in `key="value"` format.
    ///
    /// Label values are escaped per the Prometheus text exposition format:
    /// backslash, double-quote, and newline are escaped.
    private static func labelPairs(_ labels: [String: String]) -> [String] {
        labels.sorted { $0.key < $1.key }
            .map { "\($0.key)=\"\(escapePrometheusLabelValue($0.value))\"" }
    }

    /// Escapes a label value for the Prometheus text exposition format.
    ///
    /// Backslash (`\`) becomes `\\`, double-quote (`"`) becomes `\"`,
    /// and newline (`\n`) becomes `\n` (literal backslash-n).
    private static func escapePrometheusLabelValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    /// Formats a double value for Prometheus output.
    ///
    /// Special values are formatted per the Prometheus spec:
    /// `NaN` for not-a-number, `+Inf` / `-Inf` for infinities.
    /// Integers are formatted without decimal points (e.g., "5" not "5.0").
    private static func formatValue(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value > 0 ? "+Inf" : "-Inf" }
        if value == value.rounded() && !value.isZero {
            return String(format: "%.0f", value)
        }
        return "\(value)"
    }

    /// Returns the Prometheus type name string.
    private static func prometheusTypeName(_ type: MetricType) -> String {
        switch type {
        case .counter: return "counter"
        case .gauge: return "gauge"
        case .histogram: return "histogram"
        }
    }
}
