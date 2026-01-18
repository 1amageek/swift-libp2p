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

        // Start listening for incoming connections from the client
        Task { [weak self] in
            await self?.processIncomingConnections()
        }
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

        // Wait for next connection
        return try await withCheckedThrowingContinuation { continuation in
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
    }

    public func close() async throws {
        _ = state.withLock { s in
            s.isClosed = true
            s.waitingContinuation?.resume(throwing: TransportError.listenerClosed)
            s.waitingContinuation = nil
        }
    }

    // MARK: - Connection Queueing

    /// Enqueues an incoming connection.
    ///
    /// Called when the RelayClient receives an incoming connection via Stop protocol.
    func enqueue(_ connection: RelayedConnection) {
        _ = state.withLock { s in
            guard !s.isClosed else { return }

            if let continuation = s.waitingContinuation {
                s.waitingContinuation = nil
                continuation.resume(returning: RelayedRawConnection(relayedConnection: connection))
            } else {
                s.incomingConnections.append(connection)
            }
        }
    }

    // MARK: - Private

    /// Processes incoming connections from the relay client.
    private func processIncomingConnections() async {
        // Use two tasks: one to watch for events, one to accept connections
        await withTaskGroup(of: Void.self) { group in
            // Task 1: Watch for reservation expiration
            group.addTask { [weak self] in
                guard let self = self else { return }
                for await event in self.client.events {
                    let isClosed = self.state.withLock { $0.isClosed }
                    if isClosed { break }

                    switch event {
                    case .reservationExpired(let eventRelay) where eventRelay == self.relay:
                        // Our reservation expired - close the listener
                        try? await self.close()
                        return

                    default:
                        break
                    }
                }
            }

            // Task 2: Accept incoming connections
            group.addTask { [weak self] in
                guard let self = self else { return }
                while true {
                    let isClosed = self.state.withLock { $0.isClosed }
                    if isClosed { break }

                    do {
                        // Wait for an incoming connection from the relay
                        let connection = try await self.client.acceptConnection(relay: self.relay)
                        self.enqueue(connection)
                    } catch {
                        // Connection accept failed - check if we should stop
                        let isClosed = self.state.withLock { $0.isClosed }
                        if isClosed { break }
                        // Otherwise continue trying
                    }
                }
            }
        }
    }
}
