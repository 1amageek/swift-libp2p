/// UPnPHandler - UPnP IGD protocol handler for NAT traversal
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// UPnP Internet Gateway Device protocol handler.
///
/// Implements NAT traversal using UPnP IGD:
/// 1. SSDP discovery via UDP multicast
/// 2. Device description fetch via HTTP
/// 3. Port mapping via SOAP requests
struct UPnPHandler: NATProtocolHandler {

    /// Maximum size (bytes) accepted for a UPnP device description or SOAP
    /// response. A malicious gateway could otherwise stream unbounded data.
    private static let maxResponseSize = 64 * 1024

    /// Allowlist of UPnP service type URNs we are willing to drive.
    /// Used to validate the `serviceType` before interpolating it into SOAP XML.
    private static let allowedServiceTypes: Set<String> = [
        "urn:schemas-upnp-org:service:WANIPConnection:1",
        "urn:schemas-upnp-org:service:WANIPConnection:2",
        "urn:schemas-upnp-org:service:WANPPPConnection:1"
    ]

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

        // SSRF guard: SSDP is unauthenticated UDP multicast, so the LOCATION
        // header is fully attacker-controllable. Only fetch it if it is an
        // http(s) URL whose host is a LAN IP literal (RFC1918/link-local).
        // This rejects file://, public hosts, and cloud metadata endpoints
        // such as 169.254.169.254.
        try Self.validateGatewayURL(locationURL)

        // Fetch device description and find control URL
        let (controlURL, serviceType) = try await fetchControlURL(from: locationURL, configuration: configuration)

        return .upnp(controlURL: controlURL, serviceType: serviceType)
    }

    /// Validates that a gateway-supplied URL is safe to fetch:
    /// - scheme must be `http` (UPnP device descriptions are plain HTTP)
    /// - host must be a LAN IP literal (RFC1918 private or link-local)
    ///
    /// Hostnames are rejected: we never resolve attacker-supplied DNS names for
    /// control traffic (the resolution result could point anywhere, including
    /// back at the host or at a cloud metadata service).
    static func validateGatewayURL(_ url: URL) throws {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" else {
            throw NATPortMapperError.untrustedGatewayURL("scheme not allowed: \(url.scheme ?? "nil")")
        }
        guard let host = url.host, !host.isEmpty else {
            throw NATPortMapperError.untrustedGatewayURL("missing host in \(url.absoluteString)")
        }
        // Strip IPv6 brackets if present.
        let bareHost = host.hasPrefix("[") && host.hasSuffix("]")
            ? String(host.dropFirst().dropLast())
            : host
        guard IPAddressValidator.parse(bareHost) != nil else {
            throw NATPortMapperError.untrustedGatewayURL("host is not a numeric IP literal: \(bareHost)")
        }
        // Require an RFC1918 private (or IPv6 ULA) address. Link-local is
        // explicitly excluded so the cloud metadata endpoint 169.254.169.254
        // (and other 169.254/16, fe80::/10 targets) cannot be reached: a UPnP
        // IGD always lives on the routed LAN, never on APIPA/link-local.
        guard IPAddressValidator.classify(bareHost) == .privateRange else {
            throw NATPortMapperError.untrustedGatewayURL("host is not an RFC1918 private address: \(bareHost)")
        }
    }

    func getExternalAddress(
        gateway: NATGatewayType,
        configuration: NATPortMapperConfiguration
    ) async throws -> String {
        guard case .upnp(let controlURL, let serviceType) = gateway else {
            throw NATPortMapperError.invalidResponse
        }
        try Self.validateServiceType(serviceType)

        let escapedServiceType = Self.xmlEscape(serviceType)
        let soapAction = "\"\(serviceType)#GetExternalIPAddress\""
        let soapBody = """
            <?xml version="1.0"?>
            <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
                <s:Body>
                    <u:GetExternalIPAddress xmlns:u="\(escapedServiceType)"/>
                </s:Body>
            </s:Envelope>
            """

        let response = try await sendSOAPRequest(
            to: controlURL, action: soapAction, body: soapBody, configuration: configuration
        )

        guard let ip = extractXMLTagValue(named: "NewExternalIPAddress", from: response) else {
            throw NATPortMapperError.externalAddressUnavailable
        }

        // The external IP returned by the gateway is untrusted: reject bogons.
        guard IPAddressValidator.isRoutableExternalAddress(ip) else {
            throw NATPortMapperError.invalidExternalAddress(ip)
        }
        return ip
    }

    /// Validates a service type against the URN allowlist before it is used in
    /// a SOAP action or interpolated into XML.
    static func validateServiceType(_ serviceType: String) throws {
        guard allowedServiceTypes.contains(serviceType) else {
            throw NATPortMapperError.untrustedGatewayURL("disallowed serviceType: \(serviceType)")
        }
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
        try Self.validateServiceType(serviceType)

        let localIP = try getLocalIPAddress()

        let escapedServiceType = Self.xmlEscape(serviceType)
        // Escape all attacker- or environment-influenced values before XML
        // interpolation to prevent SOAP/XML injection.
        let escapedLocalIP = Self.xmlEscape(localIP)
        let escapedDescription = Self.xmlEscape(configuration.mappingDescription)
        let soapAction = "\"\(serviceType)#AddPortMapping\""
        let soapBody = """
            <?xml version="1.0"?>
            <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
                <s:Body>
                    <u:AddPortMapping xmlns:u="\(escapedServiceType)">
                        <NewRemoteHost></NewRemoteHost>
                        <NewExternalPort>\(externalPort)</NewExternalPort>
                        <NewProtocol>\(`protocol`.rawValue)</NewProtocol>
                        <NewInternalPort>\(internalPort)</NewInternalPort>
                        <NewInternalClient>\(escapedLocalIP)</NewInternalClient>
                        <NewEnabled>1</NewEnabled>
                        <NewPortMappingDescription>\(escapedDescription)</NewPortMappingDescription>
                        <NewLeaseDuration>\(Int(duration.components.seconds))</NewLeaseDuration>
                    </u:AddPortMapping>
                </s:Body>
            </s:Envelope>
            """

        _ = try await sendSOAPRequest(
            to: controlURL, action: soapAction, body: soapBody, configuration: configuration
        )

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
        try Self.validateServiceType(serviceType)

        let escapedServiceType = Self.xmlEscape(serviceType)
        let soapAction = "\"\(serviceType)#DeletePortMapping\""
        let soapBody = """
            <?xml version="1.0"?>
            <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
                <s:Body>
                    <u:DeletePortMapping xmlns:u="\(escapedServiceType)">
                        <NewRemoteHost></NewRemoteHost>
                        <NewExternalPort>\(mapping.externalPort)</NewExternalPort>
                        <NewProtocol>\(mapping.protocol.rawValue)</NewProtocol>
                    </u:DeletePortMapping>
                </s:Body>
            </s:Envelope>
            """

        _ = try await sendSOAPRequest(
            to: controlURL, action: soapAction, body: soapBody, configuration: configuration
        )
    }

    // MARK: - Private

    private func fetchControlURL(
        from locationURL: URL,
        configuration: NATPortMapperConfiguration
    ) async throws -> (URL, String) {
        var request = URLRequest(url: locationURL)
        request.timeoutInterval = max(1, Double(configuration.discoveryTimeout.components.seconds))

        let (data, _) = try await URLSession.shared.data(for: request)
        guard data.count <= Self.maxResponseSize else {
            throw NATPortMapperError.invalidResponse
        }
        let xml = String(data: data, encoding: .utf8) ?? ""

        // Look for an allowlisted WANIPConnection / WANPPPConnection service.
        for serviceType in Self.allowedServiceTypes.sorted() {
            guard let serviceBlock = extractServiceBlock(containing: serviceType, from: xml) else {
                continue
            }
            if let controlPath = extractXMLTagValue(named: "controlURL", from: serviceBlock),
               let controlURL = URL(string: controlPath, relativeTo: locationURL)?.absoluteURL {
                // SSRF guard: the controlURL is gateway-supplied. It must be a
                // valid LAN http URL AND its host must match the LOCATION host;
                // otherwise the device description could redirect our SOAP POSTs
                // to an arbitrary internal target.
                try Self.validateGatewayURL(controlURL)
                guard controlURL.host == locationURL.host,
                      controlURL.port == locationURL.port else {
                    throw NATPortMapperError.untrustedGatewayURL(
                        "controlURL host \(controlURL.host ?? "nil"):\(controlURL.port.map(String.init) ?? "nil") differs from LOCATION host \(locationURL.host ?? "nil"):\(locationURL.port.map(String.init) ?? "nil")"
                    )
                }
                return (controlURL, serviceType)
            }
        }

        throw NATPortMapperError.invalidResponse
    }

    private func sendSOAPRequest(
        to url: URL,
        action: String,
        body: String,
        configuration: NATPortMapperConfiguration
    ) async throws -> String {
        // Defense in depth: validate the control URL again before every POST.
        try Self.validateGatewayURL(url)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = max(1, Double(configuration.discoveryTimeout.components.seconds))
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue(action, forHTTPHeaderField: "SOAPACTION")
        request.httpBody = Data(body.utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NATPortMapperError.invalidResponse
        }

        guard data.count <= Self.maxResponseSize else {
            throw NATPortMapperError.invalidResponse
        }

        if httpResponse.statusCode != 200 {
            let responseBody = String(data: data, encoding: .utf8) ?? ""
            throw NATPortMapperError.requestDenied("HTTP \(httpResponse.statusCode): \(responseBody)")
        }

        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Escapes XML special characters for safe interpolation into SOAP bodies.
    ///
    /// Prevents SOAP/XML injection from attacker-influenced values
    /// (`serviceType`, `localIP`, `mappingDescription`).
    static func xmlEscape(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.count)
        for character in value {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&apos;"
            default: result.append(character)
            }
        }
        return result
    }
}
