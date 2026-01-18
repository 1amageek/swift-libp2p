/// HealthMonitor - Connection health monitoring
///
/// Uses ping to detect dead connections and trigger cleanup.

import Foundation
import P2PCore

/// Protocol for providing ping functionality.
///
/// This abstraction allows the HealthMonitor to use different
/// ping implementations (e.g., PingService adapter).
public protocol PingProvider: Sendable {
    /// Pings a peer and returns the round-trip time.
    ///
    /// - Parameter peer: The peer to ping
    /// - Returns: The round-trip time
    /// - Throws: If the ping fails or times out
    func ping(_ peer: PeerID) async throws -> Duration
}

/// Configuration for health monitoring.
public struct HealthMonitorConfiguration: Sendable {
    /// Interval between health checks.
    public var interval: Duration

    /// Timeout for each ping attempt.
    public var timeout: Duration

    /// Number of consecutive failures before reporting.
    public var maxFailures: Int

    /// Whether to perform an immediate check when monitoring starts.
    ///
    /// When true, the first health check runs immediately after
    /// `startMonitoring` is called, then continues at regular intervals.
    /// When false, the first check runs after `interval` has elapsed.
    public var checkImmediately: Bool

    /// Default configuration.
    ///
    /// - interval: 30 seconds
    /// - timeout: 10 seconds
    /// - maxFailures: 3
    /// - checkImmediately: false
    public static let `default` = HealthMonitorConfiguration(
        interval: .seconds(30),
        timeout: .seconds(10),
        maxFailures: 3,
        checkImmediately: false
    )

    /// Aggressive monitoring with shorter intervals.
    ///
    /// - interval: 10 seconds
    /// - timeout: 5 seconds
    /// - maxFailures: 2
    /// - checkImmediately: true
    public static let aggressive = HealthMonitorConfiguration(
        interval: .seconds(10),
        timeout: .seconds(5),
        maxFailures: 2,
        checkImmediately: true
    )

    /// Relaxed monitoring for stable networks.
    ///
    /// - interval: 60 seconds
    /// - timeout: 15 seconds
    /// - maxFailures: 5
    /// - checkImmediately: false
    public static let relaxed = HealthMonitorConfiguration(
        interval: .seconds(60),
        timeout: .seconds(15),
        maxFailures: 5,
        checkImmediately: false
    )

    /// Creates a new health monitor configuration.
    ///
    /// - Parameters:
    ///   - interval: Time between checks
    ///   - timeout: Ping timeout
    ///   - maxFailures: Failures before reporting
    ///   - checkImmediately: Whether to check immediately when monitoring starts
    public init(
        interval: Duration = .seconds(30),
        timeout: Duration = .seconds(10),
        maxFailures: Int = 3,
        checkImmediately: Bool = false
    ) {
        precondition(interval > .zero, "interval must be positive")
        precondition(timeout > .zero, "timeout must be positive")
        precondition(maxFailures > 0, "maxFailures must be positive")
        self.interval = interval
        self.timeout = timeout
        self.maxFailures = maxFailures
        self.checkImmediately = checkImmediately
    }
}

/// Internal error for health check timeout.
enum HealthCheckError: Error {
    case timeout
    case cancelled
}

/// Monitors connection health using ping.
///
/// The HealthMonitor periodically pings connected peers to detect
/// dead connections. When a peer fails multiple consecutive pings,
/// the configured callback is invoked.
///
/// ## Example
/// ```swift
/// let monitor = HealthMonitor(
///     configuration: .default,
///     pingProvider: myPingProvider
/// )
/// monitor.onHealthCheckFailed = { peer in
///     await node.disconnect(from: peer)
/// }
/// await monitor.startMonitoring(peer: remotePeer)
/// ```
public actor HealthMonitor {

    /// Configuration.
    private let configuration: HealthMonitorConfiguration

    /// Ping provider for health checks.
    private let pingProvider: any PingProvider

    /// Active monitoring tasks by peer.
    private var monitoringTasks: [PeerID: Task<Void, Never>] = [:]

    /// Consecutive failure counts by peer.
    private var failureCounts: [PeerID: Int] = [:]

    /// Callback when health check fails (threshold exceeded).
    private var onHealthCheckFailed: (@Sendable (PeerID) async -> Void)?

    /// Sets the callback for health check failures.
    ///
    /// - Parameter callback: The callback to invoke when health check fails
    public func setOnHealthCheckFailed(_ callback: (@Sendable (PeerID) async -> Void)?) {
        self.onHealthCheckFailed = callback
    }

    /// Creates a new health monitor.
    ///
    /// - Parameters:
    ///   - configuration: Monitoring configuration
    ///   - pingProvider: Provider for ping operations
    public init(
        configuration: HealthMonitorConfiguration = .default,
        pingProvider: any PingProvider
    ) {
        self.configuration = configuration
        self.pingProvider = pingProvider
    }

    // MARK: - Monitoring Control

    /// Starts monitoring a peer.
    ///
    /// If already monitoring this peer, this is a no-op.
    ///
    /// - Parameter peer: The peer to monitor
    public func startMonitoring(peer: PeerID) {
        guard monitoringTasks[peer] == nil else { return }

        let task = Task { [weak self, configuration, pingProvider] in
            guard let self = self else { return }

            // Immediate check if configured
            var isFirstCheck = configuration.checkImmediately

            while !Task.isCancelled {
                do {
                    // Wait for interval (skip on first check if immediate)
                    if !isFirstCheck {
                        try await Task.sleep(for: configuration.interval)
                    }
                    isFirstCheck = false

                    // Ping with timeout
                    _ = try await self.pingWithTimeout(
                        peer: peer,
                        pingProvider: pingProvider,
                        timeout: configuration.timeout
                    )

                    // Success - reset failure count
                    await self.resetFailureCount(for: peer)

                } catch is CancellationError {
                    break
                } catch {
                    // Ping failed - record failure
                    await self.recordFailure(for: peer)
                }
            }
        }

        monitoringTasks[peer] = task
    }

    /// Stops monitoring a peer.
    ///
    /// - Parameter peer: The peer to stop monitoring
    public func stopMonitoring(peer: PeerID) {
        monitoringTasks[peer]?.cancel()
        monitoringTasks.removeValue(forKey: peer)
        failureCounts.removeValue(forKey: peer)
    }

    /// Stops monitoring all peers.
    public func stopAll() {
        for task in monitoringTasks.values {
            task.cancel()
        }
        monitoringTasks.removeAll()
        failureCounts.removeAll()
    }

    /// Returns whether a peer is being monitored.
    ///
    /// - Parameter peer: The peer to check
    /// - Returns: true if monitoring is active
    public func isMonitoring(peer: PeerID) -> Bool {
        monitoringTasks[peer] != nil
    }

    /// Returns all peers being monitored.
    public var monitoredPeers: [PeerID] {
        Array(monitoringTasks.keys)
    }

    // MARK: - Manual Check

    /// Performs an immediate health check on a peer.
    ///
    /// This does not affect the regular monitoring schedule.
    ///
    /// - Parameter peer: The peer to check
    /// - Returns: The round-trip time if successful
    /// - Throws: If the ping fails or times out
    public func checkHealth(of peer: PeerID) async throws -> Duration {
        try await pingWithTimeout(
            peer: peer,
            pingProvider: pingProvider,
            timeout: configuration.timeout
        )
    }

    // MARK: - Private

    private func pingWithTimeout(
        peer: PeerID,
        pingProvider: any PingProvider,
        timeout: Duration
    ) async throws -> Duration {
        try await withThrowingTaskGroup(of: Duration.self) { group in
            group.addTask {
                try await pingProvider.ping(peer)
            }

            group.addTask {
                try await Task.sleep(for: timeout)
                throw HealthCheckError.timeout
            }

            // Get first result (ping or timeout)
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func resetFailureCount(for peer: PeerID) {
        failureCounts[peer] = 0
    }

    private func recordFailure(for peer: PeerID) async {
        let count = (failureCounts[peer] ?? 0) + 1
        failureCounts[peer] = count

        if count >= configuration.maxFailures {
            // Reset count and trigger callback
            failureCounts[peer] = 0
            await onHealthCheckFailed?(peer)
        }
    }
}

// MARK: - Failure Count Access (for testing)

extension HealthMonitor {
    /// Gets the current failure count for a peer.
    ///
    /// Primarily for testing purposes.
    ///
    /// - Parameter peer: The peer to check
    /// - Returns: The current failure count
    public func failureCount(for peer: PeerID) -> Int {
        failureCounts[peer] ?? 0
    }
}
