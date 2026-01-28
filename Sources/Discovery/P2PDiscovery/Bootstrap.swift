/// P2PDiscovery - Bootstrap
///
/// Provides bootstrap functionality for joining a P2P network.
/// Manages initial seed connections and automatic re-bootstrap.

import Foundation
import P2PCore
import Synchronization

// MARK: - Bootstrap Configuration

/// Configuration for the bootstrap service.
public struct BootstrapConfiguration: Sendable {

    /// Seed peers to connect to on bootstrap.
    public var seeds: [SeedPeer]

    /// Whether to automatically bootstrap when peer count is low.
    public var automaticBootstrap: Bool

    /// Interval between automatic bootstrap checks.
    public var bootstrapInterval: Duration

    /// Minimum number of connected peers before triggering bootstrap.
    public var minPeers: Int

    /// Maximum concurrent connection attempts during bootstrap.
    public var maxConcurrentDials: Int

    /// Timeout for individual connection attempts.
    public var dialTimeout: Duration

    /// Creates a configuration.
    public init(
        seeds: [SeedPeer] = [],
        automaticBootstrap: Bool = true,
        bootstrapInterval: Duration = .seconds(300),
        minPeers: Int = 3,
        maxConcurrentDials: Int = 5,
        dialTimeout: Duration = .seconds(30)
    ) {
        self.seeds = seeds
        self.automaticBootstrap = automaticBootstrap
        self.bootstrapInterval = bootstrapInterval
        self.minPeers = minPeers
        self.maxConcurrentDials = maxConcurrentDials
        self.dialTimeout = dialTimeout
    }

    /// Default configuration (no seeds).
    public static let `default` = BootstrapConfiguration()

    /// Creates a configuration with seed addresses.
    ///
    /// - Parameter seedAddresses: Array of (PeerID, Multiaddr) tuples.
    public static func withSeeds(_ seedAddresses: [(PeerID, Multiaddr)]) -> BootstrapConfiguration {
        BootstrapConfiguration(
            seeds: seedAddresses.map { SeedPeer(peerID: $0.0, address: $0.1) }
        )
    }
}

// MARK: - Seed Peer

/// A seed peer for bootstrap.
public struct SeedPeer: Sendable, Hashable {

    /// The peer ID of the seed.
    public let peerID: PeerID

    /// The address to connect to.
    public let address: Multiaddr

    /// Creates a seed peer.
    public init(peerID: PeerID, address: Multiaddr) {
        self.peerID = peerID
        self.address = address
    }
}

// MARK: - Bootstrap Result

/// Result of a bootstrap operation.
public struct BootstrapResult: Sendable {

    /// Peers that were successfully connected.
    public let connected: [PeerID]

    /// Peers that failed to connect with their error descriptions.
    public let failed: [(SeedPeer, String)]

    /// Whether bootstrap was successful (at least one connection).
    public var isSuccess: Bool {
        !connected.isEmpty
    }

    /// Total attempted connections.
    public var totalAttempted: Int {
        connected.count + failed.count
    }
}

// MARK: - Bootstrap Events

/// Events emitted by the bootstrap service.
public enum BootstrapEvent: Sendable {
    /// Bootstrap started.
    case started
    /// A seed peer connection succeeded.
    case seedConnected(PeerID)
    /// A seed peer connection failed.
    case seedFailed(SeedPeer, String)
    /// Bootstrap completed.
    case completed(BootstrapResult)
    /// Automatic bootstrap triggered.
    case autoBootstrapTriggered(currentPeerCount: Int)
}

// MARK: - Bootstrap Service Protocol

/// Protocol for bootstrap functionality.
public protocol BootstrapService: Sendable {

    /// Performs a bootstrap operation.
    ///
    /// Attempts to connect to all configured seed peers.
    ///
    /// - Returns: Result of the bootstrap operation.
    func bootstrap() async -> BootstrapResult

    /// Starts automatic bootstrap monitoring.
    ///
    /// Will periodically check peer count and trigger bootstrap
    /// if below the minimum threshold.
    func startAutoBootstrap() async

    /// Stops automatic bootstrap monitoring.
    func stopAutoBootstrap() async

    /// Whether automatic bootstrap is currently running.
    var isAutoBootstrapRunning: Bool { get async }

    /// Stream of bootstrap events.
    var events: AsyncStream<BootstrapEvent> { get }
}

// MARK: - Connection Provider

/// Protocol for providing connection functionality to bootstrap.
///
/// This allows bootstrap to work without a direct dependency on Node.
public protocol BootstrapConnectionProvider: Sendable {

    /// Attempts to connect to a peer at the given address.
    ///
    /// - Parameter address: The address to connect to.
    /// - Returns: The connected peer ID.
    func connect(to address: Multiaddr) async throws -> PeerID

    /// Returns the current number of connected peers.
    func connectedPeerCount() async -> Int

    /// Returns the set of currently connected peer IDs.
    func connectedPeers() async -> Set<PeerID>
}

// MARK: - Default Bootstrap Service

/// Default implementation of BootstrapService.
public actor DefaultBootstrap: BootstrapService {

    // MARK: - Properties

    private let configuration: BootstrapConfiguration
    private let connectionProvider: any BootstrapConnectionProvider
    private let peerStore: (any PeerStore)?

    private var autoBootstrapTask: Task<Void, Never>?
    private var _isAutoBootstrapRunning = false

    private nonisolated let broadcaster = EventBroadcaster<BootstrapEvent>()

    public nonisolated var events: AsyncStream<BootstrapEvent> {
        broadcaster.subscribe()
    }

    // MARK: - Initialization

    /// Creates a new bootstrap service.
    ///
    /// - Parameters:
    ///   - configuration: Bootstrap configuration.
    ///   - connectionProvider: Provider for connection functionality.
    ///   - peerStore: Optional peer store to record seed addresses.
    public init(
        configuration: BootstrapConfiguration,
        connectionProvider: any BootstrapConnectionProvider,
        peerStore: (any PeerStore)? = nil
    ) {
        self.configuration = configuration
        self.connectionProvider = connectionProvider
        self.peerStore = peerStore
    }

    deinit {
        autoBootstrapTask?.cancel()
        broadcaster.shutdown()
    }

    // MARK: - BootstrapService Protocol

    public var isAutoBootstrapRunning: Bool {
        _isAutoBootstrapRunning
    }

    public func bootstrap() async -> BootstrapResult {
        broadcaster.emit(.started)

        // Add seeds to peer store
        if let peerStore = peerStore {
            for seed in configuration.seeds {
                await peerStore.addAddress(seed.address, for: seed.peerID)
            }
        }

        // Filter out already-connected peers
        let connectedPeers = await connectionProvider.connectedPeers()
        let seedsToConnect = configuration.seeds.filter { !connectedPeers.contains($0.peerID) }

        guard !seedsToConnect.isEmpty else {
            // All seeds already connected
            let result = BootstrapResult(
                connected: configuration.seeds.map { $0.peerID },
                failed: []
            )
            broadcaster.emit(.completed(result))
            return result
        }

        // Connect to seeds with limited concurrency
        var connected: [PeerID] = []
        var failed: [(SeedPeer, String)] = []

        await withTaskGroup(of: (SeedPeer, Result<PeerID, Error>).self) { group in
            var pending = seedsToConnect[...]
            var active = 0

            // Add initial batch
            while active < configuration.maxConcurrentDials, let seed = pending.popFirst() {
                active += 1
                group.addTask {
                    await self.connectToSeed(seed)
                }
            }

            // Process results and add more
            for await (seed, result) in group {
                active -= 1

                switch result {
                case .success(let peerID):
                    connected.append(peerID)
                    broadcaster.emit(.seedConnected(peerID))

                case .failure(let error):
                    let errorDesc = String(describing: error)
                    failed.append((seed, errorDesc))
                    broadcaster.emit(.seedFailed(seed, errorDesc))
                }

                // Add next seed if available
                if let nextSeed = pending.popFirst() {
                    active += 1
                    group.addTask {
                        await self.connectToSeed(nextSeed)
                    }
                }
            }
        }

        let result = BootstrapResult(connected: connected, failed: failed)
        broadcaster.emit(.completed(result))

        return result
    }

    public func startAutoBootstrap() async {
        guard !_isAutoBootstrapRunning else { return }
        guard configuration.automaticBootstrap else { return }

        _isAutoBootstrapRunning = true

        autoBootstrapTask = Task { [weak self] in
            await self?.autoBootstrapLoop()
        }
    }

    public func stopAutoBootstrap() async {
        _isAutoBootstrapRunning = false
        autoBootstrapTask?.cancel()
        autoBootstrapTask = nil
    }

    // MARK: - Private Methods

    private func connectToSeed(_ seed: SeedPeer) async -> (SeedPeer, Result<PeerID, Error>) {
        do {
            let peerID = try await withTimeout(configuration.dialTimeout) {
                try await self.connectionProvider.connect(to: seed.address)
            }
            return (seed, .success(peerID))
        } catch {
            return (seed, .failure(error))
        }
    }

    private func autoBootstrapLoop() async {
        while _isAutoBootstrapRunning && !Task.isCancelled {
            // Check peer count
            let currentCount = await connectionProvider.connectedPeerCount()

            if currentCount < configuration.minPeers {
                broadcaster.emit(.autoBootstrapTriggered(currentPeerCount: currentCount))
                _ = await bootstrap()
            }

            // Wait for next check
            do {
                try await Task.sleep(for: configuration.bootstrapInterval)
            } catch {
                break
            }
        }
    }

    /// Executes a closure with a timeout.
    private func withTimeout<T: Sendable>(
        _ timeout: Duration,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }

            group.addTask {
                try await Task.sleep(for: timeout)
                throw BootstrapError.timeout
            }

            guard let result = try await group.next() else {
                throw BootstrapError.timeout
            }

            group.cancelAll()
            return result
        }
    }
}

// MARK: - Bootstrap Error

/// Errors that can occur during bootstrap.
public enum BootstrapError: Error, Sendable {
    /// Connection timed out.
    case timeout
    /// No seeds configured.
    case noSeeds
    /// All seed connections failed.
    case allSeedsFailed([String])
    /// Bootstrap already in progress.
    case alreadyInProgress
}

extension BootstrapError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .timeout:
            return "Bootstrap connection timed out"
        case .noSeeds:
            return "No seed peers configured"
        case .allSeedsFailed(let errors):
            return "All seed connections failed: \(errors.joined(separator: ", "))"
        case .alreadyInProgress:
            return "Bootstrap already in progress"
        }
    }
}
