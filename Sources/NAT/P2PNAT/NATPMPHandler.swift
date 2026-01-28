/// NATPMPHandler - NAT-PMP protocol handler for NAT traversal
import Foundation

/// NAT-PMP (RFC 6886) protocol handler.
///
/// Implements NAT traversal using NAT-PMP:
/// 1. Gateway discovery via default route
/// 2. External address request (opcode 0)
/// 3. Port mapping request (opcode 1=UDP, 2=TCP)
struct NATPMPHandler: NATProtocolHandler {

    func discoverGateway(configuration: NATPortMapperConfiguration) async throws -> NATGatewayType {
        let gatewayIP = try await getDefaultGateway()
        return .natpmp(gatewayIP: gatewayIP)
    }

    func getExternalAddress(
        gateway: NATGatewayType,
        configuration: NATPortMapperConfiguration
    ) async throws -> String {
        guard case .natpmp(let gatewayIP) = gateway else {
            throw NATPortMapperError.invalidResponse
        }

        // Send external address request (opcode 0)
        let request: [UInt8] = [0, 0] // Version 0, Opcode 0

        let socket = try UDPSocket()
        let response = try socket.sendAndReceive(
            to: gatewayIP,
            port: configuration.natpmpPort,
            data: request,
            responseSize: 12,
            timeout: configuration.discoveryTimeout
        )

        if response.count < 12 {
            throw NATPortMapperError.invalidResponse
        }

        // Parse response
        let resultCode = UInt16(response[2]) << 8 | UInt16(response[3])
        if resultCode != 0 {
            throw NATPortMapperError.requestDenied("NAT-PMP error code: \(resultCode)")
        }

        // Extract IP address (bytes 8-11)
        return "\(response[8]).\(response[9]).\(response[10]).\(response[11])"
    }

    func requestMapping(
        gateway: NATGatewayType,
        internalPort: UInt16,
        externalPort: UInt16,
        protocol: NATTransportProtocol,
        duration: Duration,
        externalAddress: String,
        configuration: NATPortMapperConfiguration
    ) async throws -> PortMapping {
        guard case .natpmp(let gatewayIP) = gateway else {
            throw NATPortMapperError.invalidResponse
        }

        // Build request
        let opcode: UInt8 = `protocol` == .udp ? 1 : 2
        let lifetime = UInt32(duration.components.seconds)

        var request: [UInt8] = [0, opcode, 0, 0] // Version, Opcode, Reserved
        request.append(UInt8(internalPort >> 8))
        request.append(UInt8(internalPort & 0xFF))
        request.append(UInt8(externalPort >> 8))
        request.append(UInt8(externalPort & 0xFF))
        request.append(UInt8((lifetime >> 24) & 0xFF))
        request.append(UInt8((lifetime >> 16) & 0xFF))
        request.append(UInt8((lifetime >> 8) & 0xFF))
        request.append(UInt8(lifetime & 0xFF))

        let socket = try UDPSocket()
        let response = try socket.sendAndReceive(
            to: gatewayIP,
            port: configuration.natpmpPort,
            data: request,
            responseSize: 16,
            timeout: configuration.discoveryTimeout
        )

        if response.count < 16 {
            throw NATPortMapperError.invalidResponse
        }

        // Parse response
        let resultCode = UInt16(response[2]) << 8 | UInt16(response[3])
        if resultCode != 0 {
            throw NATPortMapperError.requestDenied("NAT-PMP error code: \(resultCode)")
        }

        let assignedPort = UInt16(response[10]) << 8 | UInt16(response[11])
        let assignedLifetime = UInt32(response[12]) << 24 | UInt32(response[13]) << 16 | UInt32(response[14]) << 8 | UInt32(response[15])

        return PortMapping(
            internalPort: internalPort,
            externalPort: assignedPort,
            externalAddress: externalAddress,
            protocol: `protocol`,
            expiration: ContinuousClock.now + .seconds(Int64(assignedLifetime)),
            gatewayType: gateway
        )
    }

    func releaseMapping(_ mapping: PortMapping, configuration: NATPortMapperConfiguration) async throws {
        guard case .natpmp(let gatewayIP) = mapping.gatewayType else {
            throw NATPortMapperError.invalidResponse
        }

        // Release by setting lifetime to 0
        _ = try await requestMapping(
            gateway: .natpmp(gatewayIP: gatewayIP),
            internalPort: mapping.internalPort,
            externalPort: 0,
            protocol: mapping.protocol,
            duration: .zero,
            externalAddress: mapping.externalAddress,
            configuration: configuration
        )
    }
}
