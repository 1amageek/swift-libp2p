/// RendezvousPoint - Server-side rendezvous point for namespace-based peer discovery.
///
/// A rendezvous point accepts registrations from peers and serves
/// discovery queries from other peers.

import Foundation
import Synchronization
import P2PCore

/// Logger for Rendezvous point operations.
private let logger = Logger(label: "p2p.rendezvous.point")

/// Server-side rendezvous point.
///
/// Manages namespace registrations and serves discovery queries.
///
/// ## Usage
///
/// ```swift
/// let point = RendezvousPoint()
///
/// // Register a peer
/// let reg = try point.register(
///     peer: peerID,
///     namespace: "my-app",
///     addresses: [addr],
///     ttl: .seconds(3600)
/// )
///
/// // Discover peers
/// let (regs, cookie) = point.discover(namespace: "my-app")
///
/// // Listen for events
/// for await event in point.events {
///     switch event {
///     case .peerRegistered(let ns, let peer):
///         print("\(peer) registered in \(ns)")
///     }
/// }
/// ```
public final class RendezvousPoint: EventEmitting, Sendable {

    // MARK: - Event Type

    /// Events emitted by the RendezvousPoint.
    public enum Event: Sendable {
        /// A peer registered under a namespace.
        case peerRegistered(namespace: String, peer: PeerID)

        /// A peer unregistered from a namespace.
        case peerUnregistered(namespace: String, peer: PeerID)

        /// A registration expired and was removed.
        case registrationExpired(namespace: String, peer: PeerID)

        /// A new namespace was created (first registration).
        case namespaceCreated(String)
    }

    /// Configuration for the RendezvousPoint.
    public struct Configuration: Sendable {
        /// Maximum number of registrations allowed per peer (across all namespaces).
        public var maxRegistrationsPerPeer: Int

        /// Maximum number of registrations allowed per namespace.
        public var maxRegistrationsPerNamespace: Int

        /// Maximum number of namespaces the point will track.
        public var maxNamespaces: Int

        /// Creates a new configuration.
        ///
        /// - Parameters:
        ///   - maxRegistrationsPerPeer: Max registrations per peer (default: 100)
        ///   - maxRegistrationsPerNamespace: Max registrations per namespace (default: 1000)
        ///   - maxNamespaces: Max namespaces to track (default: 10000)
        public init(
            maxRegistrationsPerPeer: Int = 100,
            maxRegistrationsPerNamespace: Int = 1000,
            maxNamespaces: Int = 10000
        ) {
            self.maxRegistrationsPerPeer = maxRegistrationsPerPeer
            self.maxRegistrationsPerNamespace = maxRegistrationsPerNamespace
            self.maxNamespaces = maxNamespaces
        }
    }

    // MARK: - Internal State

    /// Per-namespace storage of registrations.
    private struct NamespaceState: Sendable {
        /// Ordered registrations (newest first for efficient cookie-based pagination).
        var registrations: [RendezvousRegistration] = []

        /// Cookie counter for pagination.
        var cookieCounter: UInt64 = 0
    }

    /// Cookie tracking for paginated discovery.
    private struct CookieInfo: Sendable {
        let namespace: String
        let offset: Int
    }

    private struct PointState: Sendable {
        /// Namespace -> registrations.
        var namespaces: [String: NamespaceState] = [:]

        /// Peer -> set of namespaces they are registered in.
        var peerNamespaces: [PeerID: Set<String>] = [:]

        /// Cookie data -> offset tracking.
        var cookies: [Data: CookieInfo] = [:]

        /// Counter for generating unique cookies.
        var nextCookieID: UInt64 = 0
    }

    // MARK: - Properties

    /// Point configuration.
    public let configuration: Configuration

    /// Event state (dedicated).
    private let eventState: Mutex<EventState>

    private struct EventState: Sendable {
        var stream: AsyncStream<Event>?
        var continuation: AsyncStream<Event>.Continuation?
    }

    /// Point state (separated).
    private let pointState: Mutex<PointState>

    // MARK: - Events

    /// Stream of events from this rendezvous point.
    ///
    /// This is a single-consumer stream. Only one `for await` loop should
    /// consume events at a time.
    public var events: AsyncStream<Event> {
        eventState.withLock { state in
            if let existing = state.stream { return existing }
            let (stream, continuation) = AsyncStream<Event>.makeStream()
            state.stream = stream
            state.continuation = continuation
            return stream
        }
    }

    // MARK: - Initialization

    /// Creates a new RendezvousPoint.
    ///
    /// - Parameter configuration: Point configuration
    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
        self.eventState = Mutex(EventState())
        self.pointState = Mutex(PointState())
    }

    // MARK: - Registration

    /// Registers a peer under a namespace.
    ///
    /// If the peer is already registered under this namespace, the existing
    /// registration is replaced with the new one.
    ///
    /// - Parameters:
    ///   - peer: The peer to register
    ///   - namespace: The namespace to register under
    ///   - addresses: The addresses the peer is reachable at
    ///   - ttl: The requested TTL for the registration
    /// - Returns: The created registration
    /// - Throws: `RendezvousError` if validation fails or limits are exceeded
    public func register(
        peer: PeerID,
        namespace: String,
        addresses: [Multiaddr],
        ttl: Duration
    ) throws -> RendezvousRegistration {
        // Validate namespace
        guard !namespace.isEmpty else {
            throw RendezvousError.invalidNamespace("Namespace must not be empty")
        }
        guard namespace.utf8.count <= RendezvousProtocol.maxNamespaceLength else {
            throw RendezvousError.invalidNamespace(
                "Namespace exceeds maximum length of \(RendezvousProtocol.maxNamespaceLength)"
            )
        }

        // Validate TTL
        guard ttl > .zero else {
            throw RendezvousError.invalidTTL("TTL must be positive")
        }

        // Clamp TTL to maximum
        let effectiveTTL: Duration
        if ttl > RendezvousProtocol.maxTTL {
            effectiveTTL = RendezvousProtocol.maxTTL
        } else {
            effectiveTTL = ttl
        }

        let expiry = ContinuousClock.now.advanced(by: effectiveTTL)
        let registration = RendezvousRegistration(
            namespace: namespace,
            peer: peer,
            addresses: addresses,
            ttl: effectiveTTL,
            expiry: expiry
        )

        // Perform the registration within the lock, collect events outside
        let pendingEvents: [Event] = pointState.withLock { state in
            var events: [Event] = []

            // Check namespace limit (only for new namespaces)
            let isNewNamespace = state.namespaces[namespace] == nil
            if isNewNamespace {
                guard state.namespaces.count < configuration.maxNamespaces else {
                    // Return empty events - we'll throw outside
                    return []
                }
            }

            // Check per-peer registration limit
            let currentPeerNamespaces = state.peerNamespaces[peer] ?? []
            if !currentPeerNamespaces.contains(namespace) {
                guard currentPeerNamespaces.count < configuration.maxRegistrationsPerPeer else {
                    return []
                }
            }

            // Get or create namespace state
            var nsState = state.namespaces[namespace] ?? NamespaceState()

            // Check per-namespace registration limit
            // If the peer already has a registration, it's a replacement (doesn't increase count)
            let existingIndex = nsState.registrations.firstIndex { $0.peer == peer }
            if existingIndex == nil {
                guard nsState.registrations.count < configuration.maxRegistrationsPerNamespace else {
                    return []
                }
            }

            // Remove existing registration for this peer if present
            if let index = existingIndex {
                nsState.registrations.remove(at: index)
            }

            // Add new registration
            nsState.registrations.append(registration)
            state.namespaces[namespace] = nsState

            // Track peer -> namespace mapping
            var peerNS = state.peerNamespaces[peer] ?? []
            peerNS.insert(namespace)
            state.peerNamespaces[peer] = peerNS

            if isNewNamespace {
                events.append(.namespaceCreated(namespace))
            }
            events.append(.peerRegistered(namespace: namespace, peer: peer))

            return events
        }

        // If no events were produced, it means a limit was hit
        if pendingEvents.isEmpty {
            // Determine which limit was exceeded
            let (nsCount, peerCount, nsRegCount, peerAlreadyInNS, namespaceExists) = pointState.withLock { state -> (Int, Int, Int, Bool, Bool) in
                let nsCount = state.namespaces.count
                let peerNS = state.peerNamespaces[peer] ?? []
                let peerCount = peerNS.count
                let peerInNS = peerNS.contains(namespace)
                let nsRegCount = state.namespaces[namespace]?.registrations.count ?? 0
                let nsExists = state.namespaces[namespace] != nil
                return (nsCount, peerCount, nsRegCount, peerInNS, nsExists)
            }

            if nsCount >= configuration.maxNamespaces && !namespaceExists {
                throw RendezvousError.tooManyNamespaces(configuration.maxNamespaces)
            }
            if !peerAlreadyInNS && peerCount >= configuration.maxRegistrationsPerPeer {
                throw RendezvousError.tooManyRegistrations(configuration.maxRegistrationsPerPeer)
            }
            if nsRegCount >= configuration.maxRegistrationsPerNamespace {
                throw RendezvousError.namespaceFull(namespace)
            }
            // Fallback
            throw RendezvousError.internalError("Registration failed due to unknown limit")
        }

        // Emit events outside the lock
        for event in pendingEvents {
            emit(event)
        }

        return registration
    }

    /// Unregisters a peer from a namespace.
    ///
    /// - Parameters:
    ///   - peer: The peer to unregister
    ///   - namespace: The namespace to unregister from
    public func unregister(peer: PeerID, namespace: String) {
        let pendingEvent: Event? = pointState.withLock { state in
            guard var nsState = state.namespaces[namespace] else {
                return nil
            }

            let countBefore = nsState.registrations.count
            nsState.registrations.removeAll { $0.peer == peer }

            if nsState.registrations.count < countBefore {
                // Registration was removed
                if nsState.registrations.isEmpty {
                    state.namespaces.removeValue(forKey: namespace)
                } else {
                    state.namespaces[namespace] = nsState
                }

                // Update peer -> namespace tracking
                state.peerNamespaces[peer]?.remove(namespace)
                if state.peerNamespaces[peer]?.isEmpty == true {
                    state.peerNamespaces.removeValue(forKey: peer)
                }

                return .peerUnregistered(namespace: namespace, peer: peer)
            }

            return nil
        }

        if let event = pendingEvent {
            emit(event)
        }
    }

    // MARK: - Discovery

    /// Discovers peers registered under a namespace.
    ///
    /// Supports cookie-based pagination for large namespaces.
    ///
    /// - Parameters:
    ///   - namespace: The namespace to search
    ///   - limit: Maximum number of registrations to return, or nil for all
    ///   - cookie: A cookie from a previous discovery call for pagination, or nil
    /// - Returns: A tuple of registrations and an optional cookie for the next page
    public func discover(
        namespace: String,
        limit: Int? = nil,
        cookie: Data? = nil
    ) -> (registrations: [RendezvousRegistration], cookie: Data?) {
        return pointState.withLock { state in
            guard let nsState = state.namespaces[namespace] else {
                return (registrations: [], cookie: nil)
            }

            // Filter out expired registrations (read-only view)
            let activeRegistrations = nsState.registrations.filter { !$0.isExpired }

            // Determine the start offset from cookie
            let startOffset: Int
            if let cookie = cookie, let cookieInfo = state.cookies[cookie] {
                guard cookieInfo.namespace == namespace else {
                    return (registrations: [], cookie: nil)
                }
                startOffset = cookieInfo.offset
            } else {
                startOffset = 0
            }

            guard startOffset < activeRegistrations.count else {
                return (registrations: [], cookie: nil)
            }

            // Slice the results
            let remaining = Array(activeRegistrations.dropFirst(startOffset))
            let result: [RendezvousRegistration]
            let hasMore: Bool

            if let limit = limit, limit > 0, remaining.count > limit {
                result = Array(remaining.prefix(limit))
                hasMore = true
            } else {
                result = remaining
                hasMore = false
            }

            // Generate a cookie if there are more results
            let nextCookie: Data?
            if hasMore {
                let cookieID = state.nextCookieID
                state.nextCookieID += 1

                var cookieData = Data(capacity: 8)
                var id = cookieID
                withUnsafeBytes(of: &id) { cookieData.append(contentsOf: $0) }

                let cookieInfo = CookieInfo(
                    namespace: namespace,
                    offset: startOffset + result.count
                )
                state.cookies[cookieData] = cookieInfo
                nextCookie = cookieData
            } else {
                nextCookie = nil
            }

            return (registrations: result, cookie: nextCookie)
        }
    }

    /// Returns the number of active registrations in a namespace.
    ///
    /// - Parameter namespace: The namespace to query
    /// - Returns: The number of non-expired registrations
    public func registrationCount(namespace: String) -> Int {
        pointState.withLock { state in
            guard let nsState = state.namespaces[namespace] else {
                return 0
            }
            return nsState.registrations.filter { !$0.isExpired }.count
        }
    }

    /// Returns all namespaces that have at least one active registration.
    ///
    /// - Returns: Array of namespace strings
    public func allNamespaces() -> [String] {
        pointState.withLock { state in
            Array(state.namespaces.keys)
        }
    }

    // MARK: - Cleanup

    /// Removes all expired registrations across all namespaces.
    ///
    /// This should be called periodically to clean up stale entries.
    public func removeExpiredRegistrations() {
        let pendingEvents: [Event] = pointState.withLock { state in
            var events: [Event] = []
            var emptyNamespaces: [String] = []

            for (namespace, var nsState) in state.namespaces {
                let before = nsState.registrations
                nsState.registrations.removeAll { registration in
                    if registration.isExpired {
                        events.append(.registrationExpired(
                            namespace: namespace,
                            peer: registration.peer
                        ))
                        // Remove from peer tracking
                        state.peerNamespaces[registration.peer]?.remove(namespace)
                        if state.peerNamespaces[registration.peer]?.isEmpty == true {
                            state.peerNamespaces.removeValue(forKey: registration.peer)
                        }
                        return true
                    }
                    return false
                }

                if nsState.registrations.isEmpty && before.count > 0 {
                    emptyNamespaces.append(namespace)
                } else if nsState.registrations.count != before.count {
                    state.namespaces[namespace] = nsState
                }
            }

            // Remove empty namespaces
            for namespace in emptyNamespaces {
                state.namespaces.removeValue(forKey: namespace)
            }

            return events
        }

        // Emit events outside the lock
        for event in pendingEvents {
            emit(event)
        }
    }

    // MARK: - Shutdown

    /// Shuts down the rendezvous point and finishes the event stream.
    ///
    /// This terminates any consumers waiting on the `events` stream.
    /// This method is idempotent and safe to call multiple times.
    public func shutdown() {
        eventState.withLock { state in
            state.continuation?.finish()
            state.continuation = nil
            state.stream = nil
        }
    }

    // MARK: - Private

    private func emit(_ event: Event) {
        _ = eventState.withLock { state in
            state.continuation?.yield(event)
        }
    }

}
