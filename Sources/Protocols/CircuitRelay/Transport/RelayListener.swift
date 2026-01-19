/// RelayListener - Listener for incoming relayed connections.

import Foundation
import Synchronization
import P2PCore
import P2PTransport

/// Listener for incoming relayed connections.
///
/// This listener wraps a reservation on a relay and accepts incoming
/// relayed connections from other peers.
public final class RelayListener: Listener, Sendable {

    // MARK: - Constants

    /// Maximum number of queued connections before dropping oldest.
    private static let maxQueuedConnections = 64

    // MARK: - Listener

    public let localAddress: Multiaddr

    // MARK: - Properties

    /// The relay peer ID.
    public let relay: PeerID

    /// The relay client.
    private let client: RelayClient

    /// The current reservation.
    public let reservation: Reservation

    /// Listener state.
    private let state: Mutex<ListenerState>

    /// Background processing task.
    private let processingTask: Mutex<Task<Void?, Never>?>

    private struct ListenerState: Sendable {
        var incomingConnections: [RelayedConnection] = []
        var waitingContinuation: CheckedContinuation<any RawConnection, any Error>?
        var isClosed: Bool = false
    }

    // MARK: - Initialization

    /// Creates a new relay listener.
    ///
    /// - Parameters:
    ///   - relay: The relay peer ID.
    ///   - client: The relay client.
    ///   - localAddress: The local (relay) address.
    ///   - reservation: The reservation on the relay.
    init(
        relay: PeerID,
        client: RelayClient,
        localAddress: Multiaddr,
        reservation: Reservation
    ) {
        self.relay = relay
        self.client = client
        self.localAddress = localAddress
        self.reservation = reservation
        self.state = Mutex(ListenerState())
        self.processingTask = Mutex(nil)

        // Register with the client for direct connection routing
        client.registerListener(self, for: relay)

        // Start background task for reservation expiration monitoring
        let task = Task { [weak self] in
            await self?.monitorReservationExpiration()
        }
        self.processingTask.withLock { $0 = task }
    }

    // MARK: - Listener Protocol

    public func accept() async throws -> any RawConnection {
        // Check for queued connections first
        let queued: RelayedConnection? = state.withLock { s in
            if s.isClosed { return nil }
            return s.incomingConnections.isEmpty ? nil : s.incomingConnections.removeFirst()
        }

        if let conn = queued {
            return RelayedRawConnection(relayedConnection: conn)
        }

        // Wait for next connection with cancellation support
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let shouldResume = state.withLock { s -> (Bool, RelayedConnection?) in
                    if s.isClosed {
                        return (true, nil) // Will throw
                    } else if !s.incomingConnections.isEmpty {
                        return (true, s.incomingConnections.removeFirst())
                    } else {
                        s.waitingContinuation = continuation
                        return (false, nil)
                    }
                }

                if shouldResume.0 {
                    if let conn = shouldResume.1 {
                        continuation.resume(returning: RelayedRawConnection(relayedConnection: conn))
                    } else {
                        continuation.resume(throwing: TransportError.listenerClosed)
                    }
                }
            }
        } onCancel: { [weak self] in
            guard let self = self else { return }
            // Immediately clean up the continuation on cancellation
            let continuation = self.state.withLock { s -> CheckedContinuation<any RawConnection, any Error>? in
                let cont = s.waitingContinuation
                s.waitingContinuation = nil
                return cont
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    public func close() async throws {
        // Unregister from the client
        client.unregisterListener(for: relay)

        // Cancel the processing task
        let task = processingTask.withLock { t -> Task<Void?, Never>? in
            let existing = t
            t = nil
            return existing
        }
        task?.cancel()

        // Then update state and resume any waiting continuation
        state.withLock { s in
            s.isClosed = true
            s.waitingContinuation?.resume(throwing: TransportError.listenerClosed)
            s.waitingContinuation = nil
        }
    }

    // MARK: - Connection Queueing

    /// Enqueues an incoming connection.
    ///
    /// Called when the RelayClient receives an incoming connection via Stop protocol.
    /// If the queue is at capacity, the oldest connection is dropped.
    func enqueue(_ connection: RelayedConnection) {
        let dropped: RelayedConnection? = state.withLock { s in
            guard !s.isClosed else { return nil }

            if let continuation = s.waitingContinuation {
                s.waitingContinuation = nil
                continuation.resume(returning: RelayedRawConnection(relayedConnection: connection))
                return nil
            } else {
                // Enforce queue size limit - drop oldest if at capacity
                var droppedConnection: RelayedConnection? = nil
                if s.incomingConnections.count >= Self.maxQueuedConnections {
                    droppedConnection = s.incomingConnections.removeFirst()
                }
                s.incomingConnections.append(connection)
                return droppedConnection
            }
        }

        // Close dropped connection asynchronously (outside lock)
        if let dropped = dropped {
            Task { try? await dropped.close() }
        }
    }

    // MARK: - Private

    /// Monitors reservation expiration and closes the listener when expired.
    ///
    /// With the Listener Registry pattern, connections are routed directly
    /// via `enqueue()` from the RelayClient, so we only need to monitor
    /// expiration rather than actively polling for connections.
    private func monitorReservationExpiration() async {
        // Wait until reservation expires
        let expirationTime = reservation.expiration
        let now = ContinuousClock.now

        if expirationTime > now {
            try? await Task.sleep(until: expirationTime, clock: .continuous)
        }

        // Check if we're already closed or cancelled
        if Task.isCancelled { return }
        let isClosed = state.withLock { $0.isClosed }
        if isClosed { return }

        // Close the listener on expiration
        try? await close()
    }
}
