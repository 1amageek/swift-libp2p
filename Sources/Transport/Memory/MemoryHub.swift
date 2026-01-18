/// MemoryHub - Central connection router for memory transport
///
/// Routes connection requests between memory transport instances.

import Foundation
import Synchronization
import P2PCore
import P2PTransport

/// Errors that can occur with the memory hub.
public enum MemoryHubError: Error, Sendable {
    /// The address is not a valid memory address.
    case invalidAddress(Multiaddr)

    /// No listener is registered at the given address.
    case noListener(Multiaddr)

    /// A listener is already registered at the given address.
    case addressInUse(Multiaddr)

    /// The listener was closed.
    case listenerClosed
}

/// Central router for in-memory transport connections.
///
/// The MemoryHub tracks registered listeners and routes dial requests
/// to the appropriate listener. It can be used as a shared singleton
/// or as isolated instances for separate test scenarios.
///
/// ## Usage
///
/// ```swift
/// // Use shared hub for simple tests
/// let transport1 = MemoryTransport()
/// let transport2 = MemoryTransport()
///
/// // Or use isolated hub for test isolation
/// let hub = MemoryHub()
/// let transport1 = MemoryTransport(hub: hub)
/// let transport2 = MemoryTransport(hub: hub)
/// ```
public final class MemoryHub: Sendable {

    /// Shared instance for simple test scenarios.
    public static let shared = MemoryHub()

    /// Registered listeners by their memory address identifier.
    private let listeners: Mutex<[String: WeakListener]>

    /// Wrapper to hold weak reference to listener.
    private struct WeakListener: Sendable {
        weak var listener: MemoryListener?
    }

    /// Creates a new memory hub.
    public init() {
        self.listeners = Mutex([:])
    }

    /// Registers a listener at the given address.
    ///
    /// - Parameters:
    ///   - listener: The listener to register
    ///   - address: The address to register at
    /// - Throws: `MemoryHubError.invalidAddress` if not a memory address,
    ///           `MemoryHubError.addressInUse` if the address is already in use
    public func register(listener: MemoryListener, at address: Multiaddr) throws {
        guard let id = address.memoryID else {
            throw MemoryHubError.invalidAddress(address)
        }

        try listeners.withLock { listeners in
            // Clean up any dead references
            if let existing = listeners[id], existing.listener != nil {
                throw MemoryHubError.addressInUse(address)
            }
            listeners[id] = WeakListener(listener: listener)
        }
    }

    /// Unregisters the listener at the given address.
    ///
    /// - Parameter address: The address to unregister
    public func unregister(address: Multiaddr) {
        guard let id = address.memoryID else { return }

        listeners.withLock { listeners in
            _ = listeners.removeValue(forKey: id)
        }
    }

    /// Connects to a listener at the given address.
    ///
    /// Creates a pair of connected MemoryConnections and enqueues the
    /// remote end with the listener.
    ///
    /// - Parameter address: The address to connect to
    /// - Returns: The local end of the connection
    /// - Throws: `MemoryHubError.invalidAddress` if not a memory address,
    ///           `MemoryHubError.noListener` if no listener is registered
    public func connect(to address: Multiaddr) throws -> MemoryConnection {
        guard let id = address.memoryID else {
            throw MemoryHubError.invalidAddress(address)
        }

        let listener: MemoryListener? = listeners.withLock { listeners in
            listeners[id]?.listener
        }

        guard let listener = listener else {
            throw MemoryHubError.noListener(address)
        }

        // Create the connection pair
        // The dialer gets a synthetic local address
        let dialerAddress = Multiaddr.memory(id: "dialer-\(UUID().uuidString)")
        let (local, remote) = MemoryConnection.makePair(
            localAddress: dialerAddress,
            remoteAddress: address
        )

        // Enqueue the remote end to the listener
        listener.enqueue(remote)

        return local
    }

    /// Resets the hub by clearing all listeners.
    ///
    /// Useful for cleaning up between tests.
    public func reset() {
        listeners.withLock { listeners in
            listeners.removeAll()
        }
    }

    /// Returns the number of registered listeners.
    public var listenerCount: Int {
        listeners.withLock { listeners in
            // Count only non-nil weak references
            listeners.values.filter { $0.listener != nil }.count
        }
    }
}
