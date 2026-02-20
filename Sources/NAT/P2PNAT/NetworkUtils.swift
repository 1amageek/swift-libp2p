/// NetworkUtils - Network and XML utility functions for NAT
import Foundation
import Synchronization

#if canImport(Network)
import Network
#endif

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Gets the default gateway IP address.
///
/// - Apple platforms: Uses `NWPath.gateways` from the Network framework.
/// - Linux: Parses `/proc/net/route` for the default route.
func getDefaultGateway() async throws -> String {
    #if canImport(Network)
    return try await withCheckedThrowingContinuation { continuation in
        let monitor = NWPathMonitor()
        let resumed = Mutex(false)
        monitor.pathUpdateHandler = { path in
            let alreadyResumed = resumed.withLock { state -> Bool in
                if state { return true }
                state = true
                return false
            }
            guard !alreadyResumed else { return }
            monitor.cancel()
            for gateway in path.gateways {
                if case .hostPort(host: .ipv4(let addr), port: _) = gateway {
                    continuation.resume(returning: "\(addr)")
                    return
                }
            }
            continuation.resume(throwing: NATPortMapperError.noGatewayFound)
        }
        monitor.start(queue: DispatchQueue(label: "p2p.nat.gateway"))
    }
    #elseif os(Linux)
    return try await Task.detached {
        try readGatewayFromProcRoute()
    }.value
    #else
    throw NATPortMapperError.noGatewayFound
    #endif
}

#if os(Linux)
/// Reads the default gateway from `/proc/net/route`.
///
/// The file contains tab-separated fields. The default route has
/// Destination `00000000`. The Gateway field is a hex-encoded IPv4 address
/// in host byte order (little-endian on x86/arm).
private func readGatewayFromProcRoute() throws -> String {
    let contents: String
    do {
        contents = try String(contentsOfFile: "/proc/net/route", encoding: .utf8)
    } catch {
        throw NATPortMapperError.noGatewayFound
    }

    // Skip the header line and find the default route.
    for line in contents.components(separatedBy: "\n").dropFirst() {
        let fields = line.split(separator: "\t")
        guard fields.count >= 3, fields[1] == "00000000" else { continue }
        guard let gwHex = UInt32(fields[2], radix: 16) else { continue }
        // Host byte order (little-endian) → dotted-decimal
        let b0 = gwHex & 0xFF
        let b1 = (gwHex >> 8) & 0xFF
        let b2 = (gwHex >> 16) & 0xFF
        let b3 = (gwHex >> 24) & 0xFF
        return "\(b0).\(b1).\(b2).\(b3)"
    }
    throw NATPortMapperError.noGatewayFound
}
#endif

/// Gets the local IPv4 address from a network interface (en* or eth*).
func getLocalIPAddress() throws -> String {
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0 else {
        throw NATPortMapperError.networkError("Failed to get network interfaces")
    }
    defer { freeifaddrs(ifaddr) }

    var current = ifaddr
    while let addr = current {
        let interface = addr.pointee
        if interface.ifa_addr.pointee.sa_family == sa_family_t(AF_INET) {
            guard let ifaName = interface.ifa_name else {
                current = interface.ifa_next
                continue
            }
            let name = String(cString: ifaName)
            if name.hasPrefix("en") || name.hasPrefix("eth") {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                #if canImport(Darwin)
                let addrLen = socklen_t(interface.ifa_addr.pointee.sa_len)
                #else
                let addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                #endif
                getnameinfo(
                    interface.ifa_addr,
                    addrLen,
                    &hostname,
                    socklen_t(hostname.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
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

/// Extracts a `<service>...</service>` block containing the specified text.
///
/// Used to scope XML tag extraction to the correct UPnP service block,
/// preventing false matches from other services in the device description.
///
/// - Parameters:
///   - text: The text that must appear within the service block (e.g., a serviceType URN).
///   - xml: The full XML string to search in.
/// - Returns: The service block substring, or nil if not found.
func extractServiceBlock(containing text: String, from xml: String) -> String? {
    // Find all <service>...</service> blocks and return the one containing the text
    var searchStart = xml.startIndex
    while searchStart < xml.endIndex {
        guard let openRange = xml.range(of: "<service>", options: .caseInsensitive, range: searchStart..<xml.endIndex),
              let closeRange = xml.range(of: "</service>", options: .caseInsensitive, range: openRange.upperBound..<xml.endIndex) else {
            break
        }

        let block = String(xml[openRange.lowerBound..<closeRange.upperBound])
        if block.contains(text) {
            return block
        }

        searchStart = closeRange.upperBound
    }
    return nil
}

/// Extracts the text content of an XML tag.
///
/// Simple regex-based extraction for `<tag>value</tag>` patterns.
///
/// - Parameters:
///   - tag: The XML tag name to search for.
///   - xml: The XML string to search in.
/// - Returns: The text content, or nil if not found.
func extractXMLTagValue(named tag: String, from xml: String) -> String? {
    let pattern = "<\(tag)>([^<]+)</\(tag)>"
    guard let range = xml.range(of: pattern, options: .regularExpression) else {
        return nil
    }

    let match = String(xml[range])
    let openTag = "<\(tag)>"
    let closeTag = "</\(tag)>"
    let start = match.index(match.startIndex, offsetBy: openTag.count)
    let end = match.index(match.endIndex, offsetBy: -closeTag.count)

    guard start < end else { return nil }
    return String(match[start..<end])
}
