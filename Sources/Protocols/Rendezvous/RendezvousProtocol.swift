/// RendezvousProtocol - Protocol constants for the Rendezvous protocol.
///
/// The Rendezvous protocol enables namespace-based peer discovery.
/// Peers register themselves under namespaces and discover other peers
/// registered under the same namespace via a rendezvous point.

/// Protocol constants for the Rendezvous protocol.
public enum RendezvousProtocol {
    /// The protocol identifier for Rendezvous v1.
    public static let protocolID = "/rendezvous/1.0.0"

    /// Maximum allowed length for namespace strings.
    public static let maxNamespaceLength = 255

    /// Maximum TTL for a registration (72 hours).
    public static let maxTTL: Duration = .seconds(72 * 3600)

    /// Default TTL for a registration (2 hours).
    public static let defaultTTL: Duration = .seconds(7200)

    /// Maximum number of peers stored per namespace.
    public static let maxPeersPerNamespace = 1000
}
