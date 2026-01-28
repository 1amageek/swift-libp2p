/// UDPSocket - RAII UDP socket helper for NAT protocol operations
import Foundation

/// UDP socket with automatic cleanup via `~Copyable`.
///
/// Encapsulates the common pattern of creating a UDP socket,
/// sending data to an address, and receiving a response with timeout.
struct UDPSocket: ~Copyable {
    private let fd: Int32

    /// Creates a new non-blocking UDP socket.
    init() throws {
        let socket = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        if socket < 0 {
            throw NATPortMapperError.networkError("Failed to create UDP socket")
        }

        // Set non-blocking
        let flags = fcntl(socket, F_GETFL, 0)
        guard flags >= 0 else {
            close(socket)
            throw NATPortMapperError.networkError("Failed to get socket flags")
        }
        guard fcntl(socket, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            close(socket)
            throw NATPortMapperError.networkError("Failed to set non-blocking mode")
        }

        self.fd = socket
    }

    deinit {
        close(fd)
    }

    /// Sends data to the specified address and waits for a response.
    ///
    /// - Parameters:
    ///   - address: The IPv4 address to send to.
    ///   - port: The UDP port to send to.
    ///   - data: The request data to send.
    ///   - responseSize: Expected response buffer size.
    ///   - timeout: Maximum time to wait for a response.
    /// - Returns: The received response bytes.
    func sendAndReceive(
        to address: String,
        port: UInt16,
        data: [UInt8],
        responseSize: Int,
        timeout: Duration
    ) throws -> [UInt8] {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian

        guard inet_pton(AF_INET, address, &addr.sin_addr) == 1 else {
            throw NATPortMapperError.networkError("Invalid IPv4 address: \(address)")
        }

        // Send
        var mutableData = data
        let sent = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                sendto(fd, &mutableData, mutableData.count, 0, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        if sent < 0 {
            throw NATPortMapperError.networkError("Failed to send UDP request")
        }

        // Wait for response with select()
        var readfds = fd_set()
        natFdZero(&readfds)
        natFdSet(fd, &readfds)

        let seconds = timeout.components.seconds
        let microseconds = timeout.components.attoseconds / 1_000_000_000_000
        var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32(microseconds))
        let selectResult = select(fd + 1, &readfds, nil, nil, &tv)

        if selectResult <= 0 {
            throw NATPortMapperError.discoveryTimeout
        }

        // Read response
        var buffer = [UInt8](repeating: 0, count: responseSize)
        let received = recv(fd, &buffer, buffer.count, 0)
        if received <= 0 {
            throw NATPortMapperError.invalidResponse
        }

        return Array(buffer.prefix(received))
    }
}

// MARK: - fd_set helpers

func natFdZero(_ fdset: UnsafeMutablePointer<fd_set>) {
    memset(fdset, 0, MemoryLayout<fd_set>.size)
}

func natFdSet(_ fd: Int32, _ fdset: UnsafeMutablePointer<fd_set>) {
    // Use byte-level access to avoid undefined behavior from
    // reinterpreting tuples as contiguous arrays.
    let byteOffset = Int(fd) / 8
    let bitOffset = Int(fd) % 8
    withUnsafeMutableBytes(of: &fdset.pointee.fds_bits) { rawBuffer in
        rawBuffer[byteOffset] |= UInt8(1 << bitOffset)
    }
}
