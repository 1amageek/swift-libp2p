/// RendezvousMessages - Message types for the Rendezvous wire protocol.

import P2PCore

/// Message types used in the Rendezvous wire protocol.
public enum RendezvousMessageType: UInt8, Sendable {
    /// Client registers with a rendezvous point.
    case register = 0

    /// Server responds to a registration request.
    case registerResponse = 1

    /// Client unregisters from a namespace.
    case unregister = 2

    /// Client requests peer discovery in a namespace.
    case discover = 3

    /// Server responds with discovered peers.
    case discoverResponse = 4
}

/// A registration entry stored at a rendezvous point.
///
/// Represents a peer's registration under a specific namespace,
/// including their addresses, TTL, and expiry time.
public struct RendezvousRegistration: Sendable {
    /// The namespace this registration belongs to.
    public let namespace: String

    /// The registered peer.
    public let peer: PeerID

    /// The addresses the peer is reachable at.
    public let addresses: [Multiaddr]

    /// The time-to-live for this registration.
    public let ttl: Duration

    /// The point in time when this registration expires.
    public let expiry: ContinuousClock.Instant

    /// Creates a new registration.
    ///
    /// - Parameters:
    ///   - namespace: The namespace to register under
    ///   - peer: The peer being registered
    ///   - addresses: Addresses the peer is reachable at
    ///   - ttl: Time-to-live for the registration
    ///   - expiry: When the registration expires
    public init(
        namespace: String,
        peer: PeerID,
        addresses: [Multiaddr],
        ttl: Duration,
        expiry: ContinuousClock.Instant
    ) {
        self.namespace = namespace
        self.peer = peer
        self.addresses = addresses
        self.ttl = ttl
        self.expiry = expiry
    }

    /// Whether this registration has expired.
    public var isExpired: Bool {
        ContinuousClock.now >= expiry
    }
}

/// Status codes for Rendezvous protocol responses.
public enum RendezvousStatus: UInt16, Sendable {
    /// Request succeeded.
    case ok = 0

    /// The namespace is invalid (empty or too long).
    case invalidNamespace = 100

    /// The signed peer record is invalid or unverifiable.
    case invalidSignedPeerRecord = 101

    /// The requested TTL is invalid (negative or exceeds maximum).
    case invalidTTL = 102

    /// The discovery cookie is invalid or expired.
    case invalidCookie = 103

    /// The peer is not authorized for this operation.
    case notAuthorized = 200

    /// Internal server error at the rendezvous point.
    case internalError = 300

    /// The rendezvous point is temporarily unavailable.
    case unavailable = 400
}
