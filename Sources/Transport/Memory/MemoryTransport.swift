/// MemoryTransport - In-memory Transport implementation
///
/// A transport for testing that operates entirely in memory.

import Foundation
import P2PCore
import P2PTransport

/// An in-memory transport for testing.
///
/// This transport operates entirely in memory, making it ideal for
/// unit tests that don't need actual network I/O. It provides
/// deterministic behavior and can be used to test connection
/// handling, protocol negotiation, and other features without
/// network dependencies.
///
/// ## Usage
///
/// ```swift
/// // Create transports using shared hub
/// let transport1 = MemoryTransport()
/// let transport2 = MemoryTransport()
///
/// // Listen on an address
/// let listener = try await transport1.listen(.memory(id: "server"))
///
/// // Dial from another transport
/// let connection = try await transport2.dial(.memory(id: "server"))
///
/// // Accept the connection
/// let serverConn = try await listener.accept()
///
/// // Now they can communicate
/// try await connection.write(Data("hello".utf8))
/// let data = try await serverConn.read()
/// ```
///
/// ## Isolated Testing
///
/// For test isolation, create a separate hub:
///
/// ```swift
/// let hub = MemoryHub()
/// let transport1 = MemoryTransport(hub: hub)
/// let transport2 = MemoryTransport(hub: hub)
///
/// // Clean up after test
/// hub.reset()
/// ```
public final class MemoryTransport: Transport, Sendable {

    /// The hub this transport uses for routing.
    public let hub: MemoryHub

    /// The protocols this transport supports.
    public var protocols: [[String]] {
        [["memory"]]
    }

    /// Creates a memory transport using the shared hub.
    public init() {
        self.hub = .shared
    }

    /// Creates a memory transport using a custom hub.
    ///
    /// - Parameter hub: The memory hub to use for routing
    public init(hub: MemoryHub) {
        self.hub = hub
    }

    /// Dials a remote address.
    ///
    /// - Parameter address: The memory address to dial (e.g., `/memory/server`)
    /// - Returns: A raw connection to the remote endpoint
    /// - Throws: `TransportError.connectionFailed` if no listener is registered at the address
    public func dial(_ address: Multiaddr) async throws -> any RawConnection {
        try hub.connect(to: address)
    }

    /// Listens on the given address.
    ///
    /// - Parameter address: The memory address to listen on (e.g., `/memory/server`)
    /// - Returns: A listener for incoming connections
    /// - Throws: `TransportError.addressInUse` if the address is already in use
    public func listen(_ address: Multiaddr) async throws -> any Listener {
        let listener = MemoryListener(address: address, hub: hub)
        try hub.register(listener: listener, at: address)
        return listener
    }

    /// Checks if this transport can dial the given address.
    ///
    /// - Parameter address: The address to check
    /// - Returns: `true` if the address contains a memory protocol
    public func canDial(_ address: Multiaddr) -> Bool {
        address.protocols.contains { proto in
            if case .memory = proto { return true }
            return false
        }
    }

    /// Checks if this transport can listen on the given address.
    ///
    /// - Parameter address: The address to check
    /// - Returns: `true` if the address contains a memory protocol
    public func canListen(_ address: Multiaddr) -> Bool {
        address.protocols.contains { proto in
            if case .memory = proto { return true }
            return false
        }
    }
}
