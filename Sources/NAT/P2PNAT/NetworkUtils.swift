/// NetworkUtils - Network and XML utility functions for NAT
import Foundation

/// Gets the default gateway IP address using netstat.
///
/// Offloads the blocking `Process` call to avoid blocking
/// the cooperative thread pool.
func getDefaultGateway() async throws -> String {
    try await Task.detached {
        try _getDefaultGatewaySync()
    }.value
}

private func _getDefaultGatewaySync() throws -> String {
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
        if interface.ifa_addr.pointee.sa_family == UInt8(AF_INET) {
            guard let ifaName = interface.ifa_name else {
                current = interface.ifa_next
                continue
            }
            let name = String(cString: ifaName)
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
