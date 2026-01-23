/// Events emitted by Circuit Relay services.

import Foundation
import P2PCore

/// Events emitted by Circuit Relay services.
public enum CircuitRelayEvent: Sendable {
    // MARK: - Client Events

    /// A reservation was successfully created on a relay.
    case reservationCreated(relay: PeerID, reservation: Reservation)

    /// A reservation expired.
    case reservationExpired(relay: PeerID)

    /// A reservation request failed.
    case reservationFailed(relay: PeerID, error: CircuitRelayError)

    /// A circuit was established through a relay.
    case circuitEstablished(relay: PeerID, remote: PeerID)

    /// A circuit was closed.
    case circuitClosed(relay: PeerID, remote: PeerID)

    // MARK: - Server Events

    /// A reservation was accepted from a peer.
    case reservationAccepted(from: PeerID, expiration: ContinuousClock.Instant)

    /// A reservation request was denied.
    case reservationDenied(from: PeerID, reason: HopStatus)

    /// A circuit was opened between two peers.
    case circuitOpened(source: PeerID, destination: PeerID)

    /// A circuit completed (closed normally after data transfer).
    case circuitCompleted(source: PeerID, destination: PeerID, bytesTransferred: UInt64)

    /// A circuit failed to establish.
    case circuitFailed(source: PeerID, destination: PeerID, reason: CircuitFailureReason)
}

/// Reasons why a circuit failed to establish.
public enum CircuitFailureReason: Sendable {
    /// The target peer is not reachable (no connection exists).
    case targetUnreachable

    /// The target peer rejected the connection.
    case targetRejected

    /// The relay's resource limits were exceeded.
    case resourceLimitExceeded
}
