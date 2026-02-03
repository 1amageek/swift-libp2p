/// CompositeDiscovery - Combines multiple discovery services
import Foundation
import P2PCore
import Synchronization

/// A discovery service that combines multiple underlying discovery services.
///
/// Results are merged and deduplicated by peer ID, with scores combined
/// using a weighted average based on each service's reliability.
///
/// ## Ownership and Lifecycle
///
/// - **Ownership**: CompositeDiscovery takes ownership of the provided services.
/// - **Exclusive Use**: Each service instance should only be used by one CompositeDiscovery.
/// - **No Direct Access**: Services should not be used directly after being added to CompositeDiscovery.
/// - **Explicit Cleanup**: `stop()` must be called before the instance is deallocated.
///
/// Example:
/// ```swift
/// let mdns = MDNSDiscovery(...)
/// let swim = SWIMMembership(...)
/// let composite = CompositeDiscovery(services: [mdns, swim])
///
/// await composite.start()
/// // ... use composite ...
/// await composite.stop()  // Required: stops internal services
/// ```
///
/// **Warning**: Do not share services between multiple CompositeDiscovery instances
/// or use services directly after adding them to CompositeDiscovery.
public final class CompositeDiscovery: DiscoveryService, Sendable {

    // MARK: - Properties

    private let services: [(service: any DiscoveryService, weight: Double)]
    private let state: Mutex<State>

    private struct State: Sendable {
        var sequenceNumber: UInt64 = 0
        var forwardingTasks: [Task<Void, Never>] = []
        var isRunning: Bool = false
        var isShutdown: Bool = false
    }

    private let broadcaster = EventBroadcaster<Observation>()

    // MARK: - Initialization

    /// Creates a composite discovery service.
    ///
    /// - Parameter services: Discovery services with their weights.
    ///   Weights are used when combining scores (higher = more trusted).
    public init(services: [(service: any DiscoveryService, weight: Double)]) {
        self.services = services
        self.state = Mutex(State())
    }

    /// Creates a composite discovery service with equal weights.
    ///
    /// - Parameter services: Discovery services to combine.
    public init(services: [any DiscoveryService]) {
        self.services = services.map { ($0, 1.0) }
        self.state = Mutex(State())
    }

    deinit {
        // Cancel any remaining tasks and finish continuation (only if not already shutdown)
        let shouldFinish = state.withLock { state -> Bool in
            guard !state.isShutdown else { return false }
            state.isShutdown = true
            for task in state.forwardingTasks {
                task.cancel()
            }
            state.forwardingTasks.removeAll()
            return true
        }
        if shouldFinish {
            broadcaster.shutdown()
        }
    }

    // MARK: - Lifecycle

    /// Starts forwarding events from all services.
    public func start() async {
        let alreadyRunning = state.withLock { state in
            if state.isRunning { return true }
            state.isRunning = true
            return false
        }
        guard !alreadyRunning else { return }

        for (service, _) in services {
            let task = Task { [weak self] in
                guard let self = self else { return }
                await self.forwardEvents(from: service)
            }
            state.withLock { state in
                state.forwardingTasks.append(task)
            }
        }
    }

    /// Stops forwarding events, cancels all tasks, and stops all internal services.
    ///
    /// This method performs cleanup in the following order:
    /// 1. Cancels all event forwarding tasks
    /// 2. Stops all internal discovery services (calls `stop()` on each)
    /// 3. Shuts down the event broadcaster
    ///
    /// This method is idempotent and safe to call multiple times.
    ///
    /// - Important: After calling `stop()`, the internal services will no longer
    ///   be usable, even if accessed directly from outside CompositeDiscovery.
    public func stop() async {
        let (tasks, servicesToStop) = state.withLock { state -> ([Task<Void, Never>], [(any DiscoveryService, Double)]) in
            guard !state.isShutdown else { return ([], []) }
            state.isShutdown = true

            let t = state.forwardingTasks
            state.forwardingTasks.removeAll()
            state.isRunning = false
            state.sequenceNumber = 0
            return (t, services)
        }

        // 1. Taskキャンセル
        for task in tasks {
            task.cancel()
        }

        // 2. 内部サービス停止
        for (service, _) in servicesToStop {
            await service.stop()
        }

        // 3. Broadcasterシャットダウン
        broadcaster.shutdown()
    }

    // MARK: - DiscoveryService Protocol

    /// Announces to all underlying services.
    ///
    /// Attempts to announce to every service, collecting errors.
    /// Throws only if all services fail.
    public func announce(addresses: [Multiaddr]) async throws {
        var errors: [Error] = []
        for (service, _) in services {
            do {
                try await service.announce(addresses: addresses)
            } catch {
                errors.append(error)
            }
        }
        if errors.count == services.count, let first = errors.first {
            throw first
        }
    }

    /// Finds candidates from all services and merges results.
    ///
    /// Collects results from all services, tolerating partial failures.
    /// Throws only if all services fail.
    public func find(peer: PeerID) async throws -> [ScoredCandidate] {
        let results = await withTaskGroup(
            of: Result<[(ScoredCandidate)], Error>.self
        ) { group in
            for (service, weight) in services {
                group.addTask {
                    do {
                        let candidates = try await service.find(peer: peer)
                        return .success(candidates.map { candidate in
                            ScoredCandidate(
                                peerID: candidate.peerID,
                                addresses: candidate.addresses,
                                score: candidate.score * weight
                            )
                        })
                    } catch {
                        return .failure(error)
                    }
                }
            }

            var allResults: [Result<[ScoredCandidate], Error>] = []
            for await result in group {
                allResults.append(result)
            }
            return allResults
        }

        var allCandidates: [ScoredCandidate] = []
        var errors: [Error] = []

        for result in results {
            switch result {
            case .success(let candidates):
                allCandidates.append(contentsOf: candidates)
            case .failure(let error):
                errors.append(error)
            }
        }

        if allCandidates.isEmpty, let first = errors.first {
            throw first
        }

        return mergeCandidates(allCandidates)
    }

    /// Subscribes to observations from all services.
    public func subscribe(to peer: PeerID) -> AsyncStream<Observation> {
        AsyncStream { continuation in
            Task { [weak self] in
                guard let self = self else {
                    continuation.finish()
                    return
                }

                for await observation in self.observations {
                    if observation.subject == peer {
                        continuation.yield(observation)
                    }
                }
                continuation.finish()
            }
        }
    }

    /// Returns known peers from all services.
    public func knownPeers() async -> [PeerID] {
        var allPeers = Set<PeerID>()

        for (service, _) in services {
            let peers = await service.knownPeers()
            allPeers.formUnion(peers)
        }

        return Array(allPeers)
    }

    /// Returns all observations as a stream.
    /// Each call returns an independent stream (multi-consumer safe).
    public var observations: AsyncStream<Observation> {
        broadcaster.subscribe()
    }

    // MARK: - Private Methods

    private func forwardEvents(from service: any DiscoveryService) async {
        for await observation in service.observations {
            // Check if task was cancelled
            guard !Task.isCancelled else { return }

            // Check if still running
            let isRunning = state.withLock { $0.isRunning }
            guard isRunning else { return }

            let newSeq = state.withLock { state in
                state.sequenceNumber += 1
                return state.sequenceNumber
            }
            // Re-emit with updated sequence number
            let forwarded = Observation(
                subject: observation.subject,
                observer: observation.observer,
                kind: observation.kind,
                hints: observation.hints,
                timestamp: observation.timestamp,
                sequenceNumber: newSeq
            )
            broadcaster.emit(forwarded)
        }
    }

    private func mergeCandidates(_ candidates: [ScoredCandidate]) -> [ScoredCandidate] {
        var byPeer: [PeerID: (addresses: Set<Multiaddr>, totalScore: Double, count: Int)] = [:]

        for candidate in candidates {
            if var existing = byPeer[candidate.peerID] {
                existing.addresses.formUnion(candidate.addresses)
                existing.totalScore += candidate.score
                existing.count += 1
                byPeer[candidate.peerID] = existing
            } else {
                byPeer[candidate.peerID] = (
                    addresses: Set(candidate.addresses),
                    totalScore: candidate.score,
                    count: 1
                )
            }
        }

        return byPeer.map { (peerID, data) in
            ScoredCandidate(
                peerID: peerID,
                addresses: Array(data.addresses),
                score: data.totalScore / Double(data.count)  // Weighted average
            )
        }.sorted { $0.score > $1.score }
    }
}
