/// MemoryListener - In-memory Listener implementation
///
/// Accepts connections from the memory hub.

import Foundation
import Synchronization
import P2PCore
import P2PTransport

/// Errors that can occur with memory listeners.
public enum MemoryListenerError: Error, Sendable {
    /// Multiple concurrent accepts are not supported.
    case concurrentAcceptNotSupported
}

/// An in-memory listener that implements Listener.
///
/// Accepts connections that are routed through a MemoryHub.
///
/// - Important: This listener assumes a single acceptor pattern. Concurrent calls
///   to `accept()` from multiple tasks will throw `MemoryListenerError.concurrentAcceptNotSupported`.
public final class MemoryListener: Listener, Sendable {

    /// The local address this listener is bound to.
    public let localAddress: Multiaddr

    /// The hub this listener is registered with.
    private let hub: MemoryHub

    /// Listener state.
    private let state: Mutex<ListenerState>

    private struct ListenerState: Sendable {
        var pendingConnections: [MemoryConnection] = []
        var waitingContinuation: CheckedContinuation<any RawConnection, any Error>?
        var isClosed = false
    }

    /// Creates a new memory listener.
    ///
    /// - Parameters:
    ///   - address: The address to listen on
    ///   - hub: The memory hub to register with
    internal init(address: Multiaddr, hub: MemoryHub) {
        self.localAddress = address
        self.hub = hub
        self.state = Mutex(ListenerState())
    }

    /// Accepts the next incoming connection.
    ///
    /// Blocks until a connection is available or the listener is closed.
    ///
    /// - Returns: The accepted connection
    /// - Throws: `TransportError.listenerClosed` if the listener is closed,
    ///           `MemoryListenerError.concurrentAcceptNotSupported` if another accept is already waiting
    public func accept() async throws -> any RawConnection {
        try await withCheckedThrowingContinuation { continuation in
            state.withLock { state in
                if state.isClosed {
                    continuation.resume(throwing: TransportError.listenerClosed)
                    return
                }

                if state.waitingContinuation != nil {
                    continuation.resume(throwing: MemoryListenerError.concurrentAcceptNotSupported)
                    return
                }

                if !state.pendingConnections.isEmpty {
                    let connection = state.pendingConnections.removeFirst()
                    continuation.resume(returning: connection)
                } else {
                    state.waitingContinuation = continuation
                }
            }
        }
    }

    /// Closes the listener.
    ///
    /// Any pending accept() calls will throw `TransportError.listenerClosed`.
    /// Pending connections that were not yet accepted will be closed.
    public func close() async throws {
        let (continuation, pendingConns): (CheckedContinuation<any RawConnection, any Error>?, [MemoryConnection]) = state.withLock { state in
            state.isClosed = true
            let cont = state.waitingContinuation
            state.waitingContinuation = nil
            let pending = state.pendingConnections
            state.pendingConnections = []
            return (cont, pending)
        }

        // Resume any waiting accept with error
        continuation?.resume(throwing: TransportError.listenerClosed)

        // Close pending connections so dialers don't hang
        for conn in pendingConns {
            try? await conn.close()
        }

        // Unregister from hub
        hub.unregister(address: localAddress)
    }

    /// Enqueues a new connection.
    ///
    /// Called by MemoryHub when a dial request is made to this listener's address.
    ///
    /// - Parameter connection: The connection to enqueue
    internal func enqueue(_ connection: MemoryConnection) {
        let shouldClose = state.withLock { state -> Bool in
            if state.isClosed {
                // Listener is closed, connection should be closed
                return true
            }

            if let continuation = state.waitingContinuation {
                state.waitingContinuation = nil
                continuation.resume(returning: connection)
            } else {
                state.pendingConnections.append(connection)
            }
            return false
        }

        // Close connection outside of lock if listener was closed
        if shouldClose {
            Task {
                try? await connection.close()
            }
        }
    }

    /// Returns true if the listener is closed.
    public var isClosed: Bool {
        state.withLock { $0.isClosed }
    }

    /// Returns the number of pending connections waiting to be accepted.
    public var pendingCount: Int {
        state.withLock { $0.pendingConnections.count }
    }
}
