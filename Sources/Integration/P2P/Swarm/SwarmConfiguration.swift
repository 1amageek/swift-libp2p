/// Configuration for the Swarm layer.
///
/// Extracted from NodeConfiguration to contain only connection-lifecycle relevant settings.
/// Node creates this internally from NodeConfiguration.
import P2PCore
import P2PTransport
import P2PSecurity
import P2PMux

internal struct SwarmConfiguration: Sendable {
    /// The key pair for this node.
    let keyPair: KeyPair

    /// Addresses to listen on.
    let listenAddresses: [Multiaddr]

    /// Transports to use (in priority order for dialing).
    let transports: [any Transport]

    /// Security upgraders (in priority order for negotiation).
    let security: [any SecurityUpgrader]

    /// Muxers (in priority order for negotiation).
    let muxers: [any Muxer]

    /// Connection pool configuration.
    let pool: PoolConfiguration

    /// Resource manager for system-wide resource accounting (nil for no limits).
    let resourceManager: (any ResourceManager)?

    /// Maximum concurrent inbound stream negotiations per connection.
    let maxNegotiatingInboundStreams: Int
}
