/// NATProtocolHandler - Internal protocol abstracting NAT traversal differences
import Foundation

/// Internal protocol for NAT traversal protocol handlers.
///
/// Abstracts the differences between UPnP and NAT-PMP so that
/// `NATPortMapper` can iterate over handlers without branching.
protocol NATProtocolHandler: Sendable {
    /// Discovers a gateway using this protocol.
    func discoverGateway(configuration: NATPortMapperConfiguration) async throws -> NATGatewayType

    /// Gets the external IP address from the gateway.
    func getExternalAddress(
        gateway: NATGatewayType,
        configuration: NATPortMapperConfiguration
    ) async throws -> String

    /// Requests a port mapping on the gateway.
    func requestMapping(
        gateway: NATGatewayType,
        internalPort: UInt16,
        externalPort: UInt16,
        protocol: NATTransportProtocol,
        duration: Duration,
        externalAddress: String,
        configuration: NATPortMapperConfiguration
    ) async throws -> PortMapping

    /// Releases a port mapping from the gateway.
    func releaseMapping(_ mapping: PortMapping, configuration: NATPortMapperConfiguration) async throws
}
