/// Reservation types for Circuit Relay v2.

import Foundation
import P2PCore

/// A reservation to receive relayed connections through a relay.
///
/// When a peer behind a NAT wants to be reachable, it makes a reservation
/// on a public relay. Other peers can then connect to it through that relay.
public struct Reservation: Sendable {
    /// The relay peer ID.
    public let relay: PeerID

    /// Expiration time of this reservation.
    public let expiration: ContinuousClock.Instant

    /// Addresses to advertise for this reservation.
    ///
    /// These are the addresses that other peers should use to connect
    /// through the relay, typically in the format:
    /// `/ip4/.../tcp/.../p2p/{relay}/p2p-circuit/p2p/{peer}`
    public let addresses: [Multiaddr]

    /// Optional voucher from the relay.
    ///
    /// A signed voucher proves the reservation was granted by the relay.
    public let voucher: Data?

    /// Creates a new reservation.
    ///
    /// - Parameters:
    ///   - relay: The relay peer ID.
    ///   - expiration: When this reservation expires.
    ///   - addresses: Addresses to advertise.
    ///   - voucher: Optional signed voucher.
    public init(
        relay: PeerID,
        expiration: ContinuousClock.Instant,
        addresses: [Multiaddr],
        voucher: Data? = nil
    ) {
        self.relay = relay
        self.expiration = expiration
        self.addresses = addresses
        self.voucher = voucher
    }

    /// Whether this reservation is still valid.
    public var isValid: Bool {
        ContinuousClock.now < expiration
    }

    /// Time remaining until expiration.
    public var timeRemaining: Duration {
        let now = ContinuousClock.now
        if expiration > now {
            return expiration - now
        }
        return .zero
    }
}

/// Reservation information as received in protocol messages.
///
/// This is the wire format representation of a reservation.
public struct ReservationInfo: Sendable {
    /// Expiration as Unix timestamp in seconds.
    public let expiration: UInt64

    /// Relay addresses to advertise.
    public let addresses: [Multiaddr]

    /// Optional voucher data.
    public let voucher: Data?

    /// Creates reservation info from wire format data.
    public init(expiration: UInt64, addresses: [Multiaddr], voucher: Data? = nil) {
        self.expiration = expiration
        self.addresses = addresses
        self.voucher = voucher
    }
}
