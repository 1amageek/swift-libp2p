/// NATTransportProtocol - Transport protocol for port mapping
import Foundation

/// Transport protocol for port mapping.
public enum NATTransportProtocol: String, Sendable {
    case tcp = "TCP"
    case udp = "UDP"
}
