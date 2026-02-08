/// PCPHandler - PCP (Port Control Protocol, RFC 6887) handler for NAT traversal
import Foundation

/// PCP (RFC 6887) protocol handler.
///
/// Port Control Protocol is the successor to NAT-PMP.
/// Supports IPv4 and IPv6, and provides additional capabilities.
struct PCPHandler: NATProtocolHandler {
    // PCP version
    private static let version: UInt8 = 2
    // MAP opcode
    private static let mapOpcode: UInt8 = 1
    // IANA protocol numbers
    private static let protocolTCP: UInt8 = 6
    private static let protocolUDP: UInt8 = 17

    // PCP result codes
    private static let resultSuccess: UInt8 = 0

    func discoverGateway(configuration: NATPortMapperConfiguration) async throws -> NATGatewayType {
        let gatewayIP = try await getDefaultGateway()

        // Verify PCP support by sending ANNOUNCE (opcode=0)
        let request = buildAnnounceRequest()
        let socket = try UDPSocket()
        let response = try socket.sendAndReceive(
            to: gatewayIP,
            port: configuration.natpmpPort, // PCP uses same port 5351
            data: Array(request),
            responseSize: 24,
            timeout: configuration.discoveryTimeout
        )

        guard response.count >= 4, response[0] == PCPHandler.version else {
            throw NATPortMapperError.invalidResponse
        }

        let resultCode = response[3]
        // SUCCESS or UNSUPP_VERSION are both valid indicators of a PCP-capable gateway
        if resultCode != 0 && resultCode != 1 {
            throw NATPortMapperError.requestDenied("PCP error: \(resultCode)")
        }

        return .pcp(gatewayIP: gatewayIP)
    }

    func getExternalAddress(
        gateway: NATGatewayType,
        configuration: NATPortMapperConfiguration
    ) async throws -> String {
        guard case .pcp(let gatewayIP) = gateway else {
            throw NATPortMapperError.invalidResponse
        }

        // PCP MAP with protocol=0 returns external address
        let request = buildMAPRequest(
            internalPort: 0,
            suggestedExternalPort: 0,
            protocol: 0,
            lifetime: 0
        )

        let socket = try UDPSocket()
        let response = try socket.sendAndReceive(
            to: gatewayIP,
            port: configuration.natpmpPort,
            data: Array(request),
            responseSize: 60,
            timeout: configuration.discoveryTimeout
        )

        return try parseExternalAddress(from: response)
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
        guard case .pcp(let gatewayIP) = gateway else {
            throw NATPortMapperError.invalidResponse
        }

        let ianaProtocol: UInt8 = `protocol` == .udp ? PCPHandler.protocolUDP : PCPHandler.protocolTCP
        let lifetime = UInt32(clamping: duration.components.seconds)

        let request = buildMAPRequest(
            internalPort: internalPort,
            suggestedExternalPort: externalPort,
            protocol: ianaProtocol,
            lifetime: lifetime
        )

        let socket = try UDPSocket()
        let response = try socket.sendAndReceive(
            to: gatewayIP,
            port: configuration.natpmpPort,
            data: Array(request),
            responseSize: 60,
            timeout: configuration.discoveryTimeout
        )

        return try parseMAPResponse(
            response,
            gateway: gateway,
            internalPort: internalPort,
            externalAddress: externalAddress
        )
    }

    func releaseMapping(_ mapping: PortMapping, configuration: NATPortMapperConfiguration) async throws {
        _ = try await requestMapping(
            gateway: mapping.gatewayType,
            internalPort: mapping.internalPort,
            externalPort: 0,
            protocol: mapping.protocol,
            duration: .zero,
            externalAddress: mapping.externalAddress,
            configuration: configuration
        )
    }

    // MARK: - Private

    private func buildAnnounceRequest() -> Data {
        var data = Data(count: 24) // Minimum PCP header with client IP
        data[0] = PCPHandler.version
        data[1] = 0 // R=0, Opcode=0 (ANNOUNCE)
        // Reserved(2), Lifetime(4) = 0, ClientIP(16) = all zeros (server will use source)
        return data
    }

    private func buildMAPRequest(
        internalPort: UInt16,
        suggestedExternalPort: UInt16,
        protocol: UInt8,
        lifetime: UInt32
    ) -> Data {
        var data = Data(count: 60) // 24 header + 36 MAP payload

        // Header
        data[0] = PCPHandler.version
        data[1] = PCPHandler.mapOpcode // R=0 | MAP(1)
        // Reserved (2 bytes) = 0
        data[4] = UInt8((lifetime >> 24) & 0xFF)
        data[5] = UInt8((lifetime >> 16) & 0xFF)
        data[6] = UInt8((lifetime >> 8) & 0xFF)
        data[7] = UInt8(lifetime & 0xFF)
        // Client IP (16 bytes): IPv4-mapped IPv6 (::ffff:0.0.0.0)
        data[18] = 0xFF
        data[19] = 0xFF
        // Remaining 4 bytes of client IP left as 0 (server uses source address)

        // MAP payload (offset 24)
        // Nonce (12 bytes) - random for tracking
        for i in 24..<36 {
            data[i] = UInt8.random(in: 0...255)
        }
        data[36] = `protocol` // Protocol
        // Reserved (3 bytes) = 0
        data[40] = UInt8(internalPort >> 8)
        data[41] = UInt8(internalPort & 0xFF)
        data[42] = UInt8(suggestedExternalPort >> 8)
        data[43] = UInt8(suggestedExternalPort & 0xFF)
        // Suggested external address (16 bytes): all zeros = wildcard

        return data
    }

    private func parseExternalAddress(from response: [UInt8]) throws -> String {
        guard response.count >= 60 else {
            throw NATPortMapperError.invalidResponse
        }

        guard response[0] == PCPHandler.version else {
            throw NATPortMapperError.invalidResponse
        }

        let resultCode = response[3]
        guard resultCode == PCPHandler.resultSuccess else {
            throw NATPortMapperError.requestDenied("PCP error code: \(resultCode)")
        }

        // Assigned external address at offset 44, 16 bytes (IPv6 or IPv4-mapped)
        // Check if IPv4-mapped (::ffff:x.x.x.x)
        let isIPv4Mapped = response[44..<54].allSatisfy { $0 == 0 } &&
                           response[54] == 0xFF && response[55] == 0xFF

        if isIPv4Mapped {
            return "\(response[56]).\(response[57]).\(response[58]).\(response[59])"
        } else {
            // Full IPv6
            var parts: [String] = []
            for i in stride(from: 44, to: 60, by: 2) {
                let value = UInt16(response[i]) << 8 | UInt16(response[i + 1])
                parts.append(String(value, radix: 16))
            }
            return parts.joined(separator: ":")
        }
    }

    private func parseMAPResponse(
        _ response: [UInt8],
        gateway: NATGatewayType,
        internalPort: UInt16,
        externalAddress: String
    ) throws -> PortMapping {
        guard response.count >= 60 else {
            throw NATPortMapperError.invalidResponse
        }

        guard response[0] == PCPHandler.version else {
            throw NATPortMapperError.invalidResponse
        }

        let resultCode = response[3]
        guard resultCode == PCPHandler.resultSuccess else {
            throw NATPortMapperError.requestDenied("PCP error code: \(resultCode)")
        }

        // Lifetime from response header (offset 4-7)
        let assignedLifetime = UInt32(response[4]) << 24 | UInt32(response[5]) << 16 |
                               UInt32(response[6]) << 8 | UInt32(response[7])

        // Protocol from MAP response (offset 36)
        let responseProtocol: NATTransportProtocol = response[36] == PCPHandler.protocolUDP ? .udp : .tcp

        // Assigned external port (offset 42-43)
        let assignedPort = UInt16(response[42]) << 8 | UInt16(response[43])

        return PortMapping(
            internalPort: internalPort,
            externalPort: assignedPort,
            externalAddress: externalAddress,
            protocol: responseProtocol,
            expiration: ContinuousClock.now + .seconds(Int64(assignedLifetime)),
            gatewayType: gateway
        )
    }
}
