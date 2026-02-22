/// AutoRelayService - Automatic relay discovery and reservation for NAT-traversed peers.
///
/// Monitors AutoNAT status and automatically makes relay reservations
/// when the local peer is behind NAT. Delegates state management and
/// circuit address construction to the existing `AutoRelay` class.

import Foundation
import Synchronization
import P2PCore
import P2PProtocols
import P2PAutoNAT
import P2PCircuitRelay

/// Logger for AutoRelayService operations.
private let autoRelayServiceLogger = Logger(label: "p2p.autorelay-service")

/// Automatic relay reservation service for NAT-traversed peers.
///
/// ## Overview
///
/// `AutoRelayService` bridges AutoNAT and Circuit Relay:
/// - Reads NAT status from `AutoNATService`
/// - Uses `RelayClient` to make reservations
/// - Delegates candidate/reservation state to `AutoRelay`
/// - Notifies the Node of relay address changes via callback
///
/// ## Usage
///
/// ```swift
/// let autoRelay = AutoRelayService(
///     autoNAT: autoNATService,
///     relayClient: relayClient,
///     localPeer: keyPair.peerID
/// )
/// // Add to Node's services array
/// ```
public final class AutoRelayService: EventEmitting, Sendable {

    // MARK: - Dependencies

    private let autoNAT: AutoNATService
    private let relayClient: RelayClient
    private let autoRelay: AutoRelay
    private let configuration: AutoRelayServiceConfiguration

    // MARK: - EventEmitting State

    private let channel = EventChannel<AutoRelayServiceEvent>()

    // MARK: - Service State

    private let serviceState: Mutex<ServiceState>

    private struct ServiceState: Sendable {
        var nodeContext: (any NodeContext)?
        var candidateFailures: [PeerID: CandidateFailureInfo] = [:]
        var connectedPeers: Set<PeerID> = []
        var isShutDown: Bool = false
        var wasActivated: Bool = false
    }

    private struct CandidateFailureInfo: Sendable {
        var count: Int = 0
        var lastFailureTime: ContinuousClock.Instant?
    }

    // MARK: - Background Task

    private let monitorTask: Mutex<Task<Void, Never>?>

    // MARK: - Relay Address Callback

    private let relayAddressCallback: Mutex<(@Sendable ([Multiaddr]) async -> Void)?>

    // MARK: - Events

    /// Stream of AutoRelayService events (single consumer).
    public var events: AsyncStream<AutoRelayServiceEvent> { channel.stream }

    // MARK: - Initialization

    /// Creates a new AutoRelayService.
    ///
    /// - Parameters:
    ///   - autoNAT: The AutoNAT service for NAT status detection.
    ///   - relayClient: The relay client for making reservations.
    ///   - localPeer: The local peer ID for circuit address construction.
    ///   - configuration: Service configuration.
    public init(
        autoNAT: AutoNATService,
        relayClient: RelayClient,
        localPeer: PeerID,
        configuration: AutoRelayServiceConfiguration = .init()
    ) {
        self.autoNAT = autoNAT
        self.relayClient = relayClient
        self.configuration = configuration
        self.autoRelay = AutoRelay(
            localPeer: localPeer,
            configuration: AutoRelayConfiguration(
                maxRelays: configuration.desiredRelays,
                refreshInterval: configuration.monitorInterval
            )
        )
        self.serviceState = Mutex(ServiceState())
        self.monitorTask = Mutex(nil)
        self.relayAddressCallback = Mutex(nil)

        // Register static relays as candidates
        for peer in configuration.staticRelays {
            autoRelay.addCandidateRelay(peer, addresses: [])
        }
    }

    // MARK: - Relay Address Callback

    /// Sets the callback invoked when relay addresses change.
    ///
    /// The Node uses this to include relay addresses in `listenAddresses()`.
    public func setRelayAddressCallback(
        _ callback: @escaping @Sendable ([Multiaddr]) async -> Void
    ) {
        relayAddressCallback.withLock { $0 = callback }
    }

    // MARK: - Monitoring

    private func startMonitoring() {
        let task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                let isShutDown = self.serviceState.withLock { $0.isShutDown }
                guard !isShutDown else { break }

                await self.monitorCycle()

                do {
                    try await Task.sleep(for: self.configuration.monitorInterval)
                } catch {
                    break
                }
            }
        }
        monitorTask.withLock { $0 = task }
    }

    private func monitorCycle() async {
        // 1. Read NAT status from AutoNAT
        let natStatus = autoNAT.status
        let reachability: AutoRelayReachability = switch natStatus {
        case .publicReachable: .publiclyReachable
        case .privateBehindNAT: .privateOnly
        case .unknown: .unknown
        }

        let previousReachability = autoRelay.currentReachability
        autoRelay.updateReachability(reachability)

        // 2. Track activation/deactivation
        if reachability == .privateOnly && previousReachability != .privateOnly {
            let shouldEmit = serviceState.withLock { state -> Bool in
                if !state.wasActivated {
                    state.wasActivated = true
                    return true
                }
                return false
            }
            if shouldEmit {
                emit(.activated)
            }
        } else if reachability != .privateOnly && previousReachability == .privateOnly {
            serviceState.withLock { $0.wasActivated = false }
            emit(.deactivated)
        }

        // 3. Public? Nothing to do (AutoRelay clears active relays)
        guard reachability == .privateOnly else {
            await notifyRelayAddressChange()
            return
        }

        // 4. Collect connected peers as candidates, rank via selector (single lock)
        if configuration.useConnectedPeers {
            let now = ContinuousClock.now
            let cooldown = configuration.failureCooldown
            let candidateInfos: [RelayCandidateInfo] = serviceState.withLock { state in
                var result: [RelayCandidateInfo] = []
                result.reserveCapacity(state.connectedPeers.count)
                for peer in state.connectedPeers {
                    if let info = state.candidateFailures[peer],
                       let lastFailure = info.lastFailureTime,
                       now - lastFailure < cooldown {
                        continue
                    }
                    // Reset failure tracking after cooldown expires.
                    // Without this, expired failures would permanently penalize
                    // the peer's score via normalizeFailures().
                    if state.candidateFailures[peer] != nil {
                        state.candidateFailures.removeValue(forKey: peer)
                    }
                    result.append(RelayCandidateInfo(
                        peer: peer, addresses: [], rtt: nil,
                        recentFailures: 0, supportsRelay: true
                    ))
                }
                return result
            }

            // 5. Rank eligible peers using the selector
            let ranked = configuration.selector.select(from: candidateInfos)
            for scored in ranked {
                autoRelay.addCandidateRelay(scored.peer, addresses: [])
                emit(.candidateAdded(scored.peer))
            }
        }

        // 6. Run reservation cycle if needed
        guard autoRelay.needsMoreRelays else { return }
        guard serviceState.withLock({ $0.nodeContext }) != nil else { return }

        await autoRelay.performReservationCycle { [relayClient, weak self] peer, _ in
            guard let self else { throw AutoRelayServiceError.serviceShutDown }
            guard let context = self.serviceState.withLock({ $0.nodeContext }) else {
                throw AutoRelayServiceError.serviceShutDown
            }
            do {
                let reservation = try await relayClient.reserve(on: peer, using: context)
                self.emit(.relayReserved(relay: peer, addresses: reservation.addresses))
                return reservation.addresses
            } catch {
                self.recordFailure(for: peer)
                self.emit(.reservationFailed(relay: peer, error: "\(error)"))
                throw error
            }
        }

        // 7. Notify relay address change
        await notifyRelayAddressChange()
    }

    private func notifyRelayAddressChange() async {
        let addresses = autoRelay.relayAddresses()
        emit(.relayAddressesUpdated(addresses))

        if let callback = relayAddressCallback.withLock({ $0 }) {
            await callback(addresses)
        }
    }

    private func triggerImmediateReservationCycle() {
        Task { [weak self] in
            guard let self else { return }
            await self.monitorCycle()
        }
    }

    // MARK: - Failure Tracking

    private func recordFailure(for peer: PeerID) {
        serviceState.withLock { state in
            var info = state.candidateFailures[peer] ?? CandidateFailureInfo()
            info.count += 1
            info.lastFailureTime = .now
            state.candidateFailures[peer] = info
        }
    }

    // MARK: - Event Emission

    private func emit(_ event: AutoRelayServiceEvent) {
        channel.yield(event)
    }

    // MARK: - Shutdown (EventEmitting)

    public func shutdown() async {
        monitorTask.withLock { t in t?.cancel(); t = nil }
        serviceState.withLock { $0.isShutDown = true }
        await autoRelay.shutdown()
        relayAddressCallback.withLock { $0 = nil }
        channel.finish()
    }
}

// MARK: - NodeService

extension AutoRelayService: NodeService {
    public func attach(to context: any NodeContext) async {
        serviceState.withLock { $0.nodeContext = context }
        startMonitoring()
    }
}

// MARK: - PeerObserver

extension AutoRelayService: PeerObserver {
    public func peerConnected(_ peer: PeerID) async {
        _ = serviceState.withLock { $0.connectedPeers.insert(peer) }
    }

    public func peerDisconnected(_ peer: PeerID) async {
        _ = serviceState.withLock { $0.connectedPeers.remove(peer) }

        // If this was an active relay, handle the loss
        if autoRelay.activeRelayPeers().contains(peer) {
            autoRelay.removeCandidateRelay(peer)
            emit(.relayLost(relay: peer))
            await notifyRelayAddressChange()
            triggerImmediateReservationCycle()
        }
    }
}
