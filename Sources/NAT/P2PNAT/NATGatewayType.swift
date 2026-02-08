/// NATGatewayType - Type of NAT gateway discovered
import Foundation

/// Type of NAT gateway discovered.
public enum NATGatewayType: Sendable, Equatable {
    /// UPnP Internet Gateway Device
    case upnp(controlURL: URL, serviceType: String)
    /// NAT-PMP gateway
    case natpmp(gatewayIP: String)
    /// PCP (Port Control Protocol) gateway
    case pcp(gatewayIP: String)
}
