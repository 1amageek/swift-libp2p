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

extension QueryPeer: Comparable {
    public static func < (lhs: QueryPeer, rhs: QueryPeer) -> Bool {
        if lhs.distance != rhs.distance {
            return lhs.distance < rhs.distance
        }
        return lhs.peer.id < rhs.peer.id
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

    /// Records latency for a peer (optional).
    func recordLatency(peer: PeerID, latency: Duration, success: Bool)
}

extension KademliaQueryDelegate {
    /// Default no-op implementation for backward compatibility.
    public func recordLatency(peer: PeerID, latency: Duration, success: Bool) {}
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

    /// The local peer ID, used to drop self from returned peer lists.
    /// `nil` if unknown (self is then only excluded by responder identity).
    public let localPeerID: PeerID?

    /// Creates a query.
    ///
    /// - Parameters:
    ///   - type: The query type.
    ///   - config: Query configuration.
    ///   - validator: Record validator for GET_VALUE selection (optional).
    ///   - skademliaConfig: S/Kademlia configuration (default: disabled).
    ///   - localPeerID: The local peer ID, to exclude self from results.
    public init(
        type: KademliaQueryType,
        config: KademliaQueryConfig = .default,
        validator: (any RecordValidator)? = nil,
        skademliaConfig: SKademliaConfig = .disabled,
        localPeerID: PeerID? = nil
    ) {
        self.queryType = type
        self.config = config
        self.validator = validator
        self.skademliaConfig = skademliaConfig
        self.localPeerID = localPeerID

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

        // The requested raw key (for GET_VALUE response key matching).
        let requestedKey: Data?
        if case .getValue(let key) = queryType {
            requestedKey = key
        } else {
            requestedKey = nil
        }

        // Convergence tracking: the distance of the closest peer we have *heard
        // back from*. A round that discovers no peer strictly closer than this
        // means we have converged and can stop early (rather than always running
        // maxIterations, which an adversary could otherwise steer).
        var closestRespondedDistance: KademliaKey?

        // Iterative query loop. `maxIterations` is only a safety cap.
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
            var discoveredCloser = false
            for (peerID, result) in results {
                switch result {
                case .success(let response):
                    seenPeers[peerID]?.state = .succeeded

                    // Update convergence tracker with this responder's distance.
                    let respDistance = KademliaKey(from: peerID).distance(to: targetKey)
                    if let best = closestRespondedDistance {
                        if respDistance < best { closestRespondedDistance = respDistance }
                    } else {
                        closestRespondedDistance = respDistance
                    }

                    switch response {
                    case .findNode(let closerPeers):
                        let accepted = acceptableCloserPeers(closerPeers, from: peerID, seenPeers: seenPeers)
                        for newPeer in accepted {
                            seenPeers[newPeer.id] = QueryPeer(peer: newPeer, target: targetKey)
                            discoveredCloser = true
                        }

                    case .getValue(let record, let closerPeers):
                        // Collect records for later selection, but only those
                        // whose key matches the requested key (defends against a
                        // responder returning a record for a different key).
                        if let record = record {
                            if let requestedKey, record.key != requestedKey {
                                // Mismatched key — ignore this record.
                            } else {
                                collectedRecords.append((record, peerID))
                            }
                        }
                        let accepted = acceptableCloserPeers(closerPeers, from: peerID, seenPeers: seenPeers)
                        for newPeer in accepted {
                            seenPeers[newPeer.id] = QueryPeer(peer: newPeer, target: targetKey)
                            discoveredCloser = true
                        }

                    case .getProviders(let providers, let closerPeers):
                        // Collect providers
                        for provider in providers {
                            if !foundProviders.contains(where: { $0.id == provider.id }) {
                                foundProviders.append(provider)
                            }
                        }
                        let accepted = acceptableCloserPeers(closerPeers, from: peerID, seenPeers: seenPeers)
                        for newPeer in accepted {
                            seenPeers[newPeer.id] = QueryPeer(peer: newPeer, target: targetKey)
                            discoveredCloser = true
                        }
                    }

                case .failure:
                    seenPeers[peerID]?.state = .failed
                }
            }

            // Convergence test: if this round discovered no peer strictly closer
            // than what we've already seen, and there are no closer un-contacted
            // peers remaining, the lookup has converged — stop early.
            if !discoveredCloser {
                let remaining = selectCandidates(from: seenPeers, count: config.alpha)
                let hasCloserRemaining: Bool
                if let best = closestRespondedDistance {
                    hasCloserRemaining = remaining.contains { $0.distance < best }
                } else {
                    hasCloserRemaining = !remaining.isEmpty
                }
                if !hasCloserRemaining {
                    break
                }
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

        // No custom validator: apply a default selection by majority/quorum
        // rather than blindly trusting the first responder. The value returned
        // by the most peers wins; ties break to the first occurrence.
        if collectedRecords.count > 1 {
            var counts: [Data: Int] = [:]
            for entry in collectedRecords {
                counts[entry.record.value, default: 0] += 1
            }
            var bestValue: Data?
            var bestCount = 0
            for entry in collectedRecords {
                let c = counts[entry.record.value] ?? 0
                if c > bestCount {
                    bestCount = c
                    bestValue = entry.record.value
                }
            }
            if let bestValue, let winner = collectedRecords.first(where: { $0.record.value == bestValue }) {
                return winner
            }
        }

        return collectedRecords[0]
    }

    /// Filters and bounds a list of closer peers returned by a responder.
    ///
    /// Hardening against eclipse/Sybil injection:
    /// - Caps the accepted count at `k` so a single response cannot inject a
    ///   huge peer list.
    /// - Drops self and the responder (they are not "closer peers").
    /// - Drops peers already seen (dedup).
    /// - Requires each new peer to be strictly closer to the target than the
    ///   responder; a responder must not be able to steer us toward arbitrary
    ///   far-away peers.
    private func acceptableCloserPeers(
        _ closerPeers: [KademliaPeer],
        from responder: PeerID,
        seenPeers: [PeerID: QueryPeer]
    ) -> [KademliaPeer] {
        let responderDistance = KademliaKey(from: responder).distance(to: targetKey)
        var accepted: [KademliaPeer] = []
        var localSeen = Set<PeerID>()

        for peer in closerPeers {
            if accepted.count >= config.k { break }
            // Drop self and the responder.
            if peer.id == responder { continue }
            if let local = localPeerID, peer.id == local { continue }
            // Dedup against already-known peers and within this batch.
            if seenPeers[peer.id] != nil { continue }
            if !localSeen.insert(peer.id).inserted { continue }
            // Require strictly-closer peers.
            let peerDistance = KademliaKey(from: peer.id).distance(to: targetKey)
            guard peerDistance < responderDistance else { continue }
            accepted.append(peer)
        }
        return accepted
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
            return notContacted.smallest(count)
        }

        // Sibling Broadcast: select alpha closest peers + additional peers from diverse distance bands
        let baseCandidates = notContacted.smallest(count)
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
            .smallest(count)
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
        let start = ContinuousClock.now
        do {
            let response: QueryResponse
            switch queryType {
            case .findNode(let key):
                let peers = try await delegate.sendFindNode(to: peerID, key: key)
                response = .findNode(peers)

            case .getValue(let key):
                let (record, closerPeers) = try await delegate.sendGetValue(to: peerID, key: key)
                response = .getValue(record, closerPeers)

            case .getProviders(let key):
                let (providers, closerPeers) = try await delegate.sendGetProviders(to: peerID, key: key)
                response = .getProviders(providers, closerPeers)
            }
            let elapsed = ContinuousClock.now - start
            delegate.recordLatency(peer: peerID, latency: elapsed, success: true)
            return response
        } catch {
            let elapsed = ContinuousClock.now - start
            delegate.recordLatency(peer: peerID, latency: elapsed, success: false)
            throw error
        }
    }
}
