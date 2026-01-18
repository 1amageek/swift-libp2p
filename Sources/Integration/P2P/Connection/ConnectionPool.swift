/// ConnectionPool - Central connection state manager
///
/// Manages all connection state, tracking, and lifecycle operations.
/// This is an internal component used only by the Node actor.

import Foundation
import Synchronization
import P2PCore
import P2PMux

/// Configuration for the connection pool.
public struct PoolConfiguration: Sendable {
    /// Connection limits.
    public var limits: ConnectionLimits

    /// Reconnection policy.
    public var reconnectionPolicy: ReconnectionPolicy

    /// Idle timeout for connections.
    public var idleTimeout: Duration

    /// Optional connection gater.
    public var gater: (any ConnectionGater)?

    /// Creates a new pool configuration.
    public init(
        limits: ConnectionLimits = .default,
        reconnectionPolicy: ReconnectionPolicy = .default,
        idleTimeout: Duration = .seconds(60),
        gater: (any ConnectionGater)? = nil
    ) {
        self.limits = limits
        self.reconnectionPolicy = reconnectionPolicy
        self.idleTimeout = idleTimeout
        self.gater = gater
    }
}

/// Information about a managed connection.
internal struct ManagedConnection: Sendable {
    /// Unique connection identifier.
    let id: ConnectionID

    /// The peer on the other end.
    let peer: PeerID

    /// The address used for this connection.
    let address: Multiaddr

    /// Connection direction.
    let direction: ConnectionDirection

    /// The underlying muxed connection (nil if disconnected).
    var connection: (any MuxedConnection)?

    /// Current state.
    var state: ConnectionState

    /// Number of reconnection attempts.
    var retryCount: Int

    /// Last activity timestamp.
    var lastActivity: ContinuousClock.Instant

    /// When the connection was established.
    var connectedAt: ContinuousClock.Instant?

    /// Tags for this connection (affects trim priority).
    var tags: Set<String>

    /// Whether this connection is protected from trimming.
    var isProtected: Bool
}

/// Central manager for all connection state.
///
/// This class is designed to be used only by the Node actor.
/// It is `internal` and not intended for external use.
///
/// ## Thread Safety
/// All mutable state is protected by `Mutex<PoolState>`.
/// The Node actor serializes access, but Mutex provides
/// additional safety for any internal async operations.
///
/// ## Responsibilities
/// - Track all connections by ID and peer
/// - Manage pending dials (prevent duplicates)
/// - Handle tagging and protection
/// - Provide trimming logic
internal final class ConnectionPool: Sendable {

    /// Pool configuration.
    let configuration: PoolConfiguration

    /// Internal state protected by mutex.
    private let state: Mutex<PoolState>

    private struct PoolState: Sendable {
        /// All managed connections by ID.
        var connections: [ConnectionID: ManagedConnection] = [:]

        /// Mapping from peer to their connection IDs.
        var peerConnections: [PeerID: Set<ConnectionID>] = [:]

        /// Pending dial tasks (to prevent duplicate dials).
        var pendingDials: [PeerID: Task<PeerID, any Error>] = [:]

        /// Connections marked for auto-reconnect.
        var autoReconnect: [PeerID: Multiaddr] = [:]
    }

    /// Creates a new connection pool.
    ///
    /// - Parameter configuration: Pool configuration
    init(configuration: PoolConfiguration = .init()) {
        self.configuration = configuration
        self.state = Mutex(PoolState())
    }

    // MARK: - Connection Management

    /// Adds a new connection to the pool.
    ///
    /// - Parameters:
    ///   - connection: The muxed connection
    ///   - peer: The remote peer
    ///   - address: The connection address
    ///   - direction: Connection direction
    /// - Returns: The assigned connection ID
    @discardableResult
    func add(
        _ connection: any MuxedConnection,
        for peer: PeerID,
        address: Multiaddr,
        direction: ConnectionDirection
    ) -> ConnectionID {
        let id = ConnectionID()
        let now = ContinuousClock.now

        let managed = ManagedConnection(
            id: id,
            peer: peer,
            address: address,
            direction: direction,
            connection: connection,
            state: .connected,
            retryCount: 0,
            lastActivity: now,
            connectedAt: now,
            tags: [],
            isProtected: false
        )

        state.withLock { state in
            state.connections[id] = managed
            state.peerConnections[peer, default: []].insert(id)
        }

        return id
    }

    /// Removes a connection from the pool.
    ///
    /// - Parameter id: The connection ID to remove
    /// - Returns: The removed connection info, or nil if not found
    @discardableResult
    func remove(_ id: ConnectionID) -> ManagedConnection? {
        state.withLock { state in
            guard let managed = state.connections.removeValue(forKey: id) else {
                return nil
            }
            state.peerConnections[managed.peer]?.remove(id)
            if state.peerConnections[managed.peer]?.isEmpty == true {
                state.peerConnections.removeValue(forKey: managed.peer)
            }
            return managed
        }
    }

    /// Removes all connections for a peer.
    ///
    /// - Parameter peer: The peer whose connections to remove
    /// - Returns: The removed connections
    @discardableResult
    func remove(forPeer peer: PeerID) -> [ManagedConnection] {
        state.withLock { state in
            guard let ids = state.peerConnections.removeValue(forKey: peer) else {
                return []
            }
            return ids.compactMap { state.connections.removeValue(forKey: $0) }
        }
    }

    /// Updates the state of a connection.
    ///
    /// Also updates `lastActivity` when transitioning to `.disconnected`
    /// to ensure proper cleanup timing.
    ///
    /// - Parameters:
    ///   - id: The connection ID
    ///   - newState: The new state
    func updateState(_ id: ConnectionID, to newState: ConnectionState) {
        state.withLock { state in
            state.connections[id]?.state = newState

            // Update lastActivity on disconnect so cleanup timing is correct
            if newState.isDisconnected {
                state.connections[id]?.lastActivity = ContinuousClock.now
            }
        }
    }

    /// Updates the connection object (e.g., after reconnection).
    ///
    /// - Parameters:
    ///   - id: The connection ID
    ///   - connection: The new muxed connection
    func updateConnection(_ id: ConnectionID, connection: any MuxedConnection) {
        let now = ContinuousClock.now
        state.withLock { state in
            state.connections[id]?.connection = connection
            state.connections[id]?.state = .connected
            state.connections[id]?.lastActivity = now
            state.connections[id]?.connectedAt = now
        }
    }

    // MARK: - Query

    /// Gets an active connection to a peer and records activity.
    ///
    /// Atomically retrieves the connection and updates its last activity timestamp.
    /// This is the correct place to track activity because getting a connection
    /// implies it will be used.
    ///
    /// Prioritizes connections in `.connected` state.
    ///
    /// - Parameter peer: The peer to look up
    /// - Returns: The muxed connection, or nil if not connected
    func connection(to peer: PeerID) -> (any MuxedConnection)? {
        let now = ContinuousClock.now
        return state.withLock { state in
            guard let ids = state.peerConnections[peer] else { return nil }

            // Find first connected entry and record activity atomically
            for id in ids {
                if let managed = state.connections[id],
                   managed.state.isConnected,
                   managed.connection != nil {
                    state.connections[id]?.lastActivity = now
                    return managed.connection
                }
            }
            return nil
        }
    }

    /// Gets all connections to a peer.
    ///
    /// - Parameter peer: The peer to look up
    /// - Returns: All muxed connections to the peer
    func connections(to peer: PeerID) -> [any MuxedConnection] {
        state.withLock { state in
            guard let ids = state.peerConnections[peer] else {
                return []
            }
            return ids.compactMap { state.connections[$0]?.connection }
        }
    }

    /// Gets managed connection info by ID.
    ///
    /// - Parameter id: The connection ID
    /// - Returns: The managed connection info, or nil if not found
    func managedConnection(_ id: ConnectionID) -> ManagedConnection? {
        state.withLock { $0.connections[id] }
    }

    /// Gets the state of a peer's connection.
    ///
    /// Prioritizes the most relevant state:
    /// 1. `.connected` (if any)
    /// 2. `.reconnecting` (if any)
    /// 3. First available state
    ///
    /// - Parameter peer: The peer to look up
    /// - Returns: The connection state, or nil if not tracked
    func connectionState(of peer: PeerID) -> ConnectionState? {
        state.withLock { state in
            guard let ids = state.peerConnections[peer] else { return nil }

            var connectedState: ConnectionState?
            var reconnectingState: ConnectionState?
            var anyState: ConnectionState?

            for id in ids {
                guard let managed = state.connections[id] else { continue }
                anyState = managed.state

                if managed.state.isConnected {
                    connectedState = managed.state
                    break  // Connected is highest priority
                }
                if managed.state.isConnecting && reconnectingState == nil {
                    reconnectingState = managed.state
                }
            }

            return connectedState ?? reconnectingState ?? anyState
        }
    }

    /// All currently connected peers.
    var connectedPeers: [PeerID] {
        state.withLock { state in
            state.peerConnections.keys.filter { peer in
                state.peerConnections[peer]?.contains(where: { id in
                    state.connections[id]?.state.isConnected == true
                }) == true
            }
        }
    }

    /// Total number of active (connected) connections.
    ///
    /// Only `.connected` state connections are counted.
    /// Disconnected, reconnecting, and failed entries are not included.
    var connectionCount: Int {
        state.withLock { state in
            state.connections.values.filter { $0.state.isConnected }.count
        }
    }

    /// Total number of all tracked entries (including disconnected).
    ///
    /// Use this for debugging/monitoring, not for limit checks.
    var totalEntryCount: Int {
        state.withLock { $0.connections.count }
    }

    /// Number of active inbound connections.
    ///
    /// Only `.connected` state connections are counted.
    var inboundCount: Int {
        state.withLock { state in
            state.connections.values.filter {
                $0.direction == .inbound && $0.state.isConnected
            }.count
        }
    }

    /// Number of active outbound connections.
    ///
    /// Only `.connected` state connections are counted.
    var outboundCount: Int {
        state.withLock { state in
            state.connections.values.filter {
                $0.direction == .outbound && $0.state.isConnected
            }.count
        }
    }

    /// Checks if connected to a peer.
    ///
    /// - Parameter peer: The peer to check
    /// - Returns: true if at least one active connection exists
    func isConnected(to peer: PeerID) -> Bool {
        state.withLock { state in
            guard let ids = state.peerConnections[peer] else {
                return false
            }
            return ids.contains { id in
                state.connections[id]?.state.isConnected == true
            }
        }
    }

    // MARK: - Tagging & Protection

    /// Adds a tag to a peer's connections.
    ///
    /// - Parameters:
    ///   - peer: The peer to tag
    ///   - tag: The tag to add
    func tag(_ peer: PeerID, with tag: String) {
        state.withLock { state in
            guard let ids = state.peerConnections[peer] else { return }
            for id in ids {
                state.connections[id]?.tags.insert(tag)
            }
        }
    }

    /// Removes a tag from a peer's connections.
    ///
    /// - Parameters:
    ///   - peer: The peer to untag
    ///   - tag: The tag to remove
    func untag(_ peer: PeerID, tag: String) {
        state.withLock { state in
            guard let ids = state.peerConnections[peer] else { return }
            for id in ids {
                state.connections[id]?.tags.remove(tag)
            }
        }
    }

    /// Protects a peer's connections from trimming.
    ///
    /// - Parameter peer: The peer to protect
    func protect(_ peer: PeerID) {
        state.withLock { state in
            guard let ids = state.peerConnections[peer] else { return }
            for id in ids {
                state.connections[id]?.isProtected = true
            }
        }
    }

    /// Removes protection from a peer's connections.
    ///
    /// - Parameter peer: The peer to unprotect
    func unprotect(_ peer: PeerID) {
        state.withLock { state in
            guard let ids = state.peerConnections[peer] else { return }
            for id in ids {
                state.connections[id]?.isProtected = false
            }
        }
    }

    // MARK: - Trimming

    /// Trims connections if limits are exceeded.
    ///
    /// Only active (`.connected`) connections are counted against limits.
    /// Trimming prioritizes based on:
    /// 1. Protected connections are never trimmed
    /// 2. Connections within grace period are not trimmed
    /// 3. Fewer tags = lower priority (trimmed first)
    /// 4. Older last activity = lower priority
    /// 5. Inbound connections trimmed before outbound
    ///
    /// - Returns: List of connections that were trimmed
    func trimIfNeeded() -> [ManagedConnection] {
        state.withLock { state in
            // Count only connected entries for limit comparison
            let activeCount = state.connections.values.filter { $0.state.isConnected }.count
            let limits = configuration.limits

            guard activeCount > limits.highWatermark else {
                return []
            }

            let target = activeCount - limits.lowWatermark
            let now = ContinuousClock.now
            let graceCutoff = now - limits.gracePeriod

            // Get trimmable connections sorted by priority (lowest first)
            let candidates = state.connections.values
                .filter { managed in
                    // Not protected
                    guard !managed.isProtected else { return false }
                    // Not within grace period
                    guard let connectedAt = managed.connectedAt,
                          connectedAt < graceCutoff else { return false }
                    // Must be connected
                    guard managed.state.isConnected else { return false }
                    return true
                }
                .sorted { a, b in
                    // Fewer tags = trim first
                    if a.tags.count != b.tags.count {
                        return a.tags.count < b.tags.count
                    }
                    // Older activity = trim first
                    if a.lastActivity != b.lastActivity {
                        return a.lastActivity < b.lastActivity
                    }
                    // Inbound before outbound
                    if a.direction != b.direction {
                        return a.direction == .inbound
                    }
                    return false
                }

            // Take the first `target` connections
            let toTrim = Array(candidates.prefix(target))

            // Remove them from state
            for managed in toTrim {
                state.connections.removeValue(forKey: managed.id)
                state.peerConnections[managed.peer]?.remove(managed.id)
                if state.peerConnections[managed.peer]?.isEmpty == true {
                    state.peerConnections.removeValue(forKey: managed.peer)
                }
            }

            return toTrim
        }
    }

    /// Removes stale entries from the pool.
    ///
    /// This removes:
    /// - All entries in `.failed` state
    /// - Entries in `.disconnected` state older than the threshold
    ///
    /// - Parameter disconnectedThreshold: How long a disconnected entry can stay
    /// - Returns: List of removed entries
    @discardableResult
    func cleanupStaleEntries(disconnectedThreshold: Duration = .seconds(60)) -> [ManagedConnection] {
        let cutoff = ContinuousClock.now - disconnectedThreshold

        return state.withLock { state in
            // First pass: collect IDs to remove (avoid mutating during iteration)
            var idsToRemove: [ConnectionID] = []

            for (id, managed) in state.connections {
                let shouldRemove: Bool
                switch managed.state {
                case .failed:
                    // Always remove failed entries
                    shouldRemove = true
                case .disconnected:
                    // Remove if disconnected for too long and not auto-reconnect
                    if state.autoReconnect[managed.peer] == nil {
                        shouldRemove = managed.lastActivity < cutoff
                    } else {
                        shouldRemove = false
                    }
                default:
                    shouldRemove = false
                }

                if shouldRemove {
                    idsToRemove.append(id)
                }
            }

            // Second pass: remove collected entries
            var removed: [ManagedConnection] = []
            for id in idsToRemove {
                if let managed = state.connections.removeValue(forKey: id) {
                    state.peerConnections[managed.peer]?.remove(id)
                    if state.peerConnections[managed.peer]?.isEmpty == true {
                        state.peerConnections.removeValue(forKey: managed.peer)
                    }
                    removed.append(managed)
                }
            }

            return removed
        }
    }

    /// Gets the reconnecting connection ID for a peer.
    ///
    /// Used to update existing entry on successful reconnection.
    /// Only returns entries in `.reconnecting` state (not `.connecting`).
    ///
    /// - Parameter peer: The peer to look up
    /// - Returns: The connection ID in reconnecting state, or nil
    func reconnectingConnectionID(for peer: PeerID) -> ConnectionID? {
        state.withLock { state in
            guard let ids = state.peerConnections[peer] else { return nil }
            for id in ids {
                if let managed = state.connections[id],
                   case .reconnecting = managed.state {
                    return id
                }
            }
            return nil
        }
    }

    // MARK: - Auto-Reconnect

    /// Enables auto-reconnect for a peer.
    ///
    /// - Parameters:
    ///   - peer: The peer to reconnect to
    ///   - address: The address to use for reconnection
    func enableAutoReconnect(for peer: PeerID, address: Multiaddr) {
        state.withLock { state in
            state.autoReconnect[peer] = address
        }
    }

    /// Disables auto-reconnect for a peer.
    ///
    /// - Parameter peer: The peer to stop reconnecting to
    func disableAutoReconnect(for peer: PeerID) {
        _ = state.withLock { state in
            state.autoReconnect.removeValue(forKey: peer)
        }
    }

    /// Gets the reconnect address for a peer.
    ///
    /// - Parameter peer: The peer to look up
    /// - Returns: The reconnect address, or nil if not enabled
    func reconnectAddress(for peer: PeerID) -> Multiaddr? {
        state.withLock { $0.autoReconnect[peer] }
    }

    /// Increments and returns the retry count for a connection.
    ///
    /// - Parameter id: The connection ID
    /// - Returns: The new retry count, or nil if not found
    @discardableResult
    func incrementRetryCount(_ id: ConnectionID) -> Int? {
        state.withLock { state in
            guard state.connections[id] != nil else { return nil }
            state.connections[id]?.retryCount += 1
            return state.connections[id]?.retryCount
        }
    }

    /// Resets the retry count for a connection.
    ///
    /// - Parameter id: The connection ID
    func resetRetryCount(_ id: ConnectionID) {
        state.withLock { state in
            state.connections[id]?.retryCount = 0
        }
    }

    // MARK: - Pending Dials

    /// Checks if there's a pending dial to a peer.
    ///
    /// - Parameter peer: The peer to check
    /// - Returns: true if a dial is in progress
    func hasPendingDial(to peer: PeerID) -> Bool {
        state.withLock { $0.pendingDials[peer] != nil }
    }

    /// Gets the pending dial task for a peer.
    ///
    /// - Parameter peer: The peer to look up
    /// - Returns: The dial task, or nil if no pending dial
    func pendingDial(to peer: PeerID) -> Task<PeerID, any Error>? {
        state.withLock { $0.pendingDials[peer] }
    }

    /// Registers a pending dial task.
    ///
    /// - Parameters:
    ///   - task: The dial task
    ///   - peer: The peer being dialed
    func registerPendingDial(_ task: Task<PeerID, any Error>, for peer: PeerID) {
        state.withLock { $0.pendingDials[peer] = task }
    }

    /// Removes a pending dial registration.
    ///
    /// - Parameter peer: The peer to remove
    func removePendingDial(for peer: PeerID) {
        state.withLock { _ = $0.pendingDials.removeValue(forKey: peer) }
    }

    /// Cancels and removes all pending dials.
    ///
    /// Called during node shutdown to clean up in-flight dial attempts.
    func cancelAllPendingDials() {
        let tasks = state.withLock { state in
            let dials = state.pendingDials
            state.pendingDials.removeAll()
            return dials
        }
        for (_, task) in tasks {
            task.cancel()
        }
    }

    // MARK: - Activity Tracking

    /// Records activity on a connection.
    ///
    /// Note: For most use cases, prefer using `connection(to:)` which
    /// atomically retrieves and records activity. This method is only
    /// needed for internal operations where the connection ID is known.
    ///
    /// - Parameter id: The connection ID
    func recordActivity(_ id: ConnectionID) {
        state.withLock { state in
            state.connections[id]?.lastActivity = ContinuousClock.now
        }
    }

    /// Gets connections that have been idle beyond the threshold.
    ///
    /// - Parameter threshold: How long without activity to consider idle
    /// - Returns: List of idle connections
    func idleConnections(threshold: Duration) -> [ManagedConnection] {
        let cutoff = ContinuousClock.now - threshold
        return state.withLock { state in
            state.connections.values.filter { managed in
                managed.state.isConnected && managed.lastActivity < cutoff
            }
        }
    }

    // MARK: - Limits Checks

    /// Checks if a new inbound connection can be accepted.
    ///
    /// - Returns: true if within inbound limits
    func canAcceptInbound() -> Bool {
        guard let maxInbound = configuration.limits.maxInbound else {
            return true
        }
        return inboundCount < maxInbound
    }

    /// Checks if a new outbound connection can be established.
    ///
    /// - Returns: true if within outbound limits
    func canDialOutbound() -> Bool {
        guard let maxOutbound = configuration.limits.maxOutbound else {
            return true
        }
        return outboundCount < maxOutbound
    }

    /// Checks if another connection to a peer is allowed.
    ///
    /// Only counts active (`.connected`) connections toward the limit.
    ///
    /// - Parameter peer: The peer to check
    /// - Returns: true if within per-peer limit
    func canConnectTo(peer: PeerID) -> Bool {
        let activeCount = state.withLock { state in
            guard let ids = state.peerConnections[peer] else { return 0 }
            return ids.filter { id in
                state.connections[id]?.state.isConnected == true
            }.count
        }
        return activeCount < configuration.limits.maxConnectionsPerPeer
    }
}
