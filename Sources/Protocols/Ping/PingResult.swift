/// PingResult - Result types for Ping protocol
import Foundation
import P2PCore

/// Result of a ping operation.
public struct PingResult: Sendable {
    /// The peer that was pinged.
    public let peer: PeerID

    /// Round-trip time.
    public let rtt: Duration

    /// Timestamp of the ping.
    public let timestamp: ContinuousClock.Instant

    public init(peer: PeerID, rtt: Duration, timestamp: ContinuousClock.Instant = .now) {
        self.peer = peer
        self.rtt = rtt
        self.timestamp = timestamp
    }
}

/// Events emitted by PingService.
public enum PingEvent: Sendable {
    /// A ping succeeded.
    case success(PingResult)

    /// A ping failed.
    case failure(peer: PeerID, error: PingError)
}

/// Errors for Ping protocol.
public enum PingError: Error, Sendable {
    /// The peer did not respond in time.
    case timeout

    /// The response did not match the request.
    case mismatch

    /// Stream error.
    case streamError(String)

    /// Not connected to peer.
    case notConnected

    /// Protocol not supported by peer.
    case unsupported
}
