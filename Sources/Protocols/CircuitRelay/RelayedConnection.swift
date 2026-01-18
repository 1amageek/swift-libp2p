/// A connection relayed through a Circuit Relay.

import Foundation
import Synchronization
import P2PCore
import P2PMux

/// A connection relayed through a Circuit Relay.
///
/// This wraps a multiplexed stream and provides a RawConnection-like interface
/// with limit enforcement (data and duration limits).
public final class RelayedConnection: Sendable {

    // MARK: - Properties

    /// The relay peer ID.
    public let relay: PeerID

    /// The remote peer ID (the actual peer we're communicating with).
    public let remotePeer: PeerID

    /// Circuit limits applied by the relay.
    public let limit: CircuitLimit

    /// The underlying multiplexed stream.
    private let stream: MuxedStream

    /// Connection state.
    private let state: Mutex<ConnectionState>

    private struct ConnectionState: Sendable {
        var bytesRead: UInt64 = 0
        var bytesWritten: UInt64 = 0
        let startTime: ContinuousClock.Instant
        var isClosed: Bool = false

        init() {
            self.startTime = .now
        }
    }

    // MARK: - Initialization

    /// Creates a new relayed connection.
    ///
    /// - Parameters:
    ///   - stream: The underlying multiplexed stream.
    ///   - relay: The relay peer ID.
    ///   - remotePeer: The remote peer ID.
    ///   - limit: Circuit limits to enforce.
    public init(
        stream: MuxedStream,
        relay: PeerID,
        remotePeer: PeerID,
        limit: CircuitLimit
    ) {
        self.stream = stream
        self.relay = relay
        self.remotePeer = remotePeer
        self.limit = limit
        self.state = Mutex(ConnectionState())
    }

    // MARK: - Connection Info

    /// The remote address in circuit format.
    public var remoteAddress: Multiaddr {
        // Use unchecked since circuit addresses are always small (3 components)
        Multiaddr(uncheckedProtocols: [.p2p(relay), .p2pCircuit, .p2p(remotePeer)])
    }

    /// Total bytes transferred (read + written).
    public var bytesTransferred: UInt64 {
        state.withLock { $0.bytesRead + $0.bytesWritten }
    }

    /// Whether the connection is closed.
    public var isClosed: Bool {
        state.withLock { $0.isClosed }
    }

    /// Duration since connection was established.
    public var duration: Duration {
        state.withLock { ContinuousClock.now - $0.startTime }
    }

    // MARK: - I/O Operations

    /// Reads data from the relayed connection.
    ///
    /// - Returns: The data read.
    /// - Throws: `CircuitRelayError.circuitClosed` if closed,
    ///           `CircuitRelayError.limitExceeded` if limits exceeded.
    public func read() async throws -> Data {
        try checkLimits()

        let data = try await stream.read()

        state.withLock { s in
            s.bytesRead += UInt64(data.count)
        }

        return data
    }

    /// Writes data to the relayed connection.
    ///
    /// - Parameter data: The data to write.
    /// - Throws: `CircuitRelayError.circuitClosed` if closed,
    ///           `CircuitRelayError.limitExceeded` if limits exceeded.
    public func write(_ data: Data) async throws {
        try checkLimits()

        // Check if write would exceed data limit
        if let dataLimit = limit.data {
            let wouldExceed = state.withLock { s in
                s.bytesRead + s.bytesWritten + UInt64(data.count) > dataLimit
            }
            if wouldExceed {
                throw CircuitRelayError.limitExceeded(limit)
            }
        }

        try await stream.write(data)

        state.withLock { s in
            s.bytesWritten += UInt64(data.count)
        }
    }

    /// Closes the relayed connection.
    public func close() async throws {
        let alreadyClosed = state.withLock { s in
            let was = s.isClosed
            s.isClosed = true
            return was
        }

        if !alreadyClosed {
            try await stream.close()
        }
    }

    // MARK: - Private

    private func checkLimits() throws {
        let (totalBytes, elapsed, closed) = state.withLock { s in
            (s.bytesRead + s.bytesWritten, ContinuousClock.now - s.startTime, s.isClosed)
        }

        if closed {
            throw CircuitRelayError.circuitClosed
        }

        if let dataLimit = limit.data, totalBytes >= dataLimit {
            throw CircuitRelayError.limitExceeded(limit)
        }

        if let durationLimit = limit.duration, elapsed >= durationLimit {
            throw CircuitRelayError.limitExceeded(limit)
        }
    }
}
