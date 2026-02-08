/// RendezvousService - Client service for namespace-based peer discovery.
///
/// Provides registration and discovery functionality via rendezvous points.
/// Peers register themselves under namespaces, and other peers can discover
/// them by querying those namespaces.

import Foundation
import Synchronization
import P2PCore
import P2PProtocols

/// Logger for Rendezvous client operations.
private let logger = Logger(label: "p2p.rendezvous.client")

/// Client service for the Rendezvous protocol.
///
/// Manages registrations and discovery via one or more rendezvous points.
///
/// ## Usage
///
/// ```swift
/// let service = RendezvousService()
///
/// // Register under a namespace
/// let registration = try service.register(namespace: "my-app")
///
/// // Discover peers in a namespace
/// let peers = service.discover(namespace: "my-app")
///
/// // Listen for events
/// for await event in service.events {
///     switch event {
///     case .registered(let ns, let ttl):
///         print("Registered in \(ns) with TTL \(ttl)")
///     case .discovered(let ns, let peers):
///         print("Discovered \(peers.count) peers in \(ns)")
///     }
/// }
/// ```
public final class RendezvousService: EventEmitting, Sendable {

    // MARK: - Event Type

    /// Events emitted by the RendezvousService.
    public enum Event: Sendable {
        /// Successfully registered under a namespace.
        case registered(namespace: String, ttl: Duration)

        /// Successfully unregistered from a namespace.
        case unregistered(namespace: String)

        /// Discovered peers in a namespace.
        case discovered(namespace: String, peers: [DiscoveredPeer])

        /// A registration has expired and was removed.
        case registrationExpired(namespace: String)

        /// An error occurred during an operation.
        case error(RendezvousError)
    }

    /// A peer discovered via the Rendezvous protocol.
    public struct DiscoveredPeer: Sendable {
        /// The discovered peer's identifier.
        public let peer: PeerID

        /// The addresses the peer is reachable at.
        public let addresses: [Multiaddr]

        /// The remaining time-to-live for this peer's registration.
        public let ttl: Duration

        /// Creates a new discovered peer.
        ///
        /// - Parameters:
        ///   - peer: The peer's identifier
        ///   - addresses: Addresses the peer is reachable at
        ///   - ttl: Remaining TTL for the registration
        public init(peer: PeerID, addresses: [Multiaddr], ttl: Duration) {
            self.peer = peer
            self.addresses = addresses
            self.ttl = ttl
        }
    }

    /// An active registration managed by this service.
    public struct Registration: Sendable {
        /// The namespace this registration is for.
        public let namespace: String

        /// The TTL granted by the rendezvous point.
        public let ttl: Duration

        /// When this registration expires.
        public let expiry: ContinuousClock.Instant

        /// Creates a new registration record.
        ///
        /// - Parameters:
        ///   - namespace: The registered namespace
        ///   - ttl: The TTL granted
        ///   - expiry: When the registration expires
        public init(namespace: String, ttl: Duration, expiry: ContinuousClock.Instant) {
            self.namespace = namespace
            self.ttl = ttl
            self.expiry = expiry
        }

        /// Whether this registration has expired.
        public var isExpired: Bool {
            ContinuousClock.now >= expiry
        }
    }

    /// Configuration for the RendezvousService.
    public struct Configuration: Sendable {
        /// Default TTL to request when registering.
        public var defaultTTL: Duration

        /// Whether to automatically refresh registrations before expiry.
        public var autoRefresh: Bool

        /// How far in advance of expiry to refresh (buffer time).
        public var refreshBuffer: Duration

        /// Creates a new configuration.
        ///
        /// - Parameters:
        ///   - defaultTTL: Default TTL to request (defaults to protocol default of 2 hours)
        ///   - autoRefresh: Whether to auto-refresh registrations (defaults to true)
        ///   - refreshBuffer: Buffer time before expiry to trigger refresh (defaults to 5 minutes)
        public init(
            defaultTTL: Duration = RendezvousProtocol.defaultTTL,
            autoRefresh: Bool = true,
            refreshBuffer: Duration = .seconds(300)
        ) {
            self.defaultTTL = defaultTTL
            self.autoRefresh = autoRefresh
            self.refreshBuffer = refreshBuffer
        }
    }

    // MARK: - Properties

    /// Service configuration.
    public let configuration: Configuration

    /// Event state (dedicated).
    private let eventState: Mutex<EventState>

    private struct EventState: Sendable {
        var stream: AsyncStream<Event>?
        var continuation: AsyncStream<Event>.Continuation?
    }

    /// Service state (separated).
    private let serviceState: Mutex<ServiceState>

    private struct ServiceState: Sendable {
        var registrations: [String: Registration] = [:]
        var discoveryCache: [String: [DiscoveredPeer]] = [:]
    }

    // MARK: - Events

    /// Stream of events from this service.
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

    /// Creates a new RendezvousService.
    ///
    /// - Parameter configuration: Service configuration
    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
        self.eventState = Mutex(EventState())
        self.serviceState = Mutex(ServiceState())
    }

    // MARK: - Registration

    /// Registers under a namespace.
    ///
    /// - Parameters:
    ///   - namespace: The namespace to register under (max 255 characters)
    ///   - ttl: The TTL to request, or nil to use the configured default
    /// - Returns: The registration record
    /// - Throws: `RendezvousError.invalidNamespace` if the namespace is empty or too long,
    ///           `RendezvousError.invalidTTL` if the TTL exceeds the maximum
    public func register(namespace: String, ttl: Duration? = nil) throws -> Registration {
        // Validate namespace
        guard !namespace.isEmpty else {
            throw RendezvousError.invalidNamespace("Namespace must not be empty")
        }
        guard namespace.utf8.count <= RendezvousProtocol.maxNamespaceLength else {
            throw RendezvousError.invalidNamespace(
                "Namespace exceeds maximum length of \(RendezvousProtocol.maxNamespaceLength)"
            )
        }

        // Validate and resolve TTL
        let requestedTTL = ttl ?? configuration.defaultTTL
        guard requestedTTL > .zero else {
            throw RendezvousError.invalidTTL("TTL must be positive")
        }

        let effectiveTTL: Duration
        if requestedTTL > RendezvousProtocol.maxTTL {
            effectiveTTL = RendezvousProtocol.maxTTL
        } else {
            effectiveTTL = requestedTTL
        }

        let expiry = ContinuousClock.now.advanced(by: effectiveTTL)
        let registration = Registration(
            namespace: namespace,
            ttl: effectiveTTL,
            expiry: expiry
        )

        // Store registration and collect pending event
        let pendingEvent: Event = serviceState.withLock { state in
            state.registrations[namespace] = registration
            return .registered(namespace: namespace, ttl: effectiveTTL)
        }

        emit(pendingEvent)
        return registration
    }

    /// Unregisters from a namespace.
    ///
    /// - Parameter namespace: The namespace to unregister from
    public func unregister(namespace: String) {
        let pendingEvent: Event? = serviceState.withLock { state in
            if state.registrations.removeValue(forKey: namespace) != nil {
                return .unregistered(namespace: namespace)
            }
            return nil
        }

        if let event = pendingEvent {
            emit(event)
        }
    }

    /// Returns all active (non-expired) registrations.
    ///
    /// - Returns: A dictionary mapping namespace to registration
    public func activeRegistrations() -> [String: Registration] {
        let (active, expired) = serviceState.withLock { state -> ([String: Registration], [String]) in
            var expiredNamespaces: [String] = []
            var activeRegistrations: [String: Registration] = [:]

            for (namespace, registration) in state.registrations {
                if registration.isExpired {
                    expiredNamespaces.append(namespace)
                } else {
                    activeRegistrations[namespace] = registration
                }
            }

            // Remove expired registrations
            for namespace in expiredNamespaces {
                state.registrations.removeValue(forKey: namespace)
            }

            return (activeRegistrations, expiredNamespaces)
        }

        // Emit expiry events outside of lock
        for namespace in expired {
            emit(.registrationExpired(namespace: namespace))
        }

        return active
    }

    // MARK: - Discovery

    /// Discovers peers registered under a namespace.
    ///
    /// - Parameters:
    ///   - namespace: The namespace to search
    ///   - limit: Maximum number of peers to return, or nil for no limit
    /// - Returns: Array of discovered peers
    public func discover(namespace: String, limit: Int? = nil) -> [DiscoveredPeer] {
        let allPeers: [DiscoveredPeer] = serviceState.withLock { state in
            state.discoveryCache[namespace] ?? []
        }

        let result: [DiscoveredPeer]
        if let limit = limit, limit > 0 {
            result = Array(allPeers.prefix(limit))
        } else {
            result = allPeers
        }

        if !result.isEmpty {
            emit(.discovered(namespace: namespace, peers: result))
        }

        return result
    }

    /// Updates the discovery cache for a namespace.
    ///
    /// This is called when peers are received from a rendezvous point.
    ///
    /// - Parameters:
    ///   - namespace: The namespace the peers belong to
    ///   - peers: The discovered peers
    public func updateDiscoveryCache(namespace: String, peers: [DiscoveredPeer]) {
        serviceState.withLock { state in
            state.discoveryCache[namespace] = peers
        }
    }

    /// Clears the discovery cache for a namespace.
    ///
    /// - Parameter namespace: The namespace to clear, or nil to clear all
    public func clearDiscoveryCache(namespace: String? = nil) {
        serviceState.withLock { state in
            if let namespace = namespace {
                state.discoveryCache.removeValue(forKey: namespace)
            } else {
                state.discoveryCache.removeAll()
            }
        }
    }

    // MARK: - Shutdown

    /// Shuts down the service and finishes the event stream.
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
