/// CYCLON peer sampling protocol implementation.
///
/// Maintains a partial view of peers and periodically exchanges entries
/// with random peers to achieve uniform random sampling across the network.

import Foundation
import P2PCore
import P2PDiscovery
import P2PMux
import P2PProtocols
import Logging

/// The CYCLON protocol identifier.
public let cyclonProtocolID = "/cyclon/1.0.0"

/// CYCLON-based random peer sampling.
///
/// Conforms to `DiscoveryService` and uses the same actor + EventBroadcaster
/// pattern as `SWIMMembership` and `MDNSDiscovery`.
public actor CYCLONDiscovery: DiscoveryService {

    private let localPeerID: PeerID
    private let configuration: CYCLONConfiguration
    private let partialView: CYCLONPartialView
    private let logger: Logger

    private var localAddresses: [Multiaddr] = []
    private var streamOpener: (any StreamOpener)?
    private var shuffleTask: Task<Void, Never>?
    private var isStarted: Bool = false
    private var sequenceNumber: UInt64 = 0

    private nonisolated let broadcaster = EventBroadcaster<Observation>()

    // MARK: - Initialization

    public init(
        localPeerID: PeerID,
        configuration: CYCLONConfiguration = .default
    ) {
        self.localPeerID = localPeerID
        self.configuration = configuration
        self.partialView = CYCLONPartialView(cacheSize: configuration.cacheSize)
        self.logger = Logger(label: "p2p.discovery.cyclon")
    }

    deinit {
        broadcaster.shutdown()
    }

    // MARK: - Lifecycle

    /// Starts the CYCLON shuffle loop.
    ///
    /// - Parameter opener: Stream opener for communicating with peers
    public func start(using opener: any StreamOpener) {
        guard !isStarted else { return }
        self.streamOpener = opener
        self.isStarted = true
        self.shuffleTask = Task { [weak self] in
            await self?.shuffleLoop()
        }
        logger.info("CYCLON started", metadata: [
            "cacheSize": "\(configuration.cacheSize)",
            "shufflePeriod": "\(configuration.shufflePeriod)",
        ])
    }

    /// Stops the shuffle loop and cleans up.
    public func stop() {
        guard isStarted else { return }
        shuffleTask?.cancel()
        shuffleTask = nil
        streamOpener = nil
        isStarted = false
        broadcaster.shutdown()
        logger.info("CYCLON stopped")
    }

    /// Seeds the partial view with initial peers.
    public func seed(peers: [(PeerID, [Multiaddr])]) {
        for (peerID, addresses) in peers {
            guard peerID != localPeerID else { continue }
            partialView.add(CYCLONEntry(peerID: peerID, addresses: addresses, age: 0))
        }
        logger.debug("Seeded \(peers.count) peers")
    }

    /// Registers the shuffle request handler with the node.
    public func registerHandler(registry: any HandlerRegistry) async {
        await registry.handle(cyclonProtocolID) { [weak self] context in
            await self?.handleIncomingStream(context: context)
        }
    }

    // MARK: - DiscoveryService

    public func announce(addresses: [Multiaddr]) async throws {
        self.localAddresses = addresses
    }

    public func find(peer: PeerID) async throws -> [ScoredCandidate] {
        guard let entry = partialView.entry(for: peer) else {
            return []
        }
        let score = ageToScore(entry.age)
        return [ScoredCandidate(peerID: entry.peerID, addresses: entry.addresses, score: score)]
    }

    public nonisolated func subscribe(to peer: PeerID) -> AsyncStream<Observation> {
        let stream = broadcaster.subscribe()
        return AsyncStream { continuation in
            let task = Task {
                for await observation in stream {
                    if observation.subject == peer {
                        continuation.yield(observation)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    public func knownPeers() async -> [PeerID] {
        partialView.allPeerIDs()
    }

    public nonisolated var observations: AsyncStream<Observation> {
        broadcaster.subscribe()
    }

    // MARK: - Shuffle Loop

    private func shuffleLoop() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: configuration.shufflePeriod)
            } catch {
                break
            }
            guard !Task.isCancelled else { break }
            await performShuffle()
        }
    }

    private func performShuffle() async {
        // Step 1: Increment all ages
        partialView.incrementAges()

        // Step 2: Select oldest peer
        guard let target = partialView.oldest() else {
            return
        }

        guard let opener = streamOpener else {
            return
        }

        // Step 3: Build shuffle subset (self + random entries)
        var subset = partialView.randomSubset(
            count: configuration.shuffleLength - 1,
            excluding: target.peerID
        )
        // Include self entry
        let selfEntry = CYCLONEntry(
            peerID: localPeerID,
            addresses: localAddresses,
            age: 0
        )
        subset.insert(selfEntry, at: 0)

        // Step 4: Send shuffle request, receive response
        do {
            let stream = try await opener.newStream(
                to: target.peerID,
                protocol: cyclonProtocolID
            )
            defer { Task { try await stream.close() } }

            let requestData = CYCLONProtobuf.encode(.shuffleRequest(entries: subset))
            try await stream.writeLengthPrefixedMessage(requestData)

            let responseData = try await stream.readLengthPrefixedMessage(
                maxSize: 256 * 1024
            )
            let response = try CYCLONProtobuf.decode(responseData)

            guard case .shuffleResponse(let receivedEntries) = response else {
                throw CYCLONError.invalidMessage
            }

            // Step 5: Merge received entries
            partialView.merge(
                received: receivedEntries,
                sent: subset,
                selfID: localPeerID
            )

            // Emit observations for newly discovered peers
            emitObservations(for: receivedEntries)

            logger.trace("Shuffle complete", metadata: [
                "target": "\(target.peerID)",
                "sent": "\(subset.count)",
                "received": "\(receivedEntries.count)",
            ])

        } catch {
            logger.debug("Shuffle failed", metadata: [
                "target": "\(target.peerID)",
                "error": "\(error)",
            ])
            // Remove unreachable peer from view
            partialView.remove(target.peerID)
            emitUnreachable(target)
        }
    }

    // MARK: - Incoming Streams

    private func handleIncomingStream(context: StreamContext) async {
        do {
            let requestData = try await context.stream.readLengthPrefixedMessage(
                maxSize: 256 * 1024
            )
            let request = try CYCLONProtobuf.decode(requestData)

            guard case .shuffleRequest(let receivedEntries) = request else {
                throw CYCLONError.invalidMessage
            }

            // Build response subset
            let responseSubset = partialView.randomSubset(
                count: configuration.shuffleLength,
                excluding: context.remotePeer
            )

            let responseData = CYCLONProtobuf.encode(
                .shuffleResponse(entries: responseSubset)
            )
            try await context.stream.writeLengthPrefixedMessage(responseData)
            try await context.stream.close()

            // Merge received entries into our view
            partialView.merge(
                received: receivedEntries,
                sent: responseSubset,
                selfID: localPeerID
            )

            emitObservations(for: receivedEntries)

        } catch {
            logger.debug("Incoming shuffle failed", metadata: [
                "peer": "\(context.remotePeer)",
                "error": "\(error)",
            ])
        }
    }

    // MARK: - Event Emission

    private func emitObservations(for entries: [CYCLONEntry]) {
        let now = UInt64(Date().timeIntervalSince1970)
        for entry in entries {
            guard entry.peerID != localPeerID else { continue }
            sequenceNumber += 1
            let observation = Observation(
                subject: entry.peerID,
                observer: localPeerID,
                kind: .reachable,
                hints: entry.addresses,
                timestamp: now,
                sequenceNumber: sequenceNumber
            )
            broadcaster.emit(observation)
        }
    }

    private func emitUnreachable(_ entry: CYCLONEntry) {
        sequenceNumber += 1
        let observation = Observation(
            subject: entry.peerID,
            observer: localPeerID,
            kind: .unreachable,
            hints: entry.addresses,
            timestamp: UInt64(Date().timeIntervalSince1970),
            sequenceNumber: sequenceNumber
        )
        broadcaster.emit(observation)
    }

    // MARK: - Scoring

    private func ageToScore(_ age: UInt64) -> Double {
        max(0.0, 1.0 - (Double(age) / Double(configuration.maxAge)))
    }
}
