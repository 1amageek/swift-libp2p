/// NATManager - Coordinates NAT traversal components.
///
/// Manages AutoNAT probing, port mapping, AutoRelay, and DCUtR upgrades.
/// EventEmitting pattern with single consumer (Node is the only consumer).

import Foundation
import Synchronization
import P2PCore
import P2PMux
import P2PAutoNAT
import P2PCircuitRelay
import P2PDCUtR
import P2PNAT
import P2PProtocols

/// Logger for NATManager operations.
private let natManagerLogger = Logger(label: "p2p.nat-manager")

// MARK: - Events

/// Events emitted by NATManager.
public enum NATManagerEvent: Sendable {
    /// NAT reachability status changed.
    case reachabilityChanged(NATStatus)

    /// Port mapping succeeded.
    case portMapped(PortMapping)

    /// Port mapping failed.
    case portMappingFailed(any Error)

    /// Relay addresses were updated.
    case relayAddressesUpdated([Multiaddr])

    /// DCUtR upgrade started for a peer.
    case dcutrUpgradeStarted(PeerID)

    /// DCUtR upgrade completed for a peer.
    case dcutrUpgradeCompleted(PeerID, success: Bool)
}

// MARK: - NATManager

/// Coordinates NAT traversal services:
/// 1. AutoNAT periodic probing → NAT status detection
/// 2. Port mapping via UPnP/NAT-PMP (optional)
/// 3. AutoRelay for relay address management
/// 4. DCUtR triggering for inbound relay connections
public final class NATManager: EventEmitting, Sendable {

    // MARK: - EventEmitting State

    private let eventState: Mutex<EventState>

    private struct EventState: Sendable {
        var stream: AsyncStream<NATManagerEvent>?
        var continuation: AsyncStream<NATManagerEvent>.Continuation?
    }

    // MARK: - Service State

    private let serviceState: Mutex<ServiceState>

    private struct ServiceState: Sendable {
        /// Current NAT status.
        var natStatus: NATStatus = .unknown

        /// Peers pending DCUtR upgrade (connected via relay, waiting for Identify).
        var dcutrPending: Set<PeerID> = []

        /// Background probe task.
        var probeTask: Task<Void, Never>?

        /// Whether the manager has been started.
        var isRunning: Bool = false

        /// Whether the manager has been shut down.
        var isShutDown: Bool = false
    }

    // MARK: - Injected Closures

    /// Dialer function injected by Node for DCUtR hole punching.
    private let _dialFn: Mutex<(@Sendable (Multiaddr) async throws -> Void)?>

    /// Local address provider injected by Node.
    private let _getLocalAddresses: Mutex<(@Sendable () -> [Multiaddr])?>

    // MARK: - Properties

    /// The NAT traversal configuration.
    public let config: NATTraversalConfiguration

    /// The local peer ID.
    public let localPeer: PeerID

    // MARK: - Events

    /// Stream of NATManager events (single consumer).
    public var events: AsyncStream<NATManagerEvent> {
        eventState.withLock { state in
            if let existing = state.stream { return existing }
            let (stream, continuation) = AsyncStream<NATManagerEvent>.makeStream()
            state.stream = stream
            state.continuation = continuation
            return stream
        }
    }

    // MARK: - Initialization

    /// Creates a new NATManager.
    ///
    /// - Parameters:
    ///   - config: NAT traversal configuration with service instances.
    ///   - localPeer: The local peer ID.
    public init(config: NATTraversalConfiguration, localPeer: PeerID) {
        self.config = config
        self.localPeer = localPeer
        self._dialFn = Mutex(nil)
        self._getLocalAddresses = Mutex(nil)
        self.eventState = Mutex(EventState())
        self.serviceState = Mutex(ServiceState())
    }

    // MARK: - Lifecycle

    /// Starts the NATManager.
    ///
    /// Registers protocol handlers, wires the dialer and address provider
    /// into DCUtR, and starts the AutoNAT probe loop.
    ///
    /// - Parameters:
    ///   - opener: Stream opener for protocol communication.
    ///   - registry: Handler registry for registering protocol handlers.
    ///   - localPeer: The local peer ID.
    ///   - getLocalAddresses: Closure returning current listen addresses.
    ///   - getPeers: Closure returning currently connected peers.
    ///   - dialFn: Closure that performs a direct dial to an address (for DCUtR hole punching).
    public func start(
        opener: any StreamOpener,
        registry: any HandlerRegistry,
        localPeer: PeerID,
        getLocalAddresses: @escaping @Sendable () -> [Multiaddr],
        getPeers: @escaping @Sendable () -> [PeerID],
        dialFn: @escaping @Sendable (Multiaddr) async throws -> Void
    ) async {
        let alreadyRunning = serviceState.withLock { state -> Bool in
            if state.isRunning || state.isShutDown { return true }
            state.isRunning = true
            return false
        }
        guard !alreadyRunning else { return }

        // Store closures for deferred use (handleReachabilityChange, handleIdentifyCompleted)
        _dialFn.withLock { $0 = dialFn }
        _getLocalAddresses.withLock { $0 = getLocalAddresses }

        // Wire DCUtR dialer and address provider
        if let dcutr = config.dcutr {
            dcutr.setDialer(dialFn)
            dcutr.setLocalAddressProvider(getLocalAddresses)
        }

        // Register AutoNAT handler
        if let autoNAT = config.autoNAT {
            await autoNAT.registerHandler(registry: registry)
        }

        // Register RelayClient handler
        if let relayClient = config.relayClient {
            await relayClient.registerHandler(registry: registry)
        }

        // Register RelayServer handler
        if let relayServer = config.relayServer {
            await relayServer.registerHandler(
                registry: registry,
                opener: opener,
                localPeer: localPeer,
                getLocalAddresses: getLocalAddresses
            )
        }

        // Register DCUtR handler
        if let dcutr = config.dcutr {
            await dcutr.registerHandler(registry: registry)
        }

        // Start AutoNAT probe loop
        if let autoNAT = config.autoNAT {
            let probeTask = Task { [weak self, config] in
                guard let self else { return }
                await self.runProbeLoop(
                    autoNAT: autoNAT,
                    opener: opener,
                    getPeers: getPeers,
                    probeInterval: config.probeInterval,
                    minPeers: config.minPeersForProbe
                )
            }
            serviceState.withLock { $0.probeTask = probeTask }
        }
    }

    /// Shuts down the NATManager and all managed services.
    public func shutdown() {
        let probeTask = serviceState.withLock { state -> Task<Void, Never>? in
            state.isShutDown = true
            state.isRunning = false
            state.dcutrPending.removeAll()
            let task = state.probeTask
            state.probeTask = nil
            return task
        }

        probeTask?.cancel()

        // Shutdown managed services
        config.autoNAT?.shutdown()
        config.relayClient?.shutdown()
        config.relayServer?.shutdown()
        config.autoRelay?.shutdown()
        config.dcutr?.shutdown()
        config.holePunch?.shutdown()
        config.portMapper?.shutdown()

        // Finish event stream
        eventState.withLock { state in
            state.continuation?.finish()
            state.continuation = nil
            state.stream = nil
        }
    }

    // MARK: - Peer Lifecycle Hooks

    /// Called when a peer connects. Tracks limited (relay) connections for DCUtR.
    ///
    /// - Parameters:
    ///   - peer: The connected peer.
    ///   - address: The connection address.
    ///   - isLimited: Whether this is a relay connection.
    public func handlePeerConnected(_ peer: PeerID, address: Multiaddr, isLimited: Bool) {
        guard config.enableHolePunching, isLimited else { return }
        guard config.dcutr != nil else { return }

        serviceState.withLock { state in
            guard !state.isShutDown else { return }
            state.dcutrPending.insert(peer)
        }
    }

    /// Called when Identify completes for a peer. Triggers DCUtR if pending.
    ///
    /// - Parameter peer: The identified peer.
    public func handleIdentifyCompleted(_ peer: PeerID, opener: any StreamOpener) {
        let shouldUpgrade = serviceState.withLock { state -> Bool in
            guard !state.isShutDown else { return false }
            return state.dcutrPending.remove(peer) != nil
        }

        guard shouldUpgrade, let dcutr = config.dcutr else { return }

        emit(.dcutrUpgradeStarted(peer))

        let storedDialFn = _dialFn.withLock { $0 }
        let dialFn: @Sendable (Multiaddr) async throws -> Void = storedDialFn ?? { _ in
            throw NATManagerError.dialerNotConfigured
        }

        Task { [weak self, config] in
            // Delay before DCUtR (allows connection to stabilize)
            do {
                try await Task.sleep(for: config.dcutrDelay)
            } catch {
                return
            }

            let success: Bool
            do {
                try await dcutr.upgradeToDirectConnection(
                    with: peer,
                    using: opener,
                    dialer: dialFn
                )
                success = true
            } catch {
                natManagerLogger.debug("DCUtR upgrade failed for \(peer): \(error)")
                success = false
            }

            self?.emit(.dcutrUpgradeCompleted(peer, success: success))
        }
    }

    /// Called when a peer disconnects.
    ///
    /// - Parameter peer: The disconnected peer.
    public func handlePeerDisconnected(_ peer: PeerID) {
        serviceState.withLock { state in
            _ = state.dcutrPending.remove(peer)
        }
    }

    // MARK: - Relay Address Query

    /// Returns the local node's relay addresses.
    ///
    /// These are addresses through which **this node** can be reached via relay
    /// (e.g., `/ip4/<relay>/tcp/<port>/p2p/<relay-id>/p2p-circuit/p2p/<local-id>`).
    /// Used for address advertisement via Identify Push.
    ///
    /// To reach a **remote** peer via relay, use addresses from the address book
    /// (populated when the remote peer advertises its relay addresses via Identify).
    ///
    /// - Returns: This node's relay addresses (empty if no relays active).
    public func relayAddresses() -> [Multiaddr] {
        guard let autoRelay = config.autoRelay else { return [] }
        return autoRelay.relayAddresses()
    }

    /// Returns the current NAT status.
    public var currentStatus: NATStatus {
        serviceState.withLock { $0.natStatus }
    }

    // MARK: - Private Implementation

    /// AutoNAT probe loop.
    private func runProbeLoop(
        autoNAT: AutoNATService,
        opener: any StreamOpener,
        getPeers: @escaping @Sendable () -> [PeerID],
        probeInterval: Duration,
        minPeers: Int
    ) async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: probeInterval)
            } catch {
                break
            }

            let isShutDown = serviceState.withLock { $0.isShutDown }
            guard !isShutDown else { break }

            let peers = getPeers()
            guard peers.count >= minPeers else { continue }

            // Select random subset of peers as probe servers
            let serverCount = min(6, peers.count)
            let servers = Array(peers.shuffled().prefix(serverCount))

            do {
                let status = try await autoNAT.probe(using: opener, servers: servers)
                let statusChanged = serviceState.withLock { state -> Bool in
                    if state.natStatus != status {
                        state.natStatus = status
                        return true
                    }
                    return false
                }

                if statusChanged {
                    emit(.reachabilityChanged(status))
                    await handleReachabilityChange(status, opener: opener)
                }
            } catch {
                natManagerLogger.debug("AutoNAT probe failed: \(error)")
            }
        }
    }

    /// Handles NAT reachability changes.
    private func handleReachabilityChange(_ status: NATStatus, opener: any StreamOpener) async {
        guard let autoRelay = config.autoRelay else { return }

        switch status {
        case .publicReachable:
            autoRelay.updateReachability(.publiclyReachable)

        case .privateBehindNAT:
            // 1. Attempt port mapping first (UPnP/NAT-PMP)
            if let portMapper = config.portMapper,
               let getAddresses = _getLocalAddresses.withLock({ $0 }) {
                let addresses = getAddresses()
                let ports = extractPorts(from: addresses)
                var mappingSucceeded = false

                for (port, proto) in ports {
                    do {
                        let mapping = try await portMapper.requestMapping(
                            internalPort: port,
                            protocol: proto
                        )
                        emit(.portMapped(mapping))
                        mappingSucceeded = true
                    } catch {
                        emit(.portMappingFailed(error))
                    }
                }

                if mappingSucceeded {
                    // Port mapping succeeded — we're now reachable, skip relay
                    autoRelay.updateReachability(.publiclyReachable)
                    return
                }
            }

            // 2. Port mapping failed or unavailable — fall back to relay
            autoRelay.updateReachability(.privateOnly)

            // Perform relay reservation cycle
            guard let relayClient = config.relayClient else { return }
            await autoRelay.performReservationCycle { [weak self] relayPeer, addresses in
                guard self != nil else { throw NATManagerError.shutdownInProgress }
                let reservation = try await relayClient.reserve(on: relayPeer, using: opener)
                return reservation.addresses
            }

            // Emit updated relay addresses
            let addresses = autoRelay.relayAddresses()
            if !addresses.isEmpty {
                emit(.relayAddressesUpdated(addresses))
            }

        case .unknown:
            autoRelay.updateReachability(.unknown)
        }
    }

    /// Extracts unique port/protocol pairs from listen addresses.
    private func extractPorts(from addresses: [Multiaddr]) -> [(UInt16, NATTransportProtocol)] {
        var seen = Set<String>()
        var result: [(UInt16, NATTransportProtocol)] = []
        for addr in addresses {
            if let port = addr.tcpPort {
                let key = "tcp:\(port)"
                if seen.insert(key).inserted { result.append((port, .tcp)) }
            }
            if let port = addr.udpPort {
                let key = "udp:\(port)"
                if seen.insert(key).inserted { result.append((port, .udp)) }
            }
        }
        return result
    }

    // MARK: - Event Emission

    private func emit(_ event: NATManagerEvent) {
        eventState.withLock { state in
            _ = state.continuation?.yield(event)
        }
    }
}

// MARK: - NATManagerError

/// Errors from NATManager.
public enum NATManagerError: Error, Sendable {
    /// The NATManager is shutting down.
    case shutdownInProgress

    /// The dialer function was not configured via start().
    case dialerNotConfigured
}
