/// Circuit limit configuration for relayed connections.

import Foundation

/// Limits applied to a relayed circuit.
///
/// Relays apply limits to prevent resource exhaustion. These limits include
/// maximum duration and data transfer amounts.
public struct CircuitLimit: Sendable, Hashable {
    /// Maximum duration of the circuit.
    public let duration: Duration?

    /// Maximum data that can be transferred (in bytes).
    public let data: UInt64?

    /// Creates a new circuit limit configuration.
    ///
    /// - Parameters:
    ///   - duration: Maximum circuit duration, or nil for unlimited.
    ///   - data: Maximum data transfer in bytes, or nil for unlimited.
    public init(duration: Duration? = nil, data: UInt64? = nil) {
        self.duration = duration
        self.data = data
    }

    /// Default circuit limits (2 minutes, 128 KB).
    public static let `default` = CircuitLimit(
        duration: .seconds(120),
        data: 128 * 1024
    )

    /// No limits applied.
    public static let unlimited = CircuitLimit(duration: nil, data: nil)
}
