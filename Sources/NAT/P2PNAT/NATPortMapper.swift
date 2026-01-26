/// NATPortMapper - Unified NAT port mapping service
///
/// Supports both UPnP IGD and NAT-PMP protocols for automatic
/// port forwarding configuration on NAT routers.
import Foundation
import P2PCore
import Synchronization

/// Transport protocol for port mapping.
public enum NATTransportProtocol: String, Sendable {
    case tcp = "TCP"
    case udp = "UDP"
}

/// Type of NAT gateway discovered.
public enum NATGatewayType: Sendable, Equatable {
    /// UPnP Internet Gateway Device
    case upnp(controlURL: URL, serviceType: String)
    /// NAT-PMP gateway
    case natpmp(gatewayIP: String)
}

/// A successful port mapping.
public struct PortMapping: Sendable, Equatable {
    /// The internal (local) port.
    public let internalPort: UInt16

    /// The external (public) port.
    public let externalPort: UInt16

    /// The external (public) IP address.
    public let externalAddress: String

    /// The protocol (TCP or UDP).
    public let `protocol`: NATTransportProtocol

    /// When this mapping expires.
    public let expiration: ContinuousClock.Instant

    /// The gateway type that created this mapping.
    public let gatewayType: NATGatewayType

    /// Whether this mapping is still valid.
    public var isValid: Bool {
        ContinuousClock.now < expiration
    }

    /// Creates a Multiaddr representing the external address.
    public var multiaddr: Multiaddr? {
        switch `protocol` {
        case .tcp:
            return try? Multiaddr("/ip4/\(externalAddress)/tcp/\(externalPort)")
        case .udp:
            return try? Multiaddr("/ip4/\(externalAddress)/udp/\(externalPort)")
        }
    }
}

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

/// Errors from NATPortMapper.
public enum NATPortMapperError: Error, Sendable {
    /// No gateway was discovered.
    case noGatewayFound
    /// Gateway discovery timed out.
    case discoveryTimeout
    /// Failed to get external address.
    case externalAddressUnavailable
    /// Port mapping request failed.
    case mappingFailed(String)
    /// Port already in use.
    case portInUse
    /// Gateway rejected the request.
    case requestDenied(String)
    /// Network error.
    case networkError(String)
    /// Invalid response from gateway.
    case invalidResponse
    /// Service is shutdown.
    case shutdown
}

/// Configuration for NATPortMapper.
public struct NATPortMapperConfiguration: Sendable {
    /// Timeout for gateway discovery.
    public var discoveryTimeout: Duration

    /// Default mapping duration.
    public var defaultLeaseDuration: Duration

    /// Buffer before expiration to renew.
    public var renewalBuffer: Duration

    /// Whether to automatically renew mappings.
    public var autoRenew: Bool

    /// Whether to try UPnP.
    public var tryUPnP: Bool

    /// Whether to try NAT-PMP.
    public var tryNATPMP: Bool

    /// NAT-PMP port (default: 5351).
    public var natpmpPort: UInt16

    public init(
        discoveryTimeout: Duration = .seconds(5),
        defaultLeaseDuration: Duration = .seconds(3600),
        renewalBuffer: Duration = .seconds(300),
        autoRenew: Bool = true,
        tryUPnP: Bool = true,
        tryNATPMP: Bool = true,
        natpmpPort: UInt16 = 5351
    ) {
        self.discoveryTimeout = discoveryTimeout
        self.defaultLeaseDuration = defaultLeaseDuration
        self.renewalBuffer = renewalBuffer
        self.autoRenew = autoRenew
        self.tryUPnP = tryUPnP
        self.tryNATPMP = tryNATPMP
        self.natpmpPort = natpmpPort
    }

    public static let `default` = NATPortMapperConfiguration()
}

/// Internal state for NATPortMapper.
private struct NATPortMapperState: Sendable {
    var discoveredGateway: NATGatewayType?
    var externalAddress: String?
    var activeMappings: [UInt16: PortMapping] = [:]
    var renewalTasks: [UInt16: Task<Void, Never>] = [:]
    var isShutdown = false
}

/// Event state for NATPortMapper.
private struct NATPortMapperEventState: Sendable {
    var stream: AsyncStream<NATPortMapperEvent>?
    var continuation: AsyncStream<NATPortMapperEvent>.Continuation?
}

/// NAT port mapping service.
///
/// Discovers NAT gateways and creates port mappings to enable
/// inbound connections through NAT.
public final class NATPortMapper: Sendable {

    public let configuration: NATPortMapperConfiguration

    private let state: Mutex<NATPortMapperState>
    private let eventState: Mutex<NATPortMapperEventState>

    /// Creates a new NATPortMapper.
    public init(configuration: NATPortMapperConfiguration = .default) {
        self.configuration = configuration
        self.state = Mutex(NATPortMapperState())
        self.eventState = Mutex(NATPortMapperEventState())
    }

    /// Stream of events from this mapper.
    public var events: AsyncStream<NATPortMapperEvent> {
        eventState.withLock { state in
            if let existing = state.stream { return existing }
            let (stream, continuation) = AsyncStream<NATPortMapperEvent>.makeStream()
            state.stream = stream
            state.continuation = continuation
            return stream
        }
    }

    // MARK: - Public API

    /// Discovers a NAT gateway.
    ///
    /// Tries UPnP first, then NAT-PMP.
    public func discoverGateway() async throws -> NATGatewayType {
        let isShutdown = state.withLock { $0.isShutdown }
        if isShutdown { throw NATPortMapperError.shutdown }

        // Check if we already have a gateway
        if let existing = state.withLock({ $0.discoveredGateway }) {
            return existing
        }

        // Try UPnP first
        if configuration.tryUPnP {
            if let gateway = try? await discoverUPnPGateway() {
                state.withLock { $0.discoveredGateway = gateway }
                emit(.gatewayDiscovered(type: gateway))
                return gateway
            }
        }

        // Try NAT-PMP
        if configuration.tryNATPMP {
            if let gateway = try? await discoverNATPMPGateway() {
                state.withLock { $0.discoveredGateway = gateway }
                emit(.gatewayDiscovered(type: gateway))
                return gateway
            }
        }

        throw NATPortMapperError.noGatewayFound
    }

    /// Gets the external IP address.
    public func discoverExternalAddress() async throws -> String {
        let isShutdown = state.withLock { $0.isShutdown }
        if isShutdown { throw NATPortMapperError.shutdown }

        // Check cache
        if let cached = state.withLock({ $0.externalAddress }) {
            return cached
        }

        let gateway = try await discoverGateway()

        let address: String
        switch gateway {
        case .upnp(let controlURL, let serviceType):
            address = try await getExternalAddressUPnP(controlURL: controlURL, serviceType: serviceType)
        case .natpmp(let gatewayIP):
            address = try await getExternalAddressNATPMP(gatewayIP: gatewayIP)
        }

        state.withLock { $0.externalAddress = address }
        emit(.externalAddressDiscovered(address: address))
        return address
    }

    /// Requests a port mapping.
    ///
    /// - Parameters:
    ///   - internalPort: The local port to map.
    ///   - externalPort: The desired external port (nil = same as internal).
    ///   - protocol: TCP or UDP.
    ///   - duration: How long the mapping should last.
    ///   - description: Description for the mapping.
    /// - Returns: The created port mapping.
    public func requestMapping(
        internalPort: UInt16,
        externalPort: UInt16? = nil,
        protocol: NATTransportProtocol,
        duration: Duration? = nil,
        description: String = "libp2p"
    ) async throws -> PortMapping {
        let isShutdown = state.withLock { $0.isShutdown }
        if isShutdown { throw NATPortMapperError.shutdown }

        let gateway = try await discoverGateway()
        let extPort = externalPort ?? internalPort
        let leaseDuration = duration ?? configuration.defaultLeaseDuration

        let mapping: PortMapping
        switch gateway {
        case .upnp(let controlURL, let serviceType):
            mapping = try await requestMappingUPnP(
                controlURL: controlURL,
                serviceType: serviceType,
                internalPort: internalPort,
                externalPort: extPort,
                protocol: `protocol`,
                duration: leaseDuration,
                description: description
            )
        case .natpmp(let gatewayIP):
            mapping = try await requestMappingNATPMP(
                gatewayIP: gatewayIP,
                internalPort: internalPort,
                externalPort: extPort,
                protocol: `protocol`,
                duration: leaseDuration
            )
        }

        state.withLock { $0.activeMappings[internalPort] = mapping }
        emit(.portMappingCreated(mapping: mapping))

        // Schedule renewal if enabled
        if configuration.autoRenew {
            scheduleRenewal(for: mapping)
        }

        return mapping
    }

    /// Releases a port mapping.
    public func releaseMapping(_ mapping: PortMapping) async throws {
        let isShutdown = state.withLock { $0.isShutdown }
        if isShutdown { throw NATPortMapperError.shutdown }

        // Cancel renewal task
        let task = state.withLock { state -> Task<Void, Never>? in
            let t = state.renewalTasks.removeValue(forKey: mapping.internalPort)
            _ = state.activeMappings.removeValue(forKey: mapping.internalPort)
            return t
        }
        task?.cancel()

        switch mapping.gatewayType {
        case .upnp(let controlURL, let serviceType):
            try await releaseMappingUPnP(
                controlURL: controlURL,
                serviceType: serviceType,
                externalPort: mapping.externalPort,
                protocol: mapping.protocol
            )
        case .natpmp(let gatewayIP):
            try await releaseMappingNATPMP(
                gatewayIP: gatewayIP,
                internalPort: mapping.internalPort,
                protocol: mapping.protocol
            )
        }
    }

    /// Shuts down the mapper and releases all mappings.
    public func shutdown() {
        let capture = state.withLock { state -> (mappings: [PortMapping], tasks: [Task<Void, Never>]) in
            guard !state.isShutdown else { return ([], []) }
            state.isShutdown = true
            let m = Array(state.activeMappings.values)
            let t = Array(state.renewalTasks.values)
            state.activeMappings.removeAll()
            state.renewalTasks.removeAll()
            return (m, t)
        }

        // Cancel all renewal tasks
        for task in capture.tasks {
            task.cancel()
        }

        // Finish event stream
        eventState.withLock { state in
            state.continuation?.finish()
            state.continuation = nil
            state.stream = nil
        }
    }

    // MARK: - Private

    private func emit(_ event: NATPortMapperEvent) {
        eventState.withLock { state in
            _ = state.continuation?.yield(event)
        }
    }

    private func scheduleRenewal(for mapping: PortMapping) {
        let renewalTime = mapping.expiration - configuration.renewalBuffer

        let task = Task { [weak self] in
            guard let self = self else { return }

            do {
                try await Task.sleep(until: renewalTime, clock: .continuous)
            } catch {
                return // Cancelled
            }

            let isShutdown = self.state.withLock { $0.isShutdown }
            if isShutdown { return }

            do {
                let renewed = try await self.requestMapping(
                    internalPort: mapping.internalPort,
                    externalPort: mapping.externalPort,
                    protocol: mapping.protocol,
                    duration: nil,
                    description: "libp2p"
                )
                self.emit(.portMappingRenewed(mapping: renewed))
            } catch {
                self.emit(.portMappingFailed(
                    internalPort: mapping.internalPort,
                    error: .mappingFailed("Renewal failed: \(error)")
                ))
                self.emit(.portMappingExpired(mapping: mapping))
            }
        }

        state.withLock { $0.renewalTasks[mapping.internalPort] = task }
    }

    // MARK: - UPnP Implementation

    private func discoverUPnPGateway() async throws -> NATGatewayType {
        // SSDP M-SEARCH for Internet Gateway Device
        let ssdpAddress = "239.255.255.250"
        let ssdpPort: UInt16 = 1900

        let searchRequest = """
            M-SEARCH * HTTP/1.1\r
            HOST: 239.255.255.250:1900\r
            MAN: "ssdp:discover"\r
            MX: 3\r
            ST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r
            \r

            """

        // Create UDP socket
        let socket = try createUDPSocket()
        defer { close(socket) }

        // Send discovery request
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = ssdpPort.bigEndian
        inet_pton(AF_INET, ssdpAddress, &addr.sin_addr)

        let data = Data(searchRequest.utf8)
        let sent = data.withUnsafeBytes { ptr in
            withUnsafePointer(to: &addr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    sendto(socket, ptr.baseAddress, data.count, 0, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        if sent < 0 {
            throw NATPortMapperError.networkError("Failed to send SSDP request")
        }

        // Wait for response with timeout
        var readfds = fd_set()
        __darwin_fd_zero(&readfds)
        __darwin_fd_set(socket, &readfds)

        var timeout = timeval(tv_sec: Int(configuration.discoveryTimeout.components.seconds), tv_usec: 0)
        let selectResult = select(socket + 1, &readfds, nil, nil, &timeout)

        if selectResult <= 0 {
            throw NATPortMapperError.discoveryTimeout
        }

        // Read response
        var buffer = [UInt8](repeating: 0, count: 4096)
        let received = recv(socket, &buffer, buffer.count, 0)
        if received <= 0 {
            throw NATPortMapperError.invalidResponse
        }

        let response = String(bytes: buffer.prefix(received), encoding: .utf8) ?? ""

        // Parse LOCATION header
        guard let locationRange = response.range(of: "LOCATION:", options: .caseInsensitive),
              let endRange = response.range(of: "\r\n", range: locationRange.upperBound..<response.endIndex),
              let locationURL = URL(string: String(response[locationRange.upperBound..<endRange.lowerBound]).trimmingCharacters(in: .whitespaces)) else {
            throw NATPortMapperError.invalidResponse
        }

        // Fetch device description and find control URL
        let (controlURL, serviceType) = try await fetchUPnPControlURL(from: locationURL)

        return .upnp(controlURL: controlURL, serviceType: serviceType)
    }

    private func fetchUPnPControlURL(from locationURL: URL) async throws -> (URL, String) {
        var request = URLRequest(url: locationURL)
        request.timeoutInterval = Double(configuration.discoveryTimeout.components.seconds)

        let (data, _) = try await URLSession.shared.data(for: request)
        let xml = String(data: data, encoding: .utf8) ?? ""

        // Simple XML parsing for control URL
        // Look for WANIPConnection or WANPPPConnection service
        let serviceTypes = [
            "urn:schemas-upnp-org:service:WANIPConnection:1",
            "urn:schemas-upnp-org:service:WANPPPConnection:1"
        ]

        for serviceType in serviceTypes {
            if let controlPath = extractControlURL(from: xml, serviceType: serviceType) {
                let controlURL = URL(string: controlPath, relativeTo: locationURL)!
                return (controlURL, serviceType)
            }
        }

        throw NATPortMapperError.invalidResponse
    }

    private func extractControlURL(from xml: String, serviceType: String) -> String? {
        // Find the service block
        guard xml.contains(serviceType) else { return nil }

        // Extract controlURL - simple regex-like parsing
        let pattern = "<controlURL>([^<]+)</controlURL>"
        if let range = xml.range(of: pattern, options: .regularExpression) {
            let match = String(xml[range])
            let start = match.index(match.startIndex, offsetBy: 12) // "<controlURL>".count
            let end = match.index(match.endIndex, offsetBy: -13) // "</controlURL>".count
            if start < end {
                return String(match[start..<end])
            }
        }

        return nil
    }

    private func getExternalAddressUPnP(controlURL: URL, serviceType: String) async throws -> String {
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

        // Extract IP from response
        let pattern = "<NewExternalIPAddress>([^<]+)</NewExternalIPAddress>"
        if let range = response.range(of: pattern, options: .regularExpression) {
            let match = String(response[range])
            let start = match.index(match.startIndex, offsetBy: 22)
            let end = match.index(match.endIndex, offsetBy: -23)
            if start < end {
                return String(match[start..<end])
            }
        }

        throw NATPortMapperError.externalAddressUnavailable
    }

    private func requestMappingUPnP(
        controlURL: URL,
        serviceType: String,
        internalPort: UInt16,
        externalPort: UInt16,
        protocol: NATTransportProtocol,
        duration: Duration,
        description: String
    ) async throws -> PortMapping {
        // Get local IP address
        let localIP = try getLocalIPAddress()
        let externalAddress = try await discoverExternalAddress()

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
                        <NewPortMappingDescription>\(description)</NewPortMappingDescription>
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
            gatewayType: .upnp(controlURL: controlURL, serviceType: serviceType)
        )
    }

    private func releaseMappingUPnP(
        controlURL: URL,
        serviceType: String,
        externalPort: UInt16,
        protocol: NATTransportProtocol
    ) async throws {
        let soapAction = "\"\(serviceType)#DeletePortMapping\""
        let soapBody = """
            <?xml version="1.0"?>
            <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
                <s:Body>
                    <u:DeletePortMapping xmlns:u="\(serviceType)">
                        <NewRemoteHost></NewRemoteHost>
                        <NewExternalPort>\(externalPort)</NewExternalPort>
                        <NewProtocol>\(`protocol`.rawValue)</NewProtocol>
                    </u:DeletePortMapping>
                </s:Body>
            </s:Envelope>
            """

        _ = try await sendSOAPRequest(to: controlURL, action: soapAction, body: soapBody)
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

    // MARK: - NAT-PMP Implementation

    private func discoverNATPMPGateway() async throws -> NATGatewayType {
        let gatewayIP = try getDefaultGateway()
        return .natpmp(gatewayIP: gatewayIP)
    }

    private func getExternalAddressNATPMP(gatewayIP: String) async throws -> String {
        let socket = try createUDPSocket()
        defer { close(socket) }

        // Connect to gateway
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = configuration.natpmpPort.bigEndian
        inet_pton(AF_INET, gatewayIP, &addr.sin_addr)

        // Send external address request (opcode 0)
        var request: [UInt8] = [0, 0] // Version 0, Opcode 0
        let sent = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                sendto(socket, &request, request.count, 0, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        if sent < 0 {
            throw NATPortMapperError.networkError("Failed to send NAT-PMP request")
        }

        // Wait for response
        var readfds = fd_set()
        __darwin_fd_zero(&readfds)
        __darwin_fd_set(socket, &readfds)

        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        let selectResult = select(socket + 1, &readfds, nil, nil, &timeout)

        if selectResult <= 0 {
            throw NATPortMapperError.discoveryTimeout
        }

        // Read response
        var buffer = [UInt8](repeating: 0, count: 12)
        let received = recv(socket, &buffer, buffer.count, 0)
        if received < 12 {
            throw NATPortMapperError.invalidResponse
        }

        // Parse response
        let resultCode = UInt16(buffer[2]) << 8 | UInt16(buffer[3])
        if resultCode != 0 {
            throw NATPortMapperError.requestDenied("NAT-PMP error code: \(resultCode)")
        }

        // Extract IP address (bytes 8-11)
        let ip = "\(buffer[8]).\(buffer[9]).\(buffer[10]).\(buffer[11])"
        return ip
    }

    private func requestMappingNATPMP(
        gatewayIP: String,
        internalPort: UInt16,
        externalPort: UInt16,
        protocol: NATTransportProtocol,
        duration: Duration
    ) async throws -> PortMapping {
        let socket = try createUDPSocket()
        defer { close(socket) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = configuration.natpmpPort.bigEndian
        inet_pton(AF_INET, gatewayIP, &addr.sin_addr)

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

        let sent = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                sendto(socket, &request, request.count, 0, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        if sent < 0 {
            throw NATPortMapperError.networkError("Failed to send NAT-PMP mapping request")
        }

        // Wait for response
        var readfds = fd_set()
        __darwin_fd_zero(&readfds)
        __darwin_fd_set(socket, &readfds)

        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        let selectResult = select(socket + 1, &readfds, nil, nil, &timeout)

        if selectResult <= 0 {
            throw NATPortMapperError.discoveryTimeout
        }

        // Read response
        var buffer = [UInt8](repeating: 0, count: 16)
        let received = recv(socket, &buffer, buffer.count, 0)
        if received < 16 {
            throw NATPortMapperError.invalidResponse
        }

        // Parse response
        let resultCode = UInt16(buffer[2]) << 8 | UInt16(buffer[3])
        if resultCode != 0 {
            throw NATPortMapperError.requestDenied("NAT-PMP error code: \(resultCode)")
        }

        let assignedPort = UInt16(buffer[10]) << 8 | UInt16(buffer[11])
        let assignedLifetime = UInt32(buffer[12]) << 24 | UInt32(buffer[13]) << 16 | UInt32(buffer[14]) << 8 | UInt32(buffer[15])

        let externalAddress = try await discoverExternalAddress()

        return PortMapping(
            internalPort: internalPort,
            externalPort: assignedPort,
            externalAddress: externalAddress,
            protocol: `protocol`,
            expiration: ContinuousClock.now + .seconds(Int64(assignedLifetime)),
            gatewayType: .natpmp(gatewayIP: gatewayIP)
        )
    }

    private func releaseMappingNATPMP(
        gatewayIP: String,
        internalPort: UInt16,
        protocol: NATTransportProtocol
    ) async throws {
        // Release by setting lifetime to 0
        _ = try await requestMappingNATPMP(
            gatewayIP: gatewayIP,
            internalPort: internalPort,
            externalPort: 0,
            protocol: `protocol`,
            duration: .zero
        )
    }

    // MARK: - Helpers

    private func createUDPSocket() throws -> Int32 {
        let socket = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        if socket < 0 {
            throw NATPortMapperError.networkError("Failed to create UDP socket")
        }

        // Set non-blocking
        let flags = fcntl(socket, F_GETFL, 0)
        _ = fcntl(socket, F_SETFL, flags | O_NONBLOCK)

        return socket
    }

    private func getDefaultGateway() throws -> String {
        // Use route command to get default gateway
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
        task.arguments = ["-rn"]

        let pipe = Pipe()
        task.standardOutput = pipe

        try task.run()
        task.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        // Parse default gateway from netstat output
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            if parts.count >= 2 && parts[0] == "default" {
                return String(parts[1])
            }
        }

        throw NATPortMapperError.noGatewayFound
    }

    private func getLocalIPAddress() throws -> String {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else {
            throw NATPortMapperError.networkError("Failed to get network interfaces")
        }
        defer { freeifaddrs(ifaddr) }

        var current = ifaddr
        while let addr = current {
            let interface = addr.pointee
            if interface.ifa_addr.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name!)
                if name.hasPrefix("en") || name.hasPrefix("eth") {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(
                        interface.ifa_addr,
                        socklen_t(interface.ifa_addr.pointee.sa_len),
                        &hostname,
                        socklen_t(hostname.count),
                        nil,
                        0,
                        NI_NUMERICHOST
                    )
                    // Find null terminator and create string
                    if let nullIndex = hostname.firstIndex(of: 0) {
                        return String(decoding: hostname[..<nullIndex].map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    }
                    return String(decoding: hostname.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                }
            }
            current = interface.ifa_next
        }

        throw NATPortMapperError.networkError("No local IP address found")
    }
}

// Helper for fd_set operations
private func __darwin_fd_zero(_ fdset: UnsafeMutablePointer<fd_set>) {
    memset(fdset, 0, MemoryLayout<fd_set>.size)
}

private func __darwin_fd_set(_ fd: Int32, _ fdset: UnsafeMutablePointer<fd_set>) {
    let intOffset = Int(fd) / 32
    let bitOffset = Int(fd) % 32
    withUnsafeMutablePointer(to: &fdset.pointee.fds_bits) { ptr in
        ptr.withMemoryRebound(to: Int32.self, capacity: 32) { bits in
            bits[intOffset] |= Int32(1 << bitOffset)
        }
    }
}
