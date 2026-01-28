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

    /// Creates a query.
    ///
    /// - Parameters:
    ///   - type: The query type.
    ///   - config: Query configuration.
    public init(type: KademliaQueryType, config: KademliaQueryConfig = .default) {
        self.queryType = type
        self.config = config

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

        // Execute with timeout
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

        // For GET_VALUE and GET_PROVIDERS, track any found results
        var foundRecord: (record: KademliaRecord, from: PeerID)?
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
                        // If found a record, return immediately
                        if let record = record {
                            foundRecord = (record, peerID)
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

            // For GET_VALUE, return if we found the record
            if case .getValue = queryType, let found = foundRecord {
                return .value(found.record, from: found.from)
            }
        }

        // Build final result
        let closestPeers = getClosestSucceeded(from: seenPeers, count: config.k)

        switch queryType {
        case .findNode:
            return .nodes(closestPeers)

        case .getValue:
            if let found = foundRecord {
                return .value(found.record, from: found.from)
            }
            return .noValue(closestPeers)

        case .getProviders:
            return .providers(foundProviders, closerPeers: closestPeers)
        }
    }

    // MARK: - Private Helpers

    private enum QueryResponse: Sendable {
        case findNode([KademliaPeer])
        case getValue(KademliaRecord?, [KademliaPeer])
        case getProviders([KademliaPeer], [KademliaPeer])
    }

    private func selectCandidates(
        from peers: [PeerID: QueryPeer],
        count: Int
    ) -> [QueryPeer] {
        peers.values
            .filter { $0.state == .notContacted }
            .sorted { $0.distance < $1.distance }
            .prefix(count)
            .map { $0 }
    }

    private func getClosestSucceeded(
        from peers: [PeerID: QueryPeer],
        count: Int
    ) -> [KademliaPeer] {
        peers.values
            .filter { $0.state == .succeeded }
            .sorted { $0.distance < $1.distance }
            .prefix(count)
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
