import Foundation
import QUIC

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Resolver for WebTransport dial addresses, including DNS multiaddr variants.
enum WebTransportDialAddressResolver {
    static func resolve(_ components: WebTransportAddressComponents) throws -> QUIC.SocketAddress {
        switch components.host {
        case .ip4(let host), .ip6(let host):
            return QUIC.SocketAddress(ipAddress: host, port: components.port)

        case .dns(let host):
            return try resolveDNS(host: host, port: components.port, family: AF_UNSPEC)

        case .dns4(let host):
            return try resolveDNS(host: host, port: components.port, family: AF_INET)

        case .dns6(let host):
            return try resolveDNS(host: host, port: components.port, family: AF_INET6)
        }
    }

    private static func resolveDNS(
        host: String,
        port: UInt16,
        family: Int32
    ) throws -> QUIC.SocketAddress {
        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG,
            ai_family: family,
            ai_socktype: datagramSocketType(),
            ai_protocol: udpProtocol(),
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )

        var rawResults: UnsafeMutablePointer<addrinfo>?
        let status = String(port).withCString { service in
            host.withCString { hostCString in
                getaddrinfo(hostCString, service, &hints, &rawResults)
            }
        }

        guard status == 0, let results = rawResults else {
            throw WebTransportError.connectionFailed("Failed to resolve \(host):\(port) (\(errorMessage(for: status)))")
        }
        defer { freeaddrinfo(results) }

        var cursor: UnsafeMutablePointer<addrinfo>? = results
        while let current = cursor {
            let info = current.pointee
            if let resolved = numericSocketAddress(
                sockaddrPointer: info.ai_addr,
                sockaddrLength: info.ai_addrlen
            ) {
                return resolved
            }
            cursor = info.ai_next
        }

        throw WebTransportError.connectionFailed("Failed to resolve \(host):\(port) to a numeric IP")
    }

    private static func numericSocketAddress(
        sockaddrPointer: UnsafeMutablePointer<sockaddr>?,
        sockaddrLength: socklen_t
    ) -> QUIC.SocketAddress? {
        guard let sockaddrPointer else { return nil }

        var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        var serviceBuffer = [CChar](repeating: 0, count: Int(NI_MAXSERV))
        let flags = NI_NUMERICHOST | NI_NUMERICSERV

        let status = getnameinfo(
            sockaddrPointer,
            sockaddrLength,
            &hostBuffer,
            socklen_t(hostBuffer.count),
            &serviceBuffer,
            socklen_t(serviceBuffer.count),
            flags
        )

        let host = hostBuffer.withUnsafeBufferPointer { pointer -> String? in
            guard let baseAddress = pointer.baseAddress else { return nil }
            return String(validatingCString: baseAddress)
        }
        let service = serviceBuffer.withUnsafeBufferPointer { pointer -> String? in
            guard let baseAddress = pointer.baseAddress else { return nil }
            return String(validatingCString: baseAddress)
        }

        guard status == 0,
              let host,
              let service,
              let port = UInt16(service) else {
            return nil
        }

        return QUIC.SocketAddress(ipAddress: host, port: port)
    }

    private static func errorMessage(for status: Int32) -> String {
        guard let message = gai_strerror(status) else {
            return "unknown resolver error"
        }
        return String(cString: message)
    }

    private static func datagramSocketType() -> Int32 {
#if canImport(Glibc)
        return Int32(SOCK_DGRAM.rawValue)
#else
        return SOCK_DGRAM
#endif
    }

    private static func udpProtocol() -> Int32 {
#if canImport(Glibc)
        return Int32(IPPROTO_UDP)
#else
        return IPPROTO_UDP
#endif
    }
}
