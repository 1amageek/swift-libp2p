import Foundation
import P2PCore

/// A confirmed peer record (Tier 3 or post-handshake).
/// Contains verified identity information and observation history.
public struct ConfirmedPeerRecord: Sendable {
    /// Full peer identity.
    public let peerID: PeerID

    /// Reachable addresses.
    public var addresses: [OpaqueAddress]

    /// Observation history.
    public var observations: [BeaconObservation]

    /// Bayesian presence score (0.0-1.0).
    public var presenceScore: Double

    /// Signed envelope for tamper prevention.
    public let certificate: Envelope

    /// Epoch number (monotonically increasing per update).
    public let epoch: UInt64

    /// Expiration time (do not forward after this time).
    public let expiresAt: ContinuousClock.Instant

    /// Default TTL for records: 10 minutes.
    public static let defaultTTL: Duration = .seconds(600)

    /// Whether this record is still valid.
    public var isValid: Bool {
        ContinuousClock.now < expiresAt
    }

    public init(
        peerID: PeerID,
        addresses: [OpaqueAddress] = [],
        observations: [BeaconObservation] = [],
        presenceScore: Double = 0,
        certificate: Envelope,
        epoch: UInt64 = 0,
        expiresAt: ContinuousClock.Instant? = nil
    ) {
        self.peerID = peerID
        self.addresses = addresses
        self.observations = observations
        self.presenceScore = presenceScore
        self.certificate = certificate
        self.epoch = epoch
        self.expiresAt = expiresAt ?? (.now + Self.defaultTTL)
    }
}
