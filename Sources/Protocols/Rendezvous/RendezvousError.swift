/// RendezvousError - Error types for the Rendezvous protocol.

import P2PCore

/// Errors that can occur during Rendezvous protocol operations.
public enum RendezvousError: Error, Sendable, Equatable {
    /// The namespace is invalid (empty or exceeds maximum length).
    case invalidNamespace(String)

    /// The TTL is invalid (zero, negative, or exceeds maximum).
    case invalidTTL(String)

    /// Registration was rejected by the rendezvous point.
    case registrationRejected(RendezvousStatus)

    /// Discovery failed at the rendezvous point.
    case discoveryFailed(RendezvousStatus)

    /// The rendezvous point returned an error status.
    case serverError(RendezvousStatus)

    /// The namespace has reached its maximum registration capacity.
    case namespaceFull(String)

    /// The peer has reached its maximum number of registrations.
    case tooManyRegistrations(Int)

    /// The maximum number of namespaces has been reached.
    case tooManyNamespaces(Int)

    /// No registration exists for the given namespace and peer.
    case notRegistered(namespace: String)

    /// The cookie provided for paginated discovery is invalid.
    case invalidCookie

    /// Not connected to a rendezvous point.
    case notConnected

    /// The rendezvous point is unavailable.
    case unavailable

    /// A protocol-level error occurred.
    case protocolError(String)

    /// An internal error occurred.
    case internalError(String)
}
