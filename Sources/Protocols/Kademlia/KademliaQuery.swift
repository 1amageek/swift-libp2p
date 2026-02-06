/// KademliaQuery - Iterative query engine for Kademlia DHT.

import Foundation
import P2PCore

/// The type of Kademlia query.
public enum KademliaQueryType: Sendable {
    /// Find nodes closest to a key.
    case findNode(KademliaKey)

    /// Get a value from the DHT.
    case getValue(Data)

    /// Get providers for content.
    case getProviders(Data)
}

/// The result of a Kademlia query.
public enum KademliaQueryResult: Sendable {
    /// Found nodes (for FIND_NODE).
    case nodes([KademliaPeer])

    /// Found a value (for GET_VALUE).
    case value(KademliaRecord, from: PeerID)

    /// Found nodes but no value (for GET_VALUE).
    case noValue([KademliaPeer])

    /// Found providers (for GET_PROVIDERS).
    case providers([KademliaPeer], closerPeers: [KademliaPeer])
}

/// Configuration for Kademlia queries.
public struct KademliaQueryConfig: Sendable {
    /// Number of peers to query in parallel.
    public var alpha: Int

    /// Number of peers to return.
    public var k: Int

    /// Query timeout.
    public var timeout: Duration

    /// Maximum query iterations.
    public var maxIterations: Int

    /// Creates query configuration.
    public init(
        alpha: Int = KademliaProtocol.alphaValue,
        k: Int = KademliaProtocol.kValue,
        timeout: Duration = KademliaProtocol.queryTimeout,
        maxIterations: Int = 20
    ) {
        self.alpha = alpha
        self.k = k
        self.timeout = timeout
        self.maxIterations = maxIterations
    }

    /// Default configuration.
    public static let `default` = KademliaQueryConfig()
}

/// State of a peer during a query.
public enum QueryPeerState: Sendable {
    /// Peer has not been contacted.
    case notContacted

    /// Waiting for response from peer.
    case waiting

    /// Received successful response.
    case succeeded

    /// Peer failed to respond or returned error.
    case failed
}

/// A peer being tracked during a query.
public struct QueryPeer: Sendable {
    /// The peer.
    public let peer: KademliaPeer

    /// Distance from the target.
    public let distance: KademliaKey

    /// Current state.
    public var state: QueryPeerState

    /// Creates a query peer.
    public init(peer: KademliaPeer, target: KademliaKey) {
        self.peer = peer
        self.distance = KademliaKey(from: peer.id).distance(to: target)
        self.state = .notContacted
    }
}

/// Delegate for executing queries.
public protocol KademliaQueryDelegate: Sendable {
    /// Sends a FIND_NODE request to a peer.
    func sendFindNode(to peer: PeerID, key: KademliaKey) async throws -> [KademliaPeer]

    /// Sends a GET_VALUE request to a peer.
    func sendGetValue(to peer: PeerID, key: Data) async throws -> (record: KademliaRecord?, closerPeers: [KademliaPeer])

    /// Sends a GET_PROVIDERS request to a peer.
    func sendGetProviders(to peer: PeerID, key: Data) async throws -> (providers: [KademliaPeer], closerPeers: [KademliaPeer])
}

/// Executes iterative Kademlia queries.
public struct KademliaQuery: Sendable {
    /// The query type.
    public let queryType: KademliaQueryType

    /// The target key.
    public let targetKey: KademliaKey

    /// Query configuration.
    public let config: KademliaQueryConfig

    /// Record validator for selecting the best record from multiple responses.
    public let validator: (any RecordValidator)?

    /// S/Kademlia configuration for sibling broadcast and disjoint paths.
    public let skademliaConfig: SKademliaConfig

    /// Creates a query.
    ///
    /// - Parameters:
    ///   - type: The query type.
    ///   - config: Query configuration.
    ///   - validator: Record validator for GET_VALUE selection (optional).
    ///   - skademliaConfig: S/Kademlia configuration (default: disabled).
    public init(
        type: KademliaQueryType,
        config: KademliaQueryConfig = .default,
        validator: (any RecordValidator)? = nil,
        skademliaConfig: SKademliaConfig = .disabled
    ) {
        self.queryType = type
        self.config = config
        self.validator = validator
        self.skademliaConfig = skademliaConfig

        switch type {
        case .findNode(let key):
            self.targetKey = key
        case .getValue(let key):
            self.targetKey = KademliaKey(hashing: key)
        case .getProviders(let key):
            self.targetKey = KademliaKey(hashing: key)
        }
    }

    /// Executes the query using the provided delegate.
    ///
    /// - Parameters:
    ///   - initialPeers: Initial peers to start the query from.
    ///   - delegate: Delegate for sending messages.
    /// - Returns: The query result.
    /// - Throws: `KademliaError.timeout` if the query exceeds the configured timeout.
    public func execute(
        initialPeers: [KademliaPeer],
        delegate: any KademliaQueryDelegate
    ) async throws -> KademliaQueryResult {
        guard !initialPeers.isEmpty else {
            throw KademliaError.noPeersAvailable
        }

        // Use disjoint paths if enabled
        if skademliaConfig.enabled && skademliaConfig.useDisjointPaths {
            return try await executeDisjointPaths(
                initialPeers: initialPeers,
                pathCount: skademliaConfig.disjointPathCount,
                delegate: delegate
            )
        }

        // Execute with timeout (single-path)
        return try await withThrowingTaskGroup(of: KademliaQueryResult?.self) { group in
            // Add the main query task
            group.addTask {
                try await self.executeInternal(initialPeers: initialPeers, delegate: delegate)
            }

            // Add timeout task
            group.addTask {
                try await Task.sleep(for: self.config.timeout)
                return nil // Timeout sentinel
            }

            // Wait for first completion
            for try await result in group {
                group.cancelAll() // Cancel remaining tasks
                if let queryResult = result {
                    return queryResult
                } else {
                    // Timeout occurred
                    throw KademliaError.timeout
                }
            }

            throw KademliaError.timeout
        }
    }

    // MARK: - Disjoint Paths

    /// Partitions peers into `pathCount` groups using round-robin on distance-sorted order.
    /// Ensures each path gets a mix of close and far peers.
    private func partitionPeers(
        _ peers: [KademliaPeer],
        pathCount: Int
    ) -> [[KademliaPeer]] {
        let sorted = peers.sorted { lhs, rhs in
            KademliaKey(from: lhs.id).distance(to: targetKey)
                < KademliaKey(from: rhs.id).distance(to: targetKey)
        }

        var partitions = Array(repeating: [KademliaPeer](), count: pathCount)
        for (index, peer) in sorted.enumerated() {
            partitions[index % pathCount].append(peer)
        }
        return partitions
    }

    /// Executes disjoint path queries in parallel, then merges results.
    private func executeDisjointPaths(
        initialPeers: [KademliaPeer],
        pathCount: Int,
        delegate: any KademliaQueryDelegate
    ) async throws -> KademliaQueryResult {
        let partitions = partitionPeers(initialPeers, pathCount: pathCount)
            .filter { !$0.isEmpty }

        guard !partitions.isEmpty else {
            throw KademliaError.noPeersAvailable
        }

        // Execute all paths in parallel with overall timeout
        return try await withThrowingTaskGroup(of: KademliaQueryResult?.self) { group in
            // Timeout task
            group.addTask {
                try await Task.sleep(for: self.config.timeout)
                return nil
            }

            // Main execution task
            group.addTask {
                let pathResults = await withTaskGroup(of: KademliaQueryResult?.self) { pathGroup in
                    for partition in partitions {
                        pathGroup.addTask {
                            do {
                                return try await self.executeInternal(
                                    initialPeers: partition,
                                    delegate: delegate
                                )
                            } catch {
                                return nil
                            }
                        }
                    }
                    var results: [KademliaQueryResult] = []
                    for await result in pathGroup {
                        if let r = result {
                            results.append(r)
                        }
                    }
                    return results
                }

                guard !pathResults.isEmpty else {
                    throw KademliaError.queryFailed("All disjoint paths failed")
                }

                return self.mergeResults(pathResults)
            }

            // Wait for first completion (query or timeout)
            for try await result in group {
                group.cancelAll()
                if let queryResult = result {
                    return queryResult
                } else {
                    throw KademliaError.timeout
                }
            }

            throw KademliaError.timeout
        }
    }

    /// Merges results from multiple disjoint path queries.
    private func mergeResults(_ results: [KademliaQueryResult]) -> KademliaQueryResult {
        switch queryType {
        case .findNode:
            // Deduplicate by PeerID, sort by distance, take top k
            var seen = Set<PeerID>()
            var allPeers: [KademliaPeer] = []
            for result in results {
                if case .nodes(let peers) = result {
                    for peer in peers where seen.insert(peer.id).inserted {
                        allPeers.append(peer)
                    }
                }
            }
            let sorted = allPeers.sorted { lhs, rhs in
                KademliaKey(from: lhs.id).distance(to: targetKey)
                    < KademliaKey(from: rhs.id).distance(to: targetKey)
            }
            return .nodes(Array(sorted.prefix(config.k)))

        case .getValue:
            // Collect all found records, pick best (first found if no validator)
            var allRecords: [(KademliaRecord, PeerID)] = []
            var allClosestPeers: [KademliaPeer] = []
            var seenPeerIDs = Set<PeerID>()
            for result in results {
                switch result {
                case .value(let record, let from):
                    allRecords.append((record, from))
                case .noValue(let peers):
                    for peer in peers where seenPeerIDs.insert(peer.id).inserted {
                        allClosestPeers.append(peer)
                    }
                default:
                    break
                }
            }
            if let first = allRecords.first {
                return .value(first.0, from: first.1)
            }
            return .noValue(Array(allClosestPeers.prefix(config.k)))

        case .getProviders:
            // Deduplicate providers
            var seenProviders = Set<PeerID>()
            var allProviders: [KademliaPeer] = []
            var seenCloser = Set<PeerID>()
            var allCloser: [KademliaPeer] = []
            for result in results {
                if case .providers(let providers, let closerPeers) = result {
                    for p in providers where seenProviders.insert(p.id).inserted {
                        allProviders.append(p)
                    }
                    for p in closerPeers where seenCloser.insert(p.id).inserted {
                        allCloser.append(p)
                    }
                }
            }
            return .providers(allProviders, closerPeers: Array(allCloser.prefix(config.k)))
        }
    }

    /// Internal query execution logic.
    private func executeInternal(
        initialPeers: [KademliaPeer],
        delegate: any KademliaQueryDelegate
    ) async throws -> KademliaQueryResult {
        // Track all peers seen during the query
        var seenPeers: [PeerID: QueryPeer] = [:]

        // Add initial peers
        for peer in initialPeers {
            let queryPeer = QueryPeer(peer: peer, target: targetKey)
            seenPeers[peer.id] = queryPeer
        }

        // For GET_VALUE, collect all records for selection
        var collectedRecords: [(record: KademliaRecord, from: PeerID)] = []
        var foundProviders: [KademliaPeer] = []

        // Iterative query loop
        for _ in 0..<config.maxIterations {
            // Check for cancellation (timeout)
            try Task.checkCancellation()
            // Select ALPHA closest not-contacted peers
            let candidates = selectCandidates(from: seenPeers, count: config.alpha)

            if candidates.isEmpty {
                // No more peers to query
                break
            }

            // Mark selected peers as waiting
            for peer in candidates {
                seenPeers[peer.peer.id]?.state = .waiting
            }

            // Query peers in parallel
            let results = await queryPeersParallel(candidates, delegate: delegate)

            // Process results
            for (peerID, result) in results {
                switch result {
                case .success(let response):
                    seenPeers[peerID]?.state = .succeeded

                    switch response {
                    case .findNode(let closerPeers):
                        // Add new peers
                        for newPeer in closerPeers {
                            if seenPeers[newPeer.id] == nil {
                                seenPeers[newPeer.id] = QueryPeer(peer: newPeer, target: targetKey)
                            }
                        }

                    case .getValue(let record, let closerPeers):
                        // Collect records for later selection
                        if let record = record {
                            collectedRecords.append((record, peerID))
                        }
                        // Add closer peers regardless
                        for newPeer in closerPeers {
                            if seenPeers[newPeer.id] == nil {
                                seenPeers[newPeer.id] = QueryPeer(peer: newPeer, target: targetKey)
                            }
                        }

                    case .getProviders(let providers, let closerPeers):
                        // Collect providers
                        for provider in providers {
                            if !foundProviders.contains(where: { $0.id == provider.id }) {
                                foundProviders.append(provider)
                            }
                        }
                        // Add closer peers
                        for newPeer in closerPeers {
                            if seenPeers[newPeer.id] == nil {
                                seenPeers[newPeer.id] = QueryPeer(peer: newPeer, target: targetKey)
                            }
                        }
                    }

                case .failure:
                    seenPeers[peerID]?.state = .failed
                }
            }

            // For GET_VALUE without a validator, return as soon as we have a record.
            // With a validator, continue collecting to select the best.
            if case .getValue = queryType, !collectedRecords.isEmpty, validator == nil {
                let found = collectedRecords[0]
                return .value(found.record, from: found.from)
            }
        }

        // Build final result
        let closestPeers = getClosestSucceeded(from: seenPeers, count: config.k)

        switch queryType {
        case .findNode:
            return .nodes(closestPeers)

        case .getValue:
            if !collectedRecords.isEmpty {
                let best = try await selectBestRecord(from: collectedRecords)
                return .value(best.record, from: best.from)
            }
            return .noValue(closestPeers)

        case .getProviders:
            return .providers(foundProviders, closerPeers: closestPeers)
        }
    }

    // MARK: - Private Helpers

    /// Selects the best record from collected responses using the validator.
    private func selectBestRecord(
        from collectedRecords: [(record: KademliaRecord, from: PeerID)]
    ) async throws -> (record: KademliaRecord, from: PeerID) {
        guard !collectedRecords.isEmpty else {
            throw KademliaError.recordNotFound
        }

        if let validator = validator, collectedRecords.count > 1 {
            let records = collectedRecords.map(\.record)
            let rawKey: Data
            switch queryType {
            case .getValue(let key):
                rawKey = key
            default:
                rawKey = records[0].key
            }
            let bestIndex = try await validator.select(key: rawKey, records: records)
            guard bestIndex >= 0, bestIndex < collectedRecords.count else {
                return collectedRecords[0]
            }
            return collectedRecords[bestIndex]
        }

        return collectedRecords[0]
    }

    private enum QueryResponse: Sendable {
        case findNode([KademliaPeer])
        case getValue(KademliaRecord?, [KademliaPeer])
        case getProviders([KademliaPeer], [KademliaPeer])
    }

    private func selectCandidates(
        from peers: [PeerID: QueryPeer],
        count: Int
    ) -> [QueryPeer] {
        let notContacted = Array(peers.values.filter { $0.state == .notContacted })

        guard skademliaConfig.enabled && skademliaConfig.useSiblingBroadcast else {
            return notContacted.smallest(count, by: { $0.distance < $1.distance })
        }

        // Sibling Broadcast: select alpha closest peers + additional peers from diverse distance bands
        let baseCandidates = notContacted.smallest(count, by: { $0.distance < $1.distance })
        let basePeerIDs = Set(baseCandidates.map { $0.peer.id })

        // Group remaining not-contacted peers by distance band (bucket index)
        let remaining = notContacted.filter { !basePeerIDs.contains($0.peer.id) }
        var bucketGroups: [Int: [QueryPeer]] = [:]
        for peer in remaining {
            if let bucketIdx = peer.distance.bucketIndex {
                bucketGroups[bucketIdx, default: []].append(peer)
            }
        }

        // Round-robin select from different distance bands for diversity
        let siblingCount = skademliaConfig.siblingCount
        var siblings: [QueryPeer] = []
        let sortedBuckets = bucketGroups.keys.sorted()
        var bucketOffsets = [Int: Int]()

        var added = 0
        var pass = 0
        while added < siblingCount && pass < remaining.count {
            for bucket in sortedBuckets {
                guard added < siblingCount else { break }
                let group = bucketGroups[bucket]!
                let offset = bucketOffsets[bucket, default: 0]
                if offset < group.count {
                    siblings.append(group[offset])
                    bucketOffsets[bucket] = offset + 1
                    added += 1
                }
            }
            pass += 1
        }

        return baseCandidates + siblings
    }

    private func getClosestSucceeded(
        from peers: [PeerID: QueryPeer],
        count: Int
    ) -> [KademliaPeer] {
        Array(peers.values.filter { $0.state == .succeeded })
            .smallest(count, by: { $0.distance < $1.distance })
            .map { $0.peer }
    }

    private func queryPeersParallel(
        _ peers: [QueryPeer],
        delegate: any KademliaQueryDelegate
    ) async -> [(PeerID, Result<QueryResponse, Error>)] {
        await withTaskGroup(of: (PeerID, Result<QueryResponse, Error>).self) { group in
            for queryPeer in peers {
                group.addTask {
                    let peerID = queryPeer.peer.id
                    do {
                        let response = try await self.querySinglePeer(
                            queryPeer.peer.id,
                            delegate: delegate
                        )
                        return (peerID, .success(response))
                    } catch {
                        return (peerID, .failure(error))
                    }
                }
            }

            var results: [(PeerID, Result<QueryResponse, Error>)] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
    }

    private func querySinglePeer(
        _ peerID: PeerID,
        delegate: any KademliaQueryDelegate
    ) async throws -> QueryResponse {
        switch queryType {
        case .findNode(let key):
            let peers = try await delegate.sendFindNode(to: peerID, key: key)
            return .findNode(peers)

        case .getValue(let key):
            let (record, closerPeers) = try await delegate.sendGetValue(to: peerID, key: key)
            return .getValue(record, closerPeers)

        case .getProviders(let key):
            let (providers, closerPeers) = try await delegate.sendGetProviders(to: peerID, key: key)
            return .getProviders(providers, closerPeers)
        }
    }
}
