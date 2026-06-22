/// UDPSocketSourceTests - Verifies UDP source verification (anti-spoofing).
import Testing
import Foundation
@testable import P2PNAT

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@Suite("UDP Source Verification Tests", .serialized)
struct UDPSocketSourceTests {

    /// A minimal blocking UDP echo/responder bound to a loopback port.
    /// Returns the bound port and the server fd (caller must close).
    private func makeResponder(reply: [UInt8]) throws -> (port: UInt16, fd: Int32) {
        #if canImport(Glibc)
        let dgram = Int32(SOCK_DGRAM.rawValue)
        #else
        let dgram = SOCK_DGRAM
        #endif
        let fd = socket(AF_INET, dgram, 0)
        try #require(fd >= 0)

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0 // ephemeral
        #if canImport(Darwin)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        _ = inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)

        let bindResult = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        try #require(bindResult == 0)

        // Read back the assigned port.
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        let port = UInt16(bigEndian: bound.sin_port)

        // Background thread: receive one request, send the reply back to sender.
        let replyData = reply
        let serverFD = fd
        Thread.detachNewThread {
            var buf = [UInt8](repeating: 0, count: 64)
            var src = sockaddr_in()
            var srcLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &src) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(serverFD, &buf, buf.count, 0, $0, &srcLen)
                }
            }
            if n >= 0 {
                var out = replyData
                _ = withUnsafePointer(to: &src) { p in
                    p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(serverFD, &out, out.count, 0, $0, srcLen)
                    }
                }
            }
        }
        return (port, fd)
    }

    @Test("response from the connected gateway is accepted", .timeLimit(.minutes(1)))
    func acceptsConnectedSource() throws {
        let reply: [UInt8] = [0, 128, 0, 0, 0, 0, 0, 0, 192, 0, 2, 1]
        let (port, serverFD) = try makeResponder(reply: reply)
        defer { close(serverFD) }

        let socket = try UDPSocket()
        let response = try socket.sendAndReceive(
            to: "127.0.0.1",
            port: port,
            data: [0, 0],
            responseSize: 32,
            timeout: .seconds(2)
        )
        #expect(response == reply)
    }

    @Test("response from an unconnected port is not delivered (timeout)", .timeLimit(.minutes(1)))
    func rejectsUnexpectedSource() throws {
        // Start a responder, but connect our socket to a DIFFERENT port where no
        // one replies. The kernel-level connect() filter means a datagram from
        // the responder's port (the "spoofed" source relative to the connected
        // peer) is never delivered, so the receive times out.
        let reply: [UInt8] = [0, 128, 0, 0, 0, 0, 0, 0, 192, 0, 2, 1]
        let (responderPort, serverFD) = try makeResponder(reply: reply)
        defer { close(serverFD) }

        // Pick a port almost certainly different from the responder.
        let wrongPort: UInt16 = responderPort == 1 ? 2 : responderPort - 1

        let socket = try UDPSocket()
        #expect(throws: NATPortMapperError.self) {
            _ = try socket.sendAndReceive(
                to: "127.0.0.1",
                port: wrongPort,
                data: [0, 0],
                responseSize: 32,
                timeout: .milliseconds(300)
            )
        }
    }
}
