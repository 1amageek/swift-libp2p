/// AutoRelay - Automatic relay address advertisement for NAT-traversed peers.
///
/// When a peer is behind NAT (privateOnly reachability from AutoNAT),
/// AutoRelay automatically makes reservations on candidate relay peers
/// and advertises the resulting relay addresses.

import Foundation
import Synchronization
import P2PCore

/// Logger for AutoRelay operations.
private let logger = Logger(label: "p2p.circuit-relay.autorelay")

/// Configuration for AutoRelay.
public struct AutoRelayConfiguration: Sendable {
    /// Maximum number of active relay reservations to maintain.
    public var maxRelays: Int

    /// Interval between reservation refresh cycles.
    public var refreshInterval: Duration

    /// Timeout for individual reservation requests.
    public var reservationTimeout: Duration

    /// Creates a new configuration.
    ///
    /// - Parameters:
    ///   - maxRelays: Maximum number of active relay reservations. Default: 3.
    ///   - refreshInterval: Interval between refresh cycles. Default: 300 seconds.
    ///   - reservationTimeout: Timeout for reservation requests. Default: 30 seconds.
    public init(
        maxRelays: Int = 3,
        refreshInterval: Duration = .seconds(300),
        reservationTimeout: Duration = .seconds(30)
    ) {
        self.maxRelays = maxRelays
        self.refreshInterval = refreshInterval
        self.reservationTimeout = reservationTimeout
    }
}

/// Reachability status as reported by AutoNAT.
///
/// This mirrors the AutoNATv2Service.Reachability enum to avoid
/// a compile-time dependency on P2PAutoNAT.
public enum AutoRelayReachability: Sendable, Equatable {
    /// Reachability has not been determined yet.
    case unknown

    /// The node is publicly reachable.
    case publiclyReachable

    /// The node is only reachable on private networks (behind NAT).
    case privateOnly
}

/// AutoRelay service that manages relay reservations when the local peer
/// is behind NAT.
///
/// ## Overview
///
/// AutoRelay monitors the peer's NAT reachability status. When the peer
/// becomes `privateOnly`, the caller triggers reservation cycles to select
/// candidate relays and make reservations. Relay addresses are advertised
/// in the format:
///
/// ```
/// /ip4/<relay-ip>/tcp/<port>/p2p/<relay-id>/p2p-circuit/p2p/<self-id>
/// ```
///
/// ## Usage
///
/// ```swift
/// let autoRelay = AutoRelay(localPeer: myPeerID)
///
/// // Add candidate relays discovered from the network
/// autoRelay.addCandidateRelay(relayPeer, addresses: relayAddresses)
///
/// // Update reachability from AutoNAT
/// autoRelay.updateReachability(.privateOnly)
///
/// // Trigger reservation cycle
/// await autoRelay.performReservationCycle { peer, addrs in
///     let reservation = try await relayClient.reserve(on: peer, using: opener)
///     return reservation.addresses
/// }
///
/// // Listen for events
/// for await event in autoRelay.events {
///     switch event {
///     case .relayAddressesUpdated(let addresses):
///         // Advertise these addresses
///         break
///     default:
///         break
///     }
/// }
/// ```
public final class AutoRelay: EventEmitting, Sendable {

    // MARK: - Types

    /// Events emitted by AutoRelay.
    public enum Event: Sendable {
        /// A new relay was selected and reservation established.
        case relayAdded(PeerID, [Multiaddr])

        /// A relay was removed (reservation lost or relay unreachable).
        case relayRemoved(PeerID)

        /// The complete set of relay addresses changed.
        case relayAddressesUpdated([Multiaddr])

        /// A reservation attempt failed on a candidate relay.
        case reservationFailed(PeerID, Error)
    }

    /// Internal representation of a candidate relay.
    struct CandidateRelay: Sendable {
        let peerID: PeerID
        let addresses: [Multiaddr]
    }

    /// Internal representation of an active relay.
    struct ActiveRelay: Sendable {
        let peerID: PeerID
        let addresses: [Multiaddr]
        let relayAddresses: [Multiaddr]
    }

    // MARK: - EventEmitting State

    private let eventState: Mutex<EventState>

    private struct EventState: Sendable {
        var stream: AsyncStream<Event>?
        var continuation: AsyncStream<Event>.Continuation?
    }

    // MARK: - Service State

    private let serviceState: Mutex<ServiceState>

    private struct ServiceState: Sendable {
        /// Current NAT reachability.
        var reachability: AutoRelayReachability = .unknown

        /// Candidate relays available for reservation.
        var candidates: [PeerID: CandidateRelay] = [:]

        /// Currently active relays with reservations.
        var activeRelays: [PeerID: ActiveRelay] = [:]

        /// Whether a reservation cycle is currently running.
        var isReserving: Bool = false

        /// Whether the service has been shut down.
        var isShutDown: Bool = false
    }

    // MARK: - Properties

    /// The local peer ID (used for constructing relay addresses).
    public let localPeer: PeerID

    /// The configuration.
    public let configuration: AutoRelayConfiguration

    // MARK: - Events

    /// Stream of AutoRelay events (single consumer).
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

    /// Creates a new AutoRelay service.
    ///
    /// - Parameters:
    ///   - localPeer: The local peer ID for constructing relay addresses.
    ///   - configuration: The configuration. Default configuration is used if not specified.
    public init(
        localPeer: PeerID,
        configuration: AutoRelayConfiguration = .init()
    ) {
        self.localPeer = localPeer
        self.configuration = configuration
        self.eventState = Mutex(EventState())
        self.serviceState = Mutex(ServiceState())
    }

    // MARK: - Public API

    /// Returns the current list of relay addresses.
    ///
    /// These addresses are in the format:
    /// `/ip4/<relay-ip>/tcp/<port>/p2p/<relay-id>/p2p-circuit/p2p/<self-id>`
    ///
    /// - Returns: All relay addresses from active reservations.
    public func relayAddresses() -> [Multiaddr] {
        serviceState.withLock { state in
            state.activeRelays.values.flatMap { $0.relayAddresses }
        }
    }

    /// Returns the list of currently active relay peer IDs.
    ///
    /// - Returns: Peer IDs of relays with active reservations.
    public func activeRelayPeers() -> [PeerID] {
        serviceState.withLock { state in
            Array(state.activeRelays.keys)
        }
    }

    /// Returns the current reachability status.
    public var currentReachability: AutoRelayReachability {
        serviceState.withLock { $0.reachability }
    }

    /// Whether the service needs more relay reservations.
    ///
    /// Returns `true` when reachability is `privateOnly` and the number
    /// of active relays is below `maxRelays`.
    public var needsMoreRelays: Bool {
        serviceState.withLock { state in
            state.reachability == .privateOnly
            && state.activeRelays.count < configuration.maxRelays
            && !state.isShutDown
        }
    }

    /// Adds a candidate relay that can be used for reservations.
    ///
    /// The candidate will be considered during the next reservation cycle
    /// when the peer is behind NAT (`privateOnly`).
    ///
    /// - Parameters:
    ///   - peer: The relay peer ID.
    ///   - addresses: The relay's network addresses.
    public func addCandidateRelay(_ peer: PeerID, addresses: [Multiaddr]) {
        serviceState.withLock { state in
            guard !state.isShutDown else { return }
            state.candidates[peer] = CandidateRelay(peerID: peer, addresses: addresses)
        }
    }

    /// Removes a candidate relay.
    ///
    /// If the relay currently has an active reservation, it will be removed
    /// and a `relayRemoved` event will be emitted.
    ///
    /// - Parameter peer: The relay peer ID to remove.
    public func removeCandidateRelay(_ peer: PeerID) {
        let pendingEvents = serviceState.withLock { state -> [Event] in
            state.candidates.removeValue(forKey: peer)

            if state.activeRelays.removeValue(forKey: peer) != nil {
                var events: [Event] = [.relayRemoved(peer)]
                let allAddresses = state.activeRelays.values.flatMap { $0.relayAddresses }
                events.append(.relayAddressesUpdated(allAddresses))
                return events
            }
            return []
        }

        emitAll(pendingEvents)
    }

    /// Updates the NAT reachability status.
    ///
    /// When transitioning to `publiclyReachable` or `unknown`, all active
    /// relay reservations are cleared and corresponding events are emitted.
    ///
    /// When transitioning to `privateOnly`, the caller should subsequently
    /// call `performReservationCycle` to initiate relay reservations.
    ///
    /// - Parameter reachability: The new reachability status.
    public func updateReachability(_ reachability: AutoRelayReachability) {
        let pendingEvents = serviceState.withLock { state -> [Event] in
            let old = state.reachability
            state.reachability = reachability

            if old == reachability { return [] }

            switch reachability {
            case .privateOnly:
                // Caller should trigger reservation cycle
                return []

            case .publiclyReachable, .unknown:
                // Clear all active relays when we become publicly reachable
                var events: [Event] = []
                for (peerID, _) in state.activeRelays {
                    events.append(.relayRemoved(peerID))
                }
                if !state.activeRelays.isEmpty {
                    events.append(.relayAddressesUpdated([]))
                }
                state.activeRelays.removeAll()
                return events
            }
        }

        emitAll(pendingEvents)
    }

    /// Performs a reservation cycle to select and reserve relays.
    ///
    /// This is the core reservation cycle. It selects candidates that are not
    /// already active and attempts reservations up to `maxRelays`.
    ///
    /// - Parameter reserveAction: A closure that performs the actual reservation
    ///   on a relay peer and returns the relay's advertised addresses.
    ///   If nil, candidates are added as active relays using their candidate
    ///   addresses directly (useful for unit testing).
    public func performReservationCycle(
        reserveAction: (@Sendable (PeerID, [Multiaddr]) async throws -> [Multiaddr])? = nil
    ) async {
        let candidates = serviceState.withLock { state -> [CandidateRelay] in
            guard state.reachability == .privateOnly else { return [] }
            guard !state.isShutDown else { return [] }

            state.isReserving = true

            let needed = configuration.maxRelays - state.activeRelays.count
            guard needed > 0 else { return [] }

            return Array(
                state.candidates.values
                    .filter { !state.activeRelays.keys.contains($0.peerID) }
                    .prefix(needed)
            )
        }

        for candidate in candidates {
            let isShutDown = serviceState.withLock { $0.isShutDown }
            guard !isShutDown else { break }

            let currentCount = serviceState.withLock { $0.activeRelays.count }
            guard currentCount < configuration.maxRelays else { break }

            if let action = reserveAction {
                do {
                    let relayAddresses = try await action(candidate.peerID, candidate.addresses)
                    let circuitAddresses = buildCircuitAddresses(
                        relayPeer: candidate.peerID,
                        relayAddresses: relayAddresses
                    )

                    let pendingEvents = serviceState.withLock { state -> [Event] in
                        let active = ActiveRelay(
                            peerID: candidate.peerID,
                            addresses: relayAddresses,
                            relayAddresses: circuitAddresses
                        )
                        state.activeRelays[candidate.peerID] = active

                        var events: [Event] = [.relayAdded(candidate.peerID, circuitAddresses)]
                        let allAddresses = state.activeRelays.values.flatMap { $0.relayAddresses }
                        events.append(.relayAddressesUpdated(allAddresses))
                        return events
                    }

                    emitAll(pendingEvents)

                } catch {
                    logger.debug("Reservation failed on \(candidate.peerID): \(error)")
                    emit(.reservationFailed(candidate.peerID, error))
                }
            } else {
                // No reserve action - mark as active with constructed addresses
                let circuitAddresses = buildCircuitAddresses(
                    relayPeer: candidate.peerID,
                    relayAddresses: candidate.addresses
                )

                let pendingEvents = serviceState.withLock { state -> [Event] in
                    let active = ActiveRelay(
                        peerID: candidate.peerID,
                        addresses: candidate.addresses,
                        relayAddresses: circuitAddresses
                    )
                    state.activeRelays[candidate.peerID] = active

                    var events: [Event] = [.relayAdded(candidate.peerID, circuitAddresses)]
                    let allAddresses = state.activeRelays.values.flatMap { $0.relayAddresses }
                    events.append(.relayAddressesUpdated(allAddresses))
                    return events
                }

                emitAll(pendingEvents)
            }
        }

        serviceState.withLock { $0.isReserving = false }
    }

    // MARK: - Shutdown

    /// Shuts down the AutoRelay service and finishes the event stream.
    ///
    /// Clears active relays, candidates, and terminates the event stream.
    public func shutdown() {
        serviceState.withLock { state in
            state.isShutDown = true
            state.activeRelays.removeAll()
            state.candidates.removeAll()
        }

        eventState.withLock { state in
            state.continuation?.finish()
            state.continuation = nil
            state.stream = nil
        }
    }

    // MARK: - Private Helpers

    /// Emits a single event.
    private func emit(_ event: Event) {
        _ = eventState.withLock { state in
            state.continuation?.yield(event)
        }
    }

    /// Emits multiple events (collected outside a Mutex lock).
    private func emitAll(_ events: [Event]) {
        for event in events {
            emit(event)
        }
    }

    /// Builds p2p-circuit addresses from relay addresses.
    ///
    /// For each relay address, constructs an address of the form:
    /// `<relay-addr>/p2p/<relay-id>/p2p-circuit/p2p/<local-id>`
    ///
    /// - Parameters:
    ///   - relayPeer: The relay's peer ID.
    ///   - relayAddresses: The relay's network addresses.
    /// - Returns: Circuit relay addresses for advertisement.
    func buildCircuitAddresses(
        relayPeer: PeerID,
        relayAddresses: [Multiaddr]
    ) -> [Multiaddr] {
        var result: [Multiaddr] = []
        result.reserveCapacity(relayAddresses.count)

        for addr in relayAddresses {
            // Skip addresses that already contain p2p-circuit
            if addr.protocols.contains(where: { if case .p2pCircuit = $0 { return true } else { return false } }) {
                continue
            }

            // Build: <addr>/p2p/<relay>/p2p-circuit/p2p/<self>
            var protocols = addr.protocols

            // Only add /p2p/<relay> if not already present
            if addr.peerID != relayPeer {
                protocols.append(.p2p(relayPeer))
            }

            protocols.append(.p2pCircuit)
            protocols.append(.p2p(localPeer))

            // Use unchecked since we control the protocol count (typically 5-6)
            let circuitAddr = Multiaddr(uncheckedProtocols: protocols)
            result.append(circuitAddr)
        }

        return result
    }
}
