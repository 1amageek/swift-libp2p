/// HeartbeatManager - Periodic maintenance for GossipSub
import Foundation
import P2PCore
import Synchronization

/// Manages periodic heartbeat operations for GossipSub.
///
/// The heartbeat performs:
/// 1. Mesh maintenance (GRAFT/PRUNE)
/// 2. Fanout cleanup
/// 3. Gossip emission (IHAVE)
/// 4. Message cache shifting
public final class HeartbeatManager: Sendable {

    // MARK: - Types

    /// Callback for sending control messages.
    public typealias SendCallback = @Sendable (PeerID, GossipSubRPC) async -> Void

    // MARK: - Properties

    /// The router to maintain.
    private let router: GossipSubRouter

    /// Configuration.
    private let configuration: GossipSubConfiguration

    /// Send callback.
    private let sendCallback: SendCallback

    /// Internal state.
    private let state: Mutex<HeartbeatState>

    private struct HeartbeatState: Sendable {
        var task: Task<Void, Never>?
        var isRunning: Bool = false
        var heartbeatCount: UInt64 = 0
    }

    // MARK: - Initialization

    /// Creates a new heartbeat manager.
    ///
    /// - Parameters:
    ///   - router: The GossipSub router
    ///   - configuration: Configuration parameters
    ///   - sendCallback: Callback for sending messages
    public init(
        router: GossipSubRouter,
        configuration: GossipSubConfiguration,
        sendCallback: @escaping SendCallback
    ) {
        self.router = router
        self.configuration = configuration
        self.sendCallback = sendCallback
        self.state = Mutex(HeartbeatState())
    }

    // MARK: - Lifecycle

    /// Starts the heartbeat.
    public func start() {
        state.withLock { state in
            guard !state.isRunning else { return }
            state.isRunning = true

            state.task = Task { [weak self] in
                await self?.heartbeatLoop()
            }
        }
    }

    /// Stops the heartbeat.
    public func stop() {
        state.withLock { state in
            state.isRunning = false
            state.task?.cancel()
            state.task = nil
        }
    }

    /// Whether the heartbeat is running.
    public var isRunning: Bool {
        state.withLock { $0.isRunning }
    }

    /// The number of heartbeats that have occurred.
    public var heartbeatCount: UInt64 {
        state.withLock { $0.heartbeatCount }
    }

    // MARK: - Heartbeat Loop

    private func heartbeatLoop() async {
        let interval = configuration.heartbeatInterval

        while !Task.isCancelled {
            // Wait for next heartbeat
            do {
                try await Task.sleep(for: interval)
            } catch {
                break // Cancelled
            }

            // Check if still running
            let shouldContinue = state.withLock { $0.isRunning }
            guard shouldContinue else { break }

            // Perform heartbeat
            await performHeartbeat()
        }
    }

    /// Performs a single heartbeat cycle.
    public func performHeartbeat() async {
        // Increment counter
        state.withLock { $0.heartbeatCount += 1 }

        var graftCount = 0
        var pruneCount = 0
        var gossipCount = 0

        // 1. Mesh maintenance
        let meshActions = router.maintainMesh()
        for (peer, control) in meshActions {
            graftCount += control.grafts.count
            pruneCount += control.prunes.count

            let rpc = GossipSubRPC(control: control)
            await sendCallback(peer, rpc)
        }

        // 2. Fanout cleanup
        router.cleanupFanout()

        // 3. Gossip emission (IHAVE)
        let gossipActions = router.generateGossip()
        for (peer, ihave) in gossipActions {
            gossipCount += 1

            var control = ControlMessageBatch()
            control.ihaves.append(ihave)
            let rpc = GossipSubRPC(control: control)
            await sendCallback(peer, rpc)
        }

        // 4. Shift message cache
        router.shiftMessageCache()

        // 5. Cleanup seen cache (less frequently)
        let count = state.withLock { $0.heartbeatCount }
        if count % 10 == 0 {  // Every 10 heartbeats
            router.cleanupSeenCache()
        }

        // 6. Cleanup expired backoffs
        router.cleanupBackoffs()

        // 7. Cleanup expired IDONTWANT entries (v1.2)
        router.cleanupIDontWants()

        // 8. Decay peer scores
        router.decayPeerScores()
    }
}

// MARK: - Heartbeat Statistics

/// Statistics from a heartbeat cycle.
public struct HeartbeatStats: Sendable {
    /// Number of GRAFT messages sent.
    public let grafts: Int

    /// Number of PRUNE messages sent.
    public let prunes: Int

    /// Number of gossip (IHAVE) messages sent.
    public let gossipSent: Int

    /// Total mesh peers across all topics.
    public let meshPeers: Int

    /// Duration of the heartbeat cycle.
    public let duration: Duration
}
