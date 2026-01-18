/// ConnectionDirection - Direction of a connection
///
/// Indicates whether a connection was initiated locally (outbound)
/// or received from a remote peer (inbound).

/// The direction of a connection.
public enum ConnectionDirection: Sendable, Equatable {
    /// Connection initiated locally (we dialed).
    case outbound

    /// Connection received from remote (we accepted).
    case inbound
}

// MARK: - CustomStringConvertible

extension ConnectionDirection: CustomStringConvertible {
    public var description: String {
        switch self {
        case .outbound:
            return "outbound"
        case .inbound:
            return "inbound"
        }
    }
}
