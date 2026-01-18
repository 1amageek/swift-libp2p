/// Error types for Circuit Relay operations.

import Foundation
import P2PCore

/// Errors for Circuit Relay operations.
public enum CircuitRelayError: Error, Sendable {
    // MARK: - Hop Protocol Errors

    /// Reservation request was refused by the relay.
    case reservationFailed(status: HopStatus)

    /// Connection through relay failed.
    case connectionFailed(status: HopStatus)

    /// Not connected to the specified relay peer.
    case relayNotConnected(PeerID)

    /// No active reservation on the specified relay.
    case noReservation(relay: PeerID)

    // MARK: - Stop Protocol Errors

    /// Stop protocol handshake failed.
    case stopFailed(status: StopStatus)

    /// Received connection from unexpected peer.
    case unexpectedPeer(expected: PeerID, actual: PeerID)

    // MARK: - General Errors

    /// Protocol message was malformed or unexpected.
    case protocolViolation(String)

    /// Operation timed out.
    case timeout

    /// Circuit was closed.
    case circuitClosed

    /// Circuit limit was exceeded.
    case limitExceeded(CircuitLimit)

    /// Failed to encode or decode message.
    case encodingError(String)
}

/// Status codes for Hop protocol responses.
public enum HopStatus: UInt32, Sendable, Hashable {
    /// Request succeeded.
    case ok = 100

    /// Reservation was refused.
    case reservationRefused = 200

    /// Resource limit exceeded on relay.
    case resourceLimitExceeded = 201

    /// Permission denied.
    case permissionDenied = 202

    /// Connection to target failed.
    case connectionFailed = 203

    /// Target has no reservation.
    case noReservation = 204

    /// Message was malformed.
    case malformedMessage = 400

    /// Unexpected message type received.
    case unexpectedMessage = 401

    /// Unknown status code.
    case unknown = 0
}

/// Status codes for Stop protocol responses.
public enum StopStatus: UInt32, Sendable, Hashable {
    /// Request succeeded.
    case ok = 100

    /// Connection failed.
    case connectionFailed = 270

    /// Unexpected message type received.
    case unexpectedMessage = 400

    /// Unknown status code.
    case unknown = 0
}
