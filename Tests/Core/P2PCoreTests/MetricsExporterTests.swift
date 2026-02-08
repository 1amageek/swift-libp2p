import Testing
@testable import P2PCore

@Suite("MetricsExporter")
struct MetricsExporterTests {

    // MARK: - MetricName

    @Test("MetricName equality and hashing")
    func metricNameEquality() {
        let a: MetricName = "libp2p_test"
        let b = MetricName("libp2p_test")
        let c: MetricName = "libp2p_other"

        #expect(a == b)
        #expect(a != c)
        #expect(a.hashValue == b.hashValue)
        #expect(a.name == "libp2p_test")
    }

    @Test("MetricName string literal initialization")
    func metricNameStringLiteral() {
        let name: MetricName = "my_metric"
        #expect(name.name == "my_metric")
    }

    @Test("MetricName in set and dictionary")
    func metricNameCollections() {
        let a: MetricName = "metric_a"
        let b: MetricName = "metric_b"
        let aDuplicate: MetricName = "metric_a"

        var nameSet: Set<MetricName> = [a, b, aDuplicate]
        #expect(nameSet.count == 2)
        #expect(nameSet.contains(a))
        #expect(nameSet.contains(b))

        var dict: [MetricName: Int] = [a: 1, b: 2]
        dict[aDuplicate] = 3
        #expect(dict[a] == 3)
        #expect(dict[b] == 2)
    }

    // MARK: - Counter

    @Test("Counter increment")
    func counterIncrement() {
        let exporter = PrometheusExporter()
        exporter.register(.counter, name: "test_counter", help: "A test counter")

        exporter.increment("test_counter", by: 1, labels: [:])
        exporter.increment("test_counter", by: 4, labels: [:])

        let output = exporter.scrape()
        #expect(output.contains("test_counter 5"))
    }

    @Test("Counter ignores negative values")
    func counterIgnoresNegative() {
        let exporter = PrometheusExporter()
        exporter.register(.counter, name: "test_counter", help: "A test counter")

        exporter.increment("test_counter", by: 10, labels: [:])
        exporter.increment("test_counter", by: -5, labels: [:])

        let output = exporter.scrape()
        #expect(output.contains("test_counter 10"))
    }

    @Test("Counter with labels")
    func counterWithLabels() {
        let exporter = PrometheusExporter()
        exporter.register(.counter, name: "requests", help: "Total requests")

        exporter.increment("requests", by: 3, labels: ["method": "GET"])
        exporter.increment("requests", by: 7, labels: ["method": "POST"])

        let output = exporter.scrape()
        #expect(output.contains("requests{method=\"GET\"} 3"))
        #expect(output.contains("requests{method=\"POST\"} 7"))
    }

    // MARK: - Gauge

    @Test("Gauge set")
    func gaugeSet() {
        let exporter = PrometheusExporter()
        exporter.register(.gauge, name: "active_conns", help: "Active connections")

        exporter.set("active_conns", to: 42, labels: [:])
        let output1 = exporter.scrape()
        #expect(output1.contains("active_conns 42"))

        exporter.set("active_conns", to: 10, labels: [:])
        let output2 = exporter.scrape()
        #expect(output2.contains("active_conns 10"))
    }

    @Test("Gauge with labels")
    func gaugeWithLabels() {
        let exporter = PrometheusExporter()
        exporter.register(.gauge, name: "temperature", help: "Temperature")

        exporter.set("temperature", to: 23.5, labels: ["location": "office"])
        exporter.set("temperature", to: 18.0, labels: ["location": "garage"])

        let output = exporter.scrape()
        #expect(output.contains("temperature{location=\"garage\"} 18"))
        #expect(output.contains("temperature{location=\"office\"} 23.5"))
    }

    // MARK: - Histogram

    @Test("Histogram observe")
    func histogramObserve() {
        let exporter = PrometheusExporter()
        exporter.register(
            .histogram,
            name: "request_duration",
            help: "Request duration",
            buckets: [0.1, 0.5, 1.0]
        )

        exporter.observe("request_duration", value: 0.05, labels: [:])
        exporter.observe("request_duration", value: 0.3, labels: [:])
        exporter.observe("request_duration", value: 0.8, labels: [:])

        let output = exporter.scrape()
        // 0.05 <= 0.1, so bucket 0.1 has 1
        #expect(output.contains("request_duration_bucket{le=\"0.1\"} 1"))
        // 0.05 and 0.3 <= 0.5, so bucket 0.5 has 2
        #expect(output.contains("request_duration_bucket{le=\"0.5\"} 2"))
        // all three <= 1.0, so bucket 1.0 has 3
        #expect(output.contains("request_duration_bucket{le=\"1\"} 3"))
        // +Inf always has total count
        #expect(output.contains("request_duration_bucket{le=\"+Inf\"} 3"))
        // Sum and count
        #expect(output.contains("request_duration_sum 1.15"))
        #expect(output.contains("request_duration_count 3"))
    }

    @Test("Histogram with labels")
    func histogramWithLabels() {
        let exporter = PrometheusExporter()
        exporter.register(
            .histogram,
            name: "latency",
            help: "Latency",
            buckets: [1.0, 5.0]
        )

        exporter.observe("latency", value: 0.5, labels: ["endpoint": "api"])
        exporter.observe("latency", value: 3.0, labels: ["endpoint": "api"])

        let output = exporter.scrape()
        #expect(output.contains("latency_bucket{endpoint=\"api\",le=\"1\"} 1"))
        #expect(output.contains("latency_bucket{endpoint=\"api\",le=\"5\"} 2"))
        #expect(output.contains("latency_bucket{endpoint=\"api\",le=\"+Inf\"} 2"))
        #expect(output.contains("latency_sum{endpoint=\"api\"} 3.5"))
        #expect(output.contains("latency_count{endpoint=\"api\"} 2"))
    }

    // MARK: - Prometheus Scrape Format

    @Test("Scrape format includes HELP and TYPE")
    func scrapeFormatAnnotations() {
        let exporter = PrometheusExporter()
        exporter.register(.counter, name: "my_counter", help: "My counter help text")
        exporter.increment("my_counter", by: 1, labels: [:])

        let output = exporter.scrape()
        #expect(output.contains("# HELP my_counter My counter help text"))
        #expect(output.contains("# TYPE my_counter counter"))
    }

    @Test("Scrape format for gauge type")
    func scrapeFormatGaugeType() {
        let exporter = PrometheusExporter()
        exporter.register(.gauge, name: "my_gauge", help: "A gauge metric")
        exporter.set("my_gauge", to: 99, labels: [:])

        let output = exporter.scrape()
        #expect(output.contains("# TYPE my_gauge gauge"))
    }

    @Test("Scrape format for histogram type")
    func scrapeFormatHistogramType() {
        let exporter = PrometheusExporter()
        exporter.register(.histogram, name: "my_hist", help: "A histogram", buckets: [1.0])
        exporter.observe("my_hist", value: 0.5, labels: [:])

        let output = exporter.scrape()
        #expect(output.contains("# TYPE my_hist histogram"))
    }

    @Test("Labels formatting with multiple keys")
    func labelsFormatting() {
        let exporter = PrometheusExporter()
        exporter.register(.counter, name: "multi_label", help: "Multi-label metric")

        exporter.increment("multi_label", by: 1, labels: ["transport": "tcp", "direction": "inbound"])

        let output = exporter.scrape()
        // Labels should be sorted alphabetically by key
        #expect(output.contains("multi_label{direction=\"inbound\",transport=\"tcp\"} 1"))
    }

    @Test("Unregistered metric still appears in scrape")
    func unregisteredMetric() {
        let exporter = PrometheusExporter()
        exporter.increment("unregistered", by: 5, labels: [:])

        let output = exporter.scrape()
        #expect(output.contains("unregistered 5"))
        #expect(!output.contains("# HELP unregistered"))
        #expect(!output.contains("# TYPE unregistered"))
    }

    @Test("Empty scrape returns empty string")
    func emptyScrape() {
        let exporter = PrometheusExporter()
        let output = exporter.scrape()
        #expect(output.isEmpty)
    }

    // MARK: - Reset

    @Test("Reset clears all metric values")
    func resetClearsValues() {
        let exporter = PrometheusExporter()
        exporter.register(.counter, name: "c", help: "counter")
        exporter.register(.gauge, name: "g", help: "gauge")
        exporter.register(.histogram, name: "h", help: "histogram", buckets: [1.0])

        exporter.increment("c", by: 10, labels: [:])
        exporter.set("g", to: 42, labels: [:])
        exporter.observe("h", value: 0.5, labels: [:])

        // Verify data exists
        let beforeReset = exporter.scrape()
        #expect(!beforeReset.isEmpty)

        exporter.reset()

        // After reset, scrape should be empty (registrations preserved, but no data)
        let afterReset = exporter.scrape()
        #expect(afterReset.isEmpty)

        // Can still record after reset
        exporter.increment("c", by: 1, labels: [:])
        let afterRecord = exporter.scrape()
        #expect(afterRecord.contains("# HELP c counter"))
        #expect(afterRecord.contains("c 1"))
    }

    // MARK: - Multiple Metrics

    @Test("Multiple metrics in scrape output")
    func multipleMetrics() {
        let exporter = PrometheusExporter()
        exporter.register(.counter, name: "alpha", help: "First metric")
        exporter.register(.gauge, name: "beta", help: "Second metric")

        exporter.increment("alpha", by: 1, labels: [:])
        exporter.set("beta", to: 99, labels: [:])

        let output = exporter.scrape()
        #expect(output.contains("# HELP alpha First metric"))
        #expect(output.contains("# TYPE alpha counter"))
        #expect(output.contains("alpha 1"))
        #expect(output.contains("# HELP beta Second metric"))
        #expect(output.contains("# TYPE beta gauge"))
        #expect(output.contains("beta 99"))
    }

    @Test("Metrics output is sorted by name")
    func metricsSorted() {
        let exporter = PrometheusExporter()
        exporter.register(.counter, name: "zzz", help: "Z metric")
        exporter.register(.counter, name: "aaa", help: "A metric")

        exporter.increment("zzz", by: 1, labels: [:])
        exporter.increment("aaa", by: 2, labels: [:])

        let output = exporter.scrape()
        let aaaRange = output.range(of: "aaa 2")
        let zzzRange = output.range(of: "zzz 1")
        #expect(aaaRange != nil)
        #expect(zzzRange != nil)
        if let a = aaaRange, let z = zzzRange {
            #expect(a.lowerBound < z.lowerBound)
        }
    }

    // MARK: - Standard libp2p Metrics

    @Test("Standard libp2p metric names")
    func standardMetricNames() {
        #expect(LibP2PMetrics.connectionsTotal.name == "libp2p_connections_total")
        #expect(LibP2PMetrics.connectionsActive.name == "libp2p_connections_active")
        #expect(LibP2PMetrics.bytesSentTotal.name == "libp2p_bytes_sent_total")
        #expect(LibP2PMetrics.bytesReceivedTotal.name == "libp2p_bytes_received_total")
        #expect(LibP2PMetrics.streamsOpenedTotal.name == "libp2p_streams_opened_total")
        #expect(LibP2PMetrics.peersDiscoveredTotal.name == "libp2p_peers_discovered_total")
    }

    // MARK: - Concurrent Safety

    @Test("Concurrent recording is safe", .timeLimit(.minutes(1)))
    func concurrentSafety() async {
        let exporter = PrometheusExporter()
        exporter.register(.counter, name: "concurrent_counter", help: "Concurrency test")
        exporter.register(.gauge, name: "concurrent_gauge", help: "Concurrency test")
        exporter.register(.histogram, name: "concurrent_hist", help: "Concurrency test", buckets: [1.0, 10.0])

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<500 {
                group.addTask {
                    exporter.increment("concurrent_counter", by: 1, labels: [:])
                }
                group.addTask {
                    exporter.set("concurrent_gauge", to: Double(i), labels: [:])
                }
                group.addTask {
                    exporter.observe("concurrent_hist", value: Double(i % 15), labels: [:])
                }
            }
        }

        let output = exporter.scrape()
        #expect(output.contains("concurrent_counter 500"))
        #expect(output.contains("concurrent_hist_count 500"))
    }

    @Test("Concurrent scrape and record", .timeLimit(.minutes(1)))
    func concurrentScrapeAndRecord() async {
        let exporter = PrometheusExporter()
        exporter.register(.counter, name: "race_counter", help: "Race test")

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<200 {
                group.addTask {
                    exporter.increment("race_counter", by: 1, labels: [:])
                }
                group.addTask {
                    _ = exporter.scrape()
                }
            }
        }

        let output = exporter.scrape()
        #expect(output.contains("race_counter 200"))
    }

    // MARK: - Edge Cases

    @Test("Counter with fractional increment")
    func counterFractionalIncrement() {
        let exporter = PrometheusExporter()
        exporter.increment("frac_counter", by: 0.5, labels: [:])
        exporter.increment("frac_counter", by: 0.5, labels: [:])

        let output = exporter.scrape()
        #expect(output.contains("frac_counter 1"))
    }

    @Test("Gauge can be set to negative value")
    func gaugeNegative() {
        let exporter = PrometheusExporter()
        exporter.set("neg_gauge", to: -5, labels: [:])

        let output = exporter.scrape()
        #expect(output.contains("neg_gauge -5"))
    }

    @Test("Same metric name different labels are separate series")
    func differentLabelsSeparateSeries() {
        let exporter = PrometheusExporter()
        exporter.increment("series", by: 1, labels: ["env": "prod"])
        exporter.increment("series", by: 2, labels: ["env": "staging"])

        let output = exporter.scrape()
        #expect(output.contains("series{env=\"prod\"} 1"))
        #expect(output.contains("series{env=\"staging\"} 2"))
    }

    // MARK: - Label Value Escaping

    @Test("Label values with backslash are escaped")
    func labelValueBackslashEscaping() {
        let exporter = PrometheusExporter()
        exporter.increment("escaped", by: 1, labels: ["path": "C:\\Users\\test"])

        let output = exporter.scrape()
        #expect(output.contains("escaped{path=\"C:\\\\Users\\\\test\"} 1"))
    }

    @Test("Label values with double quotes are escaped")
    func labelValueQuoteEscaping() {
        let exporter = PrometheusExporter()
        exporter.increment("escaped", by: 1, labels: ["msg": "say \"hello\""])

        let output = exporter.scrape()
        #expect(output.contains("escaped{msg=\"say \\\"hello\\\"\"} 1"))
    }

    @Test("Label values with newlines are escaped")
    func labelValueNewlineEscaping() {
        let exporter = PrometheusExporter()
        exporter.increment("escaped", by: 1, labels: ["desc": "line1\nline2"])

        let output = exporter.scrape()
        #expect(output.contains("escaped{desc=\"line1\\nline2\"} 1"))
    }

    @Test("Label values with mixed special characters are escaped")
    func labelValueMixedEscaping() {
        let exporter = PrometheusExporter()
        exporter.increment("escaped", by: 1, labels: ["val": "a\\b\"c\nd"])

        let output = exporter.scrape()
        #expect(output.contains("escaped{val=\"a\\\\b\\\"c\\nd\"} 1"))
    }

    @Test("Label values without special characters are unchanged")
    func labelValueNoEscaping() {
        let exporter = PrometheusExporter()
        exporter.increment("plain", by: 1, labels: ["key": "simple_value-123"])

        let output = exporter.scrape()
        #expect(output.contains("plain{key=\"simple_value-123\"} 1"))
    }

    // MARK: - NaN and Inf Formatting

    @Test("NaN gauge value formatted as NaN")
    func nanFormatting() {
        let exporter = PrometheusExporter()
        exporter.register(.gauge, name: "nan_gauge", help: "NaN test")
        exporter.set("nan_gauge", to: Double.nan, labels: [:])

        let output = exporter.scrape()
        #expect(output.contains("nan_gauge NaN"))
    }

    @Test("Positive infinity formatted as +Inf")
    func positiveInfFormatting() {
        let exporter = PrometheusExporter()
        exporter.register(.gauge, name: "inf_gauge", help: "Inf test")
        exporter.set("inf_gauge", to: Double.infinity, labels: [:])

        let output = exporter.scrape()
        #expect(output.contains("inf_gauge +Inf"))
    }

    @Test("Negative infinity formatted as -Inf")
    func negativeInfFormatting() {
        let exporter = PrometheusExporter()
        exporter.register(.gauge, name: "ninf_gauge", help: "Negative Inf test")
        exporter.set("ninf_gauge", to: -Double.infinity, labels: [:])

        let output = exporter.scrape()
        #expect(output.contains("ninf_gauge -Inf"))
    }

    @Test("Zero value formatted correctly")
    func zeroFormatting() {
        let exporter = PrometheusExporter()
        exporter.register(.gauge, name: "zero_gauge", help: "Zero test")
        exporter.set("zero_gauge", to: 0.0, labels: [:])

        let output = exporter.scrape()
        #expect(output.contains("zero_gauge 0.0"))
    }
}
