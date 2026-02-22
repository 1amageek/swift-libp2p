/// SupernodeService - Automatic relay server activation for public nodes.
///
/// Evaluates whether the local node is eligible to serve as a relay
/// (public NAT status + sufficient connected peers) and controls
/// the RelayServer's reservation acceptance.

import Foundation
import Synchronization
import P2PCore
import P2PProtocols
import P2PAutoNAT
import P2PCircuitRelay

/// Logger for SupernodeService operations.
private let supernodeServiceLogger = Logger(label: "p2p.supernode-service")

/// Automatic relay server activation service.
///
/// ## Overview
///
/// `SupernodeService` periodically evaluates whether the local node
/// should serve as a relay for other peers:
/// - Checks NAT status via `AutoNATService`
/// - Checks connected peer count
/// - Activates/deactivates `RelayServer` reservation acceptance
///
/// ## Usage
///
/// ```swift
/// let supernode = SupernodeService(
///     autoNAT: autoNATService,
///     relayServer: relayServer,
///     configuration: .init(minConnectedPeers: 5)
/// )
/// // Add to Node's services array
/// ```
public final class SupernodeService: EventEmitting, Sendable {

    // MARK: - Dependencies

    private let autoNAT: AutoNATService
    private let relayServer: RelayServer
    private let configuration: SupernodeServiceConfiguration

    // MARK: - EventEmitting State

    private let channel = EventChannel<SupernodeServiceEvent>()

    // MARK: - Service State

    private let serviceState: Mutex<ServiceState>

    private struct ServiceState: Sendable {
        var connectedPeerCount: Int = 0
        var isRelayActive: Bool = false
        var isShutDown: Bool = false
    }

    // MARK: - Background Task

    private let evaluationTask: Mutex<Task<Void, Never>?>

    // MARK: - Events

    /// Stream of SupernodeService events (single consumer).
    public var events: AsyncStream<SupernodeServiceEvent> { channel.stream }

    // MARK: - Initialization

    /// Creates a new SupernodeService.
    ///
    /// - Parameters:
    ///   - autoNAT: The AutoNAT service for NAT status detection.
    ///   - relayServer: The relay server to control.
    ///   - configuration: Service configuration.
    public init(
        autoNAT: AutoNATService,
        relayServer: RelayServer,
        configuration: SupernodeServiceConfiguration = .init()
    ) {
        self.autoNAT = autoNAT
        self.relayServer = relayServer
        self.configuration = configuration
        self.serviceState = Mutex(ServiceState())
        self.evaluationTask = Mutex(nil)
    }

    // MARK: - Evaluation

    private func startEvaluation() {
        let task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                let isShutDown = self.serviceState.withLock { $0.isShutDown }
                guard !isShutDown else { break }

                self.evaluateEligibility()

                do {
                    try await Task.sleep(for: self.configuration.evaluationInterval)
                } catch {
                    break
                }
            }
        }
        evaluationTask.withLock { $0 = task }
    }

    private func evaluateEligibility() {
        var isEligible = true
        var reason = "eligible"

        // 1. NAT status check
        if configuration.requirePublicNAT && !autoNAT.status.isPublic {
            isEligible = false
            reason = "NAT status not public"
        }

        // 2. Connected peer count check
        if isEligible {
            let peerCount = serviceState.withLock { $0.connectedPeerCount }
            if peerCount < configuration.minConnectedPeers {
                isEligible = false
                reason = "insufficient peers (\(peerCount)/\(configuration.minConnectedPeers))"
            }
        }

        // 3. Activate/deactivate
        let pendingEvents: [SupernodeServiceEvent] = serviceState.withLock { state -> [SupernodeServiceEvent] in
            var events: [SupernodeServiceEvent] = []

            if isEligible && !state.isRelayActive {
                state.isRelayActive = true
                events.append(.relayActivated)
            } else if !isEligible && state.isRelayActive {
                state.isRelayActive = false
                events.append(.relayDeactivated(reason: reason))
            }

            events.append(.eligibilityEvaluated(isEligible: isEligible, reason: reason))
            return events
        }

        // Update RelayServer gating flag outside the lock
        relayServer.isAcceptingReservations = isEligible

        for event in pendingEvents {
            emit(event)
        }
    }

    // MARK: - Event Emission

    private func emit(_ event: SupernodeServiceEvent) {
        channel.yield(event)
    }

    // MARK: - Shutdown (EventEmitting)

    public func shutdown() async {
        evaluationTask.withLock { t in t?.cancel(); t = nil }
        serviceState.withLock { $0.isShutDown = true }
        channel.finish()
    }
}

// MARK: - NodeService

extension SupernodeService: NodeService {
    public func attach(to context: any NodeContext) async {
        startEvaluation()
    }
}

// MARK: - PeerObserver

extension SupernodeService: PeerObserver {
    public func peerConnected(_ peer: PeerID) async {
        serviceState.withLock { $0.connectedPeerCount += 1 }
    }

    public func peerDisconnected(_ peer: PeerID) async {
        serviceState.withLock { $0.connectedPeerCount = max(0, $0.connectedPeerCount - 1) }
    }
}
