/// Message types for Circuit Relay v2 protocol.
///
/// Defines the Hop and Stop protocol message structures.

import Foundation
import P2PCore

// MARK: - Hop Protocol Messages

/// Message types for the Hop protocol.
public enum HopMessageType: UInt8, Sendable {
    /// Request a reservation on the relay.
    case reserve = 0

    /// Request a connection to a target peer.
    case connect = 1

    /// Response status message.
    case status = 2
}

/// A message in the Hop protocol (client ↔ relay).
public struct HopMessage: Sendable {
    /// The message type.
    public let type: HopMessageType

    /// Target peer information (for CONNECT).
    public let peer: PeerInfo?

    /// Reservation details (in STATUS response).
    public let reservation: ReservationInfo?

    /// Circuit limits.
    public let limit: CircuitLimit?

    /// Response status.
    public let status: HopStatus?

    /// Creates a new Hop message.
    public init(
        type: HopMessageType,
        peer: PeerInfo? = nil,
        reservation: ReservationInfo? = nil,
        limit: CircuitLimit? = nil,
        status: HopStatus? = nil
    ) {
        self.type = type
        self.peer = peer
        self.reservation = reservation
        self.limit = limit
        self.status = status
    }

    /// Creates a RESERVE request.
    public static func reserve() -> HopMessage {
        HopMessage(type: .reserve)
    }

    /// Creates a CONNECT request to a target peer.
    public static func connect(to peer: PeerID) -> HopMessage {
        HopMessage(type: .connect, peer: PeerInfo(id: peer, addresses: []))
    }

    /// Creates a STATUS response.
    public static func statusResponse(
        _ status: HopStatus,
        reservation: ReservationInfo? = nil,
        limit: CircuitLimit? = nil
    ) -> HopMessage {
        HopMessage(type: .status, reservation: reservation, limit: limit, status: status)
    }
}

// MARK: - Stop Protocol Messages

/// Message types for the Stop protocol.
public enum StopMessageType: UInt8, Sendable {
    /// Incoming connection notification.
    case connect = 0

    /// Response status message.
    case status = 1
}

/// A message in the Stop protocol (relay ↔ target).
public struct StopMessage: Sendable {
    /// The message type.
    public let type: StopMessageType

    /// Source peer information (in CONNECT).
    public let peer: PeerInfo?

    /// Circuit limits.
    public let limit: CircuitLimit?

    /// Response status.
    public let status: StopStatus?

    /// Creates a new Stop message.
    public init(
        type: StopMessageType,
        peer: PeerInfo? = nil,
        limit: CircuitLimit? = nil,
        status: StopStatus? = nil
    ) {
        self.type = type
        self.peer = peer
        self.limit = limit
        self.status = status
    }

    /// Creates a CONNECT notification for an incoming connection.
    public static func connect(from peer: PeerID, limit: CircuitLimit? = nil) -> StopMessage {
        StopMessage(type: .connect, peer: PeerInfo(id: peer, addresses: []), limit: limit)
    }

    /// Creates a STATUS response.
    public static func statusResponse(_ status: StopStatus) -> StopMessage {
        StopMessage(type: .status, status: status)
    }
}

// MARK: - Common Types

/// Peer information in protocol messages.
public struct PeerInfo: Sendable {
    /// The peer ID.
    public let id: PeerID

    /// Known addresses for this peer.
    public let addresses: [Multiaddr]

    /// Creates peer info.
    public init(id: PeerID, addresses: [Multiaddr]) {
        self.id = id
        self.addresses = addresses
    }
}
