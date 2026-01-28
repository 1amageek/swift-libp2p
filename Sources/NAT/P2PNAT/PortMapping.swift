/// PortMapping - A successful port mapping
import Foundation
import P2PCore

/// A successful port mapping.
public struct PortMapping: Sendable, Equatable {
    /// The internal (local) port.
    public let internalPort: UInt16

    /// The external (public) port.
    public let externalPort: UInt16

    /// The external (public) IP address.
    public let externalAddress: String

    /// The protocol (TCP or UDP).
    public let `protocol`: NATTransportProtocol

    /// When this mapping expires.
    public let expiration: ContinuousClock.Instant

    /// The gateway type that created this mapping.
    public let gatewayType: NATGatewayType

    /// Whether this mapping is still valid.
    public var isValid: Bool {
        ContinuousClock.now < expiration
    }

    /// Creates a Multiaddr representing the external address.
    public func multiaddr() throws -> Multiaddr {
        switch `protocol` {
        case .tcp:
            return try Multiaddr("/ip4/\(externalAddress)/tcp/\(externalPort)")
        case .udp:
            return try Multiaddr("/ip4/\(externalAddress)/udp/\(externalPort)")
        }
    }
}
