/// BenchmarkSupport - Helpers for performance benchmarks
import Foundation

/// Prevents the compiler from optimizing away the given value.
@inline(never)
func blackHole<T>(_ value: T) {
    withUnsafePointer(to: value) { _ = $0 }
}

/// Converts a Duration to nanoseconds as a Double.
func durationNanoseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1_000_000_000
        + Double(duration.components.attoseconds) / 1_000_000_000
}

/// Converts a Duration to seconds as a Double.
func durationSeconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds)
        + Double(duration.components.attoseconds) / 1_000_000_000_000_000_000
}

/// Runs a benchmark with warmup and measurement phases.
///
/// - Parameters:
///   - name: Display name for the benchmark
///   - iterations: Number of measured iterations
///   - block: The code to benchmark
func benchmark(_ name: String, iterations: Int, block: () -> Void) {
    // Warmup phase
    let warmup = min(iterations / 10, 1000)
    for _ in 0..<warmup {
        block()
    }

    // Measurement phase
    let clock = ContinuousClock()
    let total = clock.measure {
        for _ in 0..<iterations {
            block()
        }
    }

    let totalNs = durationNanoseconds(total)
    let perIter = totalNs / Double(iterations)
    print("  \(name): \(perIter) ns/op (\(iterations) iters)")
}

/// Runs a throwing benchmark with warmup and measurement phases.
///
/// - Parameters:
///   - name: Display name for the benchmark
///   - iterations: Number of measured iterations
///   - block: The throwing code to benchmark
func benchmark(_ name: String, iterations: Int, block: () throws -> Void) throws {
    // Warmup phase
    let warmup = min(iterations / 10, 1000)
    for _ in 0..<warmup {
        try block()
    }

    // Measurement phase
    let clock = ContinuousClock()
    var elapsed: Duration = .zero
    let start = clock.now
    for _ in 0..<iterations {
        try block()
    }
    elapsed = clock.now - start

    let totalNs = durationNanoseconds(elapsed)
    let perIter = totalNs / Double(iterations)
    print("  \(name): \(perIter) ns/op (\(iterations) iters)")
}
