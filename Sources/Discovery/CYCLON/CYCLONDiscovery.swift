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

    public let localPeerID: PeerID
    private let configuration: CYCLONConfiguration
    private let partialView: CYCLONPartialView
    private let logger: Logger

    private var localAddresses: [Multiaddr] = []
    private var streamOpener: (any StreamOpener)?
    private var shuffleTask: Task<Void, Never>?
    private var isStarted: Bool = false
    private var sequenceNumber: UInt64 = 0

    private nonisolated let broadcaster = EventBroadcaster<PeerObservation>()

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
    public func start(using opener: any StreamOpener) async {
        DiscoveryServiceOwnershipRegistry.preconditionAccessible(self)
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

    /// Shuts down the shuffle loop and cleans up.
    public func shutdown() async throws {
        DiscoveryServiceOwnershipRegistry.preconditionAccessible(self)
        guard isStarted else { return }
        shuffleTask?.cancel()
        shuffleTask = nil
        streamOpener = nil
        isStarted = false
        sequenceNumber = 0
        broadcaster.shutdown()
        logger.info("CYCLON stopped")
    }

    /// Seeds the partial view with initial peers.
    public func seed(peers: [(PeerID, [Multiaddr])]) {
        DiscoveryServiceOwnershipRegistry.preconditionAccessible(self)
        for (peerID, addresses) in peers {
            guard peerID != localPeerID else { continue }
            partialView.add(CYCLONEntry(peerID: peerID, addresses: addresses, age: 0))
        }
        logger.debug("Seeded \(peers.count) peers")
    }

    // MARK: - DiscoveryService

    public func announce(addresses: [Multiaddr]) async throws {
        DiscoveryServiceOwnershipRegistry.preconditionAccessible(self)
        self.localAddresses = addresses
    }

    public func find(peer: PeerID) async throws -> [ScoredCandidate] {
        DiscoveryServiceOwnershipRegistry.preconditionAccessible(self)
        guard let entry = partialView.entry(for: peer) else {
            return []
        }
        let score = ageToScore(entry.age)
        return [ScoredCandidate(peerID: entry.peerID, addresses: entry.addresses, score: score)]
    }

    public nonisolated func subscribe(to peer: PeerID) -> AsyncStream<PeerObservation> {
        DiscoveryServiceOwnershipRegistry.preconditionAccessible(self)
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

    public func collectKnownPeers() async -> [PeerID] {
        DiscoveryServiceOwnershipRegistry.preconditionAccessible(self)
        return partialView.allPeerIDs()
    }

    public nonisolated var observations: AsyncStream<PeerObservation> {
        DiscoveryServiceOwnershipRegistry.preconditionAccessible(self)
        return broadcaster.subscribe()
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

            let requestData = CYCLONProtobuf.encode(.shuffleRequest(entries: subset))
            try await stream.writeLengthPrefixedMessage(ByteBuffer(bytes: requestData))

            let responseBuffer = try await stream.readLengthPrefixedMessage(
                maxSize: 256 * 1024
            )
            let response = try CYCLONProtobuf.decode(Data(buffer: responseBuffer))

            // Close the stream inline and log any close failure instead of
            // dropping it in a fire-and-forget `defer { Task { ... } }`.
            do {
                try await stream.close()
            } catch {
                logger.debug("Failed to close shuffle stream", metadata: [
                    "target": "\(target.peerID)",
                    "error": "\(error)",
                ])
            }

            guard case .shuffleResponse(let rawEntries) = response else {
                throw CYCLONError.invalidMessage
            }

            // Cap and dedupe attacker-controlled input before merging: a remote
            // peer must not be able to push more than `shuffleLength` entries.
            let receivedEntries = sanitizeReceived(rawEntries)

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
            let requestBuffer = try await context.stream.readLengthPrefixedMessage(
                maxSize: 256 * 1024
            )
            let request = try CYCLONProtobuf.decode(Data(buffer: requestBuffer))

            guard case .shuffleRequest(let rawEntries) = request else {
                throw CYCLONError.invalidMessage
            }

            // Cap and dedupe attacker-controlled input before merging.
            let receivedEntries = sanitizeReceived(rawEntries)

            // Build response subset
            let responseSubset = partialView.randomSubset(
                count: configuration.shuffleLength,
                excluding: context.remotePeer
            )

            let responseData = CYCLONProtobuf.encode(
                .shuffleResponse(entries: responseSubset)
            )
            try await context.stream.writeLengthPrefixedMessage(ByteBuffer(bytes: responseData))
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

    // MARK: - Input Sanitization

    /// Caps and dedupes received shuffle entries before they touch the view.
    ///
    /// - removes our own ID (a peer must not insert us into our own view)
    /// - dedupes by peerID (keeps first occurrence)
    /// - caps the count to `shuffleLength` (a peer cannot flood our view)
    private func sanitizeReceived(_ entries: [CYCLONEntry]) -> [CYCLONEntry] {
        var seen = Set<PeerID>()
        var result: [CYCLONEntry] = []
        result.reserveCapacity(min(entries.count, configuration.shuffleLength))
        for entry in entries {
            guard entry.peerID != localPeerID else { continue }
            guard seen.insert(entry.peerID).inserted else { continue }
            result.append(entry)
            if result.count >= configuration.shuffleLength { break }
        }
        return result
    }

    // MARK: - Event Emission

    private func emitObservations(for entries: [CYCLONEntry]) {
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        for entry in entries {
            guard entry.peerID != localPeerID else { continue }
            sequenceNumber += 1
            let observation = PeerObservation(
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
        let observation = PeerObservation(
            subject: entry.peerID,
            observer: localPeerID,
            kind: .unreachable,
            hints: entry.addresses,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            sequenceNumber: sequenceNumber
        )
        broadcaster.emit(observation)
    }

    // MARK: - Scoring

    private func ageToScore(_ age: UInt64) -> Double {
        max(0.0, 1.0 - (Double(age) / Double(configuration.maxAge)))
    }
}

extension CYCLONDiscovery: StreamService, StreamOpeningActivatable {
    public nonisolated var protocolIDs: [String] {
        [cyclonProtocolID]
    }

    public func handleInboundStream(_ context: StreamContext) async {
        await handleIncomingStream(context: context)
    }

    public func activate(using opener: any StreamOpener) async {
        await start(using: opener)
    }

    // shutdown(): already defined as async method
}
