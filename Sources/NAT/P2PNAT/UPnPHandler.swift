/// UPnPHandler - UPnP IGD protocol handler for NAT traversal
import Foundation

/// UPnP Internet Gateway Device protocol handler.
///
/// Implements NAT traversal using UPnP IGD:
/// 1. SSDP discovery via UDP multicast
/// 2. Device description fetch via HTTP
/// 3. Port mapping via SOAP requests
struct UPnPHandler: NATProtocolHandler {

    func discoverGateway(configuration: NATPortMapperConfiguration) async throws -> NATGatewayType {
        // SSDP M-SEARCH for Internet Gateway Device
        let ssdpAddress = "239.255.255.250"
        let ssdpPort: UInt16 = 1900

        let searchRequest = [
            "M-SEARCH * HTTP/1.1",
            "HOST: 239.255.255.250:1900",
            "MAN: \"ssdp:discover\"",
            "MX: 3",
            "ST: urn:schemas-upnp-org:device:InternetGatewayDevice:1",
            "",
            "",
        ].joined(separator: "\r\n")

        // Send SSDP request via UDP
        let socket = try UDPSocket()
        let response = try socket.sendAndReceive(
            to: ssdpAddress,
            port: ssdpPort,
            data: Array(searchRequest.utf8),
            responseSize: 4096,
            timeout: configuration.discoveryTimeout
        )

        let responseStr = String(bytes: response, encoding: .utf8) ?? ""

        // Parse LOCATION header
        guard let locationRange = responseStr.range(of: "LOCATION:", options: .caseInsensitive),
              let endRange = responseStr.range(of: "\r\n", range: locationRange.upperBound..<responseStr.endIndex),
              let locationURL = URL(string: String(responseStr[locationRange.upperBound..<endRange.lowerBound]).trimmingCharacters(in: .whitespaces)) else {
            throw NATPortMapperError.invalidResponse
        }

        // Fetch device description and find control URL
        let (controlURL, serviceType) = try await fetchControlURL(from: locationURL, configuration: configuration)

        return .upnp(controlURL: controlURL, serviceType: serviceType)
    }

    func getExternalAddress(
        gateway: NATGatewayType,
        configuration: NATPortMapperConfiguration
    ) async throws -> String {
        guard case .upnp(let controlURL, let serviceType) = gateway else {
            throw NATPortMapperError.invalidResponse
        }

        let soapAction = "\"\(serviceType)#GetExternalIPAddress\""
        let soapBody = """
            <?xml version="1.0"?>
            <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
                <s:Body>
                    <u:GetExternalIPAddress xmlns:u="\(serviceType)"/>
                </s:Body>
            </s:Envelope>
            """

        let response = try await sendSOAPRequest(to: controlURL, action: soapAction, body: soapBody)

        guard let ip = extractXMLTagValue(named: "NewExternalIPAddress", from: response) else {
            throw NATPortMapperError.externalAddressUnavailable
        }

        return ip
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
        guard case .upnp(let controlURL, let serviceType) = gateway else {
            throw NATPortMapperError.invalidResponse
        }

        let localIP = try getLocalIPAddress()

        let soapAction = "\"\(serviceType)#AddPortMapping\""
        let soapBody = """
            <?xml version="1.0"?>
            <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
                <s:Body>
                    <u:AddPortMapping xmlns:u="\(serviceType)">
                        <NewRemoteHost></NewRemoteHost>
                        <NewExternalPort>\(externalPort)</NewExternalPort>
                        <NewProtocol>\(`protocol`.rawValue)</NewProtocol>
                        <NewInternalPort>\(internalPort)</NewInternalPort>
                        <NewInternalClient>\(localIP)</NewInternalClient>
                        <NewEnabled>1</NewEnabled>
                        <NewPortMappingDescription>\(configuration.mappingDescription)</NewPortMappingDescription>
                        <NewLeaseDuration>\(Int(duration.components.seconds))</NewLeaseDuration>
                    </u:AddPortMapping>
                </s:Body>
            </s:Envelope>
            """

        _ = try await sendSOAPRequest(to: controlURL, action: soapAction, body: soapBody)

        return PortMapping(
            internalPort: internalPort,
            externalPort: externalPort,
            externalAddress: externalAddress,
            protocol: `protocol`,
            expiration: ContinuousClock.now + duration,
            gatewayType: gateway
        )
    }

    func releaseMapping(_ mapping: PortMapping, configuration: NATPortMapperConfiguration) async throws {
        guard case .upnp(let controlURL, let serviceType) = mapping.gatewayType else {
            throw NATPortMapperError.invalidResponse
        }

        let soapAction = "\"\(serviceType)#DeletePortMapping\""
        let soapBody = """
            <?xml version="1.0"?>
            <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
                <s:Body>
                    <u:DeletePortMapping xmlns:u="\(serviceType)">
                        <NewRemoteHost></NewRemoteHost>
                        <NewExternalPort>\(mapping.externalPort)</NewExternalPort>
                        <NewProtocol>\(mapping.protocol.rawValue)</NewProtocol>
                    </u:DeletePortMapping>
                </s:Body>
            </s:Envelope>
            """

        _ = try await sendSOAPRequest(to: controlURL, action: soapAction, body: soapBody)
    }

    // MARK: - Private

    private func fetchControlURL(
        from locationURL: URL,
        configuration: NATPortMapperConfiguration
    ) async throws -> (URL, String) {
        var request = URLRequest(url: locationURL)
        request.timeoutInterval = Double(configuration.discoveryTimeout.components.seconds)

        let (data, _) = try await URLSession.shared.data(for: request)
        let xml = String(data: data, encoding: .utf8) ?? ""

        // Look for WANIPConnection or WANPPPConnection service
        let serviceTypes = [
            "urn:schemas-upnp-org:service:WANIPConnection:1",
            "urn:schemas-upnp-org:service:WANPPPConnection:1"
        ]

        for serviceType in serviceTypes {
            guard let serviceBlock = extractServiceBlock(containing: serviceType, from: xml) else {
                continue
            }
            if let controlPath = extractXMLTagValue(named: "controlURL", from: serviceBlock),
               let controlURL = URL(string: controlPath, relativeTo: locationURL) {
                return (controlURL, serviceType)
            }
        }

        throw NATPortMapperError.invalidResponse
    }

    private func sendSOAPRequest(to url: URL, action: String, body: String) async throws -> String {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue(action, forHTTPHeaderField: "SOAPACTION")
        request.httpBody = Data(body.utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NATPortMapperError.invalidResponse
        }

        if httpResponse.statusCode != 200 {
            let responseBody = String(data: data, encoding: .utf8) ?? ""
            throw NATPortMapperError.requestDenied("HTTP \(httpResponse.statusCode): \(responseBody)")
        }

        return String(data: data, encoding: .utf8) ?? ""
    }
}
