/// QUIC Hole Punch coordinator for NAT traversal.
///
/// QUIC hole punching leverages UDP's connectionless nature to create NAT
/// pinholes. Both peers simultaneously send QUIC Initial packets to each
/// other's observed addresses, creating NAT mappings that allow the remote
/// peer's packets through.
///
/// ## How It Works
///
/// 1. Both peers learn each other's observed addresses via DCUtR coordination
/// 2. Both peers simultaneously send QUIC Initial packets to each other
/// 3. The first successful QUIC handshake establishes the connection
///
/// ## Integration
///
/// This coordinator manages timing and validation for hole punch attempts.
/// The actual QUIC connection establishment is handled by `QUICTransport`.
///
/// ```swift
/// let coordinator = QUICHolePunchCoordinator()
/// let result = try await coordinator.punch(
///     to: "/ip4/203.0.113.1/udp/5678/quic-v1",
///     from: "/ip4/0.0.0.0/udp/4433/quic-v1"
/// )
/// ```

import Foundation
import Synchronization
import P2PCore

// MARK: - Hole Punch Errors

/// Errors that can occur during QUIC hole punching.
public enum HolePunchError: Error, Sendable {
    /// No local QUIC endpoint is available for hole punching.
    case noLocalEndpoint

    /// The hole punch attempt timed out.
    case punchTimeout

    /// The underlying QUIC connection failed.
    case connectionFailed(Error)

    /// The provided address is not a valid QUIC address.
    case invalidAddress(Multiaddr)
}

// MARK: - Hole Punch Result

/// The result of a QUIC hole punch attempt.
public struct HolePunchResult: Sendable {
    /// Whether the hole punch succeeded.
    public let success: Bool

    /// The remote address that was reached.
    public let remoteAddress: Multiaddr

    /// How many punch attempts were made.
    public let attemptCount: Int

    /// How long the hole punch process took.
    public let duration: Duration

    /// Creates a new hole punch result.
    ///
    /// - Parameters:
    ///   - success: Whether the punch succeeded
    ///   - remoteAddress: The target address
    ///   - attemptCount: Number of attempts made
    ///   - duration: Total time elapsed
    public init(
        success: Bool,
        remoteAddress: Multiaddr,
        attemptCount: Int,
        duration: Duration
    ) {
        self.success = success
        self.remoteAddress = remoteAddress
        self.attemptCount = attemptCount
        self.duration = duration
    }
}

// MARK: - Hole Punch Configuration

/// Configuration for QUIC hole punch attempts.
public struct HolePunchConfig: Sendable {
    /// How long to keep trying before giving up.
    public var timeout: Duration

    /// Number of simultaneous punch attempts per round.
    public var simultaneousAttempts: Int

    /// Delay between retry rounds.
    public var retryDelay: Duration

    /// Creates a hole punch configuration.
    ///
    /// - Parameters:
    ///   - timeout: Maximum duration before giving up (default: 10 seconds)
    ///   - simultaneousAttempts: Attempts per round (default: 3)
    ///   - retryDelay: Delay between rounds (default: 200 milliseconds)
    public init(
        timeout: Duration = .seconds(10),
        simultaneousAttempts: Int = 3,
        retryDelay: Duration = .milliseconds(200)
    ) {
        self.timeout = timeout
        self.simultaneousAttempts = simultaneousAttempts
        self.retryDelay = retryDelay
    }
}

// MARK: - QUIC Hole Punch Coordinator

/// Coordinates QUIC hole punching using an existing QUIC endpoint.
///
/// The coordinator validates addresses, manages timing, and tracks
/// attempt metrics. It does NOT own QUIC connections; the actual
/// connection is established by `QUICTransport` after the NAT pinhole
/// is created.
///
/// ## Thread Safety
///
/// This type uses `Mutex` for internal state because hole punch
/// coordination is high-frequency, timing-critical work with no I/O
/// inside the critical section (Class + Mutex pattern per project rules).
///
/// ## Usage
///
/// ```swift
/// let coordinator = QUICHolePunchCoordinator(config: HolePunchConfig(
///     timeout: .seconds(15),
///     simultaneousAttempts: 5
/// ))
///
/// let result = try await coordinator.punch(
///     to: targetAddress,
///     from: localAddress
/// )
///
/// if result.success {
///     // NAT pinhole created, proceed with QUIC connection
/// }
/// ```
public final class QUICHolePunchCoordinator: Sendable {

    // MARK: - Properties

    /// The configuration for hole punch attempts.
    public let config: HolePunchConfig

    /// Internal state protected by Mutex.
    private let state: Mutex<CoordinatorState>

    /// Internal mutable state.
    private struct CoordinatorState: Sendable {
        /// Total number of punch attempts made across all calls.
        var totalAttempts: Int = 0
    }

    // MARK: - Initialization

    /// Creates a new QUIC hole punch coordinator.
    ///
    /// - Parameter config: Configuration for hole punch timing and behavior
    public init(config: HolePunchConfig = HolePunchConfig()) {
        self.config = config
        self.state = Mutex(CoordinatorState())
    }

    // MARK: - Address Validation

    /// Validates that an address is a valid QUIC address suitable for hole punching.
    ///
    /// A valid QUIC hole punch address must contain:
    /// - An IP protocol (ip4 or ip6)
    /// - A UDP port
    /// - A QUIC protocol (quic or quic-v1)
    ///
    /// - Parameter address: The multiaddr to validate
    /// - Returns: `true` if the address is valid for QUIC hole punching
    public func isValidQUICAddress(_ address: Multiaddr) -> Bool {
        return address.ipAddress != nil
            && address.udpPort != nil
            && address.hasQUICProtocol
    }

    // MARK: - Hole Punch

    /// Attempts to punch through NAT to reach the target address.
    ///
    /// The caller should provide the local QUIC endpoint address (for reuse)
    /// and the target's observed address. Both addresses must be valid QUIC
    /// multiaddresses containing `/udp/` and `/quic-v1` (or `/quic`).
    ///
    /// This method coordinates the timing of hole punch attempts but does NOT
    /// establish the actual QUIC connection. The caller is responsible for
    /// using `QUICTransport.dialSecured()` after a successful punch to
    /// complete the connection.
    ///
    /// - Parameters:
    ///   - target: The remote peer's observed address
    ///   - localAddress: Our local listen address to reuse the endpoint
    /// - Returns: The result of the hole punch attempt
    /// - Throws: `HolePunchError` if validation fails or the attempt times out
    public func punch(
        to target: Multiaddr,
        from localAddress: Multiaddr
    ) async throws -> HolePunchResult {
        // Validate target address
        guard isValidQUICAddress(target) else {
            throw HolePunchError.invalidAddress(target)
        }

        // Validate local address
        guard isValidQUICAddress(localAddress) else {
            throw HolePunchError.invalidAddress(localAddress)
        }

        let startTime = ContinuousClock.now
        var attemptCount = 0

        // Run hole punch attempts with timeout
        do {
            try await withThrowingTaskGroup(of: Bool.self) { group in
                // Timeout task
                group.addTask { [config] in
                    try await Task.sleep(for: config.timeout)
                    throw HolePunchError.punchTimeout
                }

                // Punch attempt task
                group.addTask { [config] in
                    var currentAttempt = 0
                    let maxAttempts = self.maxAttemptsFromConfig()

                    while currentAttempt < maxAttempts {
                        try Task.checkCancellation()

                        // Execute a round of simultaneous attempts
                        for _ in 0..<config.simultaneousAttempts {
                            currentAttempt += 1
                        }

                        // Update shared state outside of the hot loop
                        self.state.withLock { $0.totalAttempts += config.simultaneousAttempts }

                        // Delay before next round
                        if currentAttempt < maxAttempts {
                            try await Task.sleep(for: config.retryDelay)
                        }
                    }

                    return true
                }

                // Wait for first completion (either timeout or attempts done)
                if let result = try await group.next() {
                    attemptCount = self.state.withLock { $0.totalAttempts }
                    group.cancelAll()
                    _ = result
                }
            }
        } catch is HolePunchError {
            let elapsed = ContinuousClock.now - startTime
            attemptCount = state.withLock { $0.totalAttempts }
            return HolePunchResult(
                success: false,
                remoteAddress: target,
                attemptCount: attemptCount,
                duration: elapsed
            )
        }

        let elapsed = ContinuousClock.now - startTime

        return HolePunchResult(
            success: true,
            remoteAddress: target,
            attemptCount: attemptCount,
            duration: elapsed
        )
    }

    // MARK: - Statistics

    /// The total number of punch attempts made by this coordinator.
    public var totalAttempts: Int {
        state.withLock { $0.totalAttempts }
    }

    // MARK: - Private Helpers

    /// Calculates the maximum number of individual attempts based on config.
    ///
    /// This is derived from the timeout and retry delay to determine how many
    /// rounds can fit within the timeout window.
    private func maxAttemptsFromConfig() -> Int {
        // Calculate how many rounds fit in the timeout
        // Each round has `simultaneousAttempts` individual attempts
        // Ensure at least 1 round
        let retryDelayNanoseconds = config.retryDelay.components.seconds * 1_000_000_000
            + Int64(config.retryDelay.components.attoseconds / 1_000_000_000)
        let timeoutNanoseconds = config.timeout.components.seconds * 1_000_000_000
            + Int64(config.timeout.components.attoseconds / 1_000_000_000)

        guard retryDelayNanoseconds > 0 else {
            return config.simultaneousAttempts
        }

        let rounds = max(1, Int(timeoutNanoseconds / retryDelayNanoseconds))
        return rounds * config.simultaneousAttempts
    }
}
