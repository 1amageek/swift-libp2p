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

    /// Set of peers being monitored.
    private var monitoredPeerSet: Set<PeerID> = []

    /// Next check time for each peer.
    private var nextCheckTimes: [PeerID: ContinuousClock.Instant] = [:]

    /// Consecutive failure counts by peer.
    private var failureCounts: [PeerID: Int] = [:]

    /// The single monitoring loop task.
    private var monitorLoopTask: Task<Void, Never>?

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
        guard !monitoredPeerSet.contains(peer) else { return }

        monitoredPeerSet.insert(peer)

        if configuration.checkImmediately {
            nextCheckTimes[peer] = .now
        } else {
            nextCheckTimes[peer] = .now + configuration.interval
        }

        ensureMonitorLoopRunning()
    }

    /// Stops monitoring a peer.
    ///
    /// - Parameter peer: The peer to stop monitoring
    public func stopMonitoring(peer: PeerID) {
        monitoredPeerSet.remove(peer)
        nextCheckTimes.removeValue(forKey: peer)
        failureCounts.removeValue(forKey: peer)

        if monitoredPeerSet.isEmpty {
            monitorLoopTask?.cancel()
            monitorLoopTask = nil
        }
    }

    /// Stops monitoring all peers.
    public func stopAll() {
        monitorLoopTask?.cancel()
        monitorLoopTask = nil
        monitoredPeerSet.removeAll()
        nextCheckTimes.removeAll()
        failureCounts.removeAll()
    }

    /// Returns whether a peer is being monitored.
    ///
    /// - Parameter peer: The peer to check
    /// - Returns: true if monitoring is active
    public func isMonitoring(peer: PeerID) -> Bool {
        monitoredPeerSet.contains(peer)
    }

    /// Returns all peers being monitored.
    public var monitoredPeers: [PeerID] {
        Array(monitoredPeerSet)
    }

    /// Starts the single monitoring loop if not already running.
    private func ensureMonitorLoopRunning() {
        guard monitorLoopTask == nil else { return }

        monitorLoopTask = Task { [weak self] in
            guard let self = self else { return }
            // Tick at a fraction of the check interval for responsiveness
            let tickInterval = Duration.seconds(1)

            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: tickInterval)
                } catch {
                    break
                }

                let now = ContinuousClock.now
                let peersToCheck = await self.peersReadyForCheck(at: now)

                // Check peers concurrently in a batch
                await withTaskGroup(of: Void.self) { group in
                    for peer in peersToCheck {
                        group.addTask {
                            await self.performCheck(peer: peer)
                        }
                    }
                }
            }
        }
    }

    /// Returns peers whose next check time has arrived.
    private func peersReadyForCheck(at now: ContinuousClock.Instant) -> [PeerID] {
        var ready: [PeerID] = []
        for (peer, nextTime) in nextCheckTimes {
            if now >= nextTime && monitoredPeerSet.contains(peer) {
                ready.append(peer)
            }
        }
        return ready
    }

    /// Performs a single health check for a peer.
    private func performCheck(peer: PeerID) async {
        guard monitoredPeerSet.contains(peer) else { return }

        do {
            _ = try await pingWithTimeout(
                peer: peer,
                pingProvider: pingProvider,
                timeout: configuration.timeout
            )
            resetFailureCount(for: peer)
        } catch {
            await recordFailure(for: peer)
        }

        // Schedule next check
        nextCheckTimes[peer] = .now + configuration.interval
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
