/// NATPortMapperEvent - Events emitted by NATPortMapper
import Foundation

/// Events emitted by NATPortMapper.
public enum NATPortMapperEvent: Sendable {
    /// A gateway was discovered.
    case gatewayDiscovered(type: NATGatewayType)
    /// External IP address was discovered.
    case externalAddressDiscovered(address: String)
    /// A port mapping was created.
    case portMappingCreated(mapping: PortMapping)
    /// A port mapping was renewed.
    case portMappingRenewed(mapping: PortMapping)
    /// A port mapping failed.
    case portMappingFailed(internalPort: UInt16, error: NATPortMapperError)
    /// A port mapping expired.
    case portMappingExpired(mapping: PortMapping)
}
