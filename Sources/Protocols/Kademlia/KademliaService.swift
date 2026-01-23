/// KademliaService - Kademlia DHT service for peer routing and content discovery.
///
/// Implements the Kademlia Distributed Hash Table protocol for:
/// - Peer routing (FIND_NODE)
/// - Content storage (GET_VALUE/PUT_VALUE)
/// - Content provider discovery (GET_PROVIDERS/ADD_PROVIDER)

import Foundation
import Synchronization
import P2PCore
import P2PMux
import P2PProtocols

/// Configuration for KademliaService.
public struct KademliaConfiguration: Sendable {
    /// K value (replication factor).
    public var kValue: Int

    /// Alpha value (parallelism factor).
    public var alphaValue: Int

    /// Maximum message size.
    public var maxMessageSize: Int

    /// Query timeout.
    public var queryTimeout: Duration

    /// Per-peer timeout for individual message exchanges.
    public var peerTimeout: Duration

    /// Record TTL.
    public var recordTTL: Duration

    /// Provider record TTL.
    public var providerTTL: Duration

    /// Record republish interval.
    public var recordRepublishInterval: Duration

    /// Provider republish interval.
    public var providerRepublishInterval: Duration

    /// Routing table refresh interval.
    public var refreshInterval: Duration

    /// Interval for automatic cleanup of expired records and providers.
    /// Set to nil to disable automatic cleanup.
    public var cleanupInterval: Duration?

    /// Operating mode.
    public var mode: KademliaMode

    // MARK: - Record Validation

    /// Record validator for incoming PUT_VALUE requests.
    ///
    /// By default, uses `DefaultRecordValidator` which limits key and value sizes
    /// to prevent DoS attacks. Set to a custom validator for application-specific
    /// validation, or `nil` to accept all records without validation (not recommended).
    public var recordValidator: (any RecordValidator)?

    /// Behavior when validation fails.
    public var onValidationFailure: ValidationFailureAction

    /// Action to take when record validation fails.
    public enum ValidationFailureAction: Sendable {
        /// Reject the record and throw an error.
        case reject

        /// Ignore the record and log a warning (don't store).
        case ignoreAndLog

        /// Accept the record anyway but emit a warning event.
        case acceptWithWarning
    }

    /// Creates a new configuration.
    public init(
        kValue: Int = KademliaProtocol.kValue,
        alphaValue: Int = KademliaProtocol.alphaValue,
        maxMessageSize: Int = KademliaProtocol.maxMessageSize,
        queryTimeout: Duration = KademliaProtocol.queryTimeout,
        peerTimeout: Duration = KademliaProtocol.requestTimeout,
        recordTTL: Duration = KademliaProtocol.recordTTL,
        providerTTL: Duration = KademliaProtocol.providerTTL,
        recordRepublishInterval: Duration = KademliaProtocol.recordRepublishInterval,
        providerRepublishInterval: Duration = KademliaProtocol.providerRepublishInterval,
        refreshInterval: Duration = KademliaProtocol.refreshInterval,
        cleanupInterval: Duration? = .seconds(300),
        mode: KademliaMode = .automatic,
        recordValidator: (any RecordValidator)? = DefaultRecordValidator(),
        onValidationFailure: ValidationFailureAction = .reject
    ) {
        self.kValue = kValue
        self.alphaValue = alphaValue
        self.maxMessageSize = maxMessageSize
        self.queryTimeout = queryTimeout
        self.peerTimeout = peerTimeout
        self.recordTTL = recordTTL
        self.providerTTL = providerTTL
        self.recordRepublishInterval = recordRepublishInterval
        self.providerRepublishInterval = providerRepublishInterval
        self.refreshInterval = refreshInterval
        self.cleanupInterval = cleanupInterval
        self.mode = mode
        self.recordValidator = recordValidator
        self.onValidationFailure = onValidationFailure
    }

    /// Default configuration.
    public static let `default` = KademliaConfiguration()
}

/// Kademlia DHT service.
///
/// ## Usage
///
/// ```swift
/// let kad = KademliaService(
///     localPeerID: myPeerID,
///     configuration: .default
/// )
/// await kad.registerHandler(registry: node)
///
/// // Add bootstrap peers
/// kad.addPeer(bootstrapPeer, addresses: [bootstrapAddr])
///
/// // Find a peer
/// let peers = try await kad.findNode(peerID, using: node)
///
/// // Store a value
/// try await kad.putValue(key: myKey, value: myValue, using: node)
///
/// // Get a value
/// let value = try await kad.getValue(key: myKey, using: node)
/// ```
public final class KademliaService: ProtocolService, EventEmitting, Sendable {

    // MARK: - ProtocolService

    public var protocolIDs: [String] {
        [KademliaProtocol.protocolID]
    }

    // MARK: - Properties

    /// The local peer ID.
    public let localPeerID: PeerID

    /// Service configuration.
    public let configuration: KademliaConfiguration

    /// The routing table.
    public let routingTable: RoutingTable

    /// The record store.
    public let recordStore: RecordStore

    /// The provider store.
    public let providerStore: ProviderStore

    /// Event state (dedicated).
    private let eventState: Mutex<EventState>

    private struct EventState: Sendable {
        var stream: AsyncStream<KademliaEvent>?
        var continuation: AsyncStream<KademliaEvent>.Continuation?
    }

    /// Service state (separated).
    private let serviceState: Mutex<ServiceState>

    private struct ServiceState: Sendable {
        var mode: KademliaMode
    }

    /// Background cleanup task.
    private let cleanupTask: Mutex<Task<Void, Never>?>

    // MARK: - Initialization

    /// Creates a new Kademlia service.
    ///
    /// - Parameters:
    ///   - localPeerID: The local peer's ID.
    ///   - configuration: Service configuration.
    public init(
        localPeerID: PeerID,
        configuration: KademliaConfiguration = .default
    ) {
        self.localPeerID = localPeerID
        self.configuration = configuration
        self.routingTable = RoutingTable(localPeerID: localPeerID, kValue: configuration.kValue)
        self.recordStore = RecordStore(defaultTTL: configuration.recordTTL)
        self.providerStore = ProviderStore(defaultTTL: configuration.providerTTL)
        self.eventState = Mutex(EventState())
        self.serviceState = Mutex(ServiceState(mode: configuration.mode))
        self.cleanupTask = Mutex(nil)
    }

    // MARK: - Events

    /// Stream of Kademlia events.
    public var events: AsyncStream<KademliaEvent> {
        eventState.withLock { state in
            if let existing = state.stream { return existing }
            let (stream, continuation) = AsyncStream<KademliaEvent>.makeStream()
            state.stream = stream
            state.continuation = continuation
            return stream
        }
    }

    private func emit(_ event: KademliaEvent) {
        _ = eventState.withLock { state in
            state.continuation?.yield(event)
        }
    }

    // MARK: - Shutdown

    /// Shuts down the service and finishes the event stream.
    ///
    /// Call this method when the service is no longer needed to properly
    /// terminate any consumers waiting on the `events` stream.
    public func shutdown() {
        stopMaintenance()
        eventState.withLock { state in
            state.continuation?.yield(.stopped)
            state.continuation?.finish()
            state.continuation = nil
            state.stream = nil
        }
    }

    // MARK: - Maintenance

    /// Starts the background maintenance task for cleaning up expired records.
    ///
    /// The maintenance task runs periodically based on `cleanupInterval` and removes:
    /// - Expired records from RecordStore
    /// - Expired providers from ProviderStore
    ///
    /// Call `stopMaintenance()` or `shutdown()` to stop the task.
    public func startMaintenance() {
        guard let interval = configuration.cleanupInterval else { return }

        cleanupTask.withLock { task in
            guard task == nil else { return }
            task = Task { [weak self] in
                await self?.runCleanupLoop(interval: interval)
            }
        }
    }

    /// Stops the background maintenance task.
    public func stopMaintenance() {
        cleanupTask.withLock { task in
            task?.cancel()
            task = nil
        }
    }

    /// Runs the cleanup loop.
    private func runCleanupLoop(interval: Duration) async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: interval)

                let recordsRemoved = recordStore.cleanup()
                let providersRemoved = providerStore.cleanup()

                if recordsRemoved > 0 || providersRemoved > 0 {
                    emit(.maintenanceCompleted(
                        recordsRemoved: recordsRemoved,
                        providersRemoved: providersRemoved
                    ))
                }
            } catch {
                // Task was cancelled
                break
            }
        }
    }

    // MARK: - Mode

    /// Current operating mode.
    public var mode: KademliaMode {
        serviceState.withLock { $0.mode }
    }

    /// Sets the operating mode.
    public func setMode(_ mode: KademliaMode) {
        serviceState.withLock { s in
            s.mode = mode
        }
        emit(.modeChanged(mode))
    }

    // MARK: - Peer Management

    /// Adds a peer to the routing table.
    ///
    /// - Parameters:
    ///   - peerID: The peer to add.
    ///   - addresses: Known addresses for the peer.
    /// - Returns: The result of the insertion.
    @discardableResult
    public func addPeer(_ peerID: PeerID, addresses: [Multiaddr] = []) -> KBucket.InsertResult {
        let result = routingTable.addPeer(peerID, addresses: addresses)

        if case .inserted = result {
            if let index = routingTable.bucketIndex(for: peerID) {
                emit(.peerAdded(peerID, bucket: index))
            }
        } else if case .updated = result {
            emit(.peerUpdated(peerID))
        }

        return result
    }

    /// Removes a peer from the routing table.
    ///
    /// - Parameter peerID: The peer to remove.
    @discardableResult
    public func removePeer(_ peerID: PeerID) -> Bool {
        if let _ = routingTable.removePeer(peerID) {
            if let index = routingTable.bucketIndex(for: peerID) {
                emit(.peerRemoved(peerID, bucket: index))
            }
            return true
        }
        return false
    }

    // MARK: - Handler Registration

    /// Registers the Kademlia protocol handler.
    ///
    /// - Parameter registry: The handler registry.
    public func registerHandler(registry: any HandlerRegistry) async {
        await registry.handle(KademliaProtocol.protocolID) { [weak self] context in
            await self?.handleStream(context)
        }
        emit(.started)
    }

    // MARK: - Stream Handling

    private func handleStream(_ context: StreamContext) async {
        // Add peer to routing table
        addPeer(context.remotePeer, addresses: [context.remoteAddress])

        do {
            // Apply per-peer timeout to server-side processing to prevent DoS
            let stream = context.stream
            let maxMessageSize = configuration.maxMessageSize

            // Read with per-peer timeout
            let data = try await withPeerTimeout {
                try await stream.readLengthPrefixedMessage(maxSize: UInt64(maxMessageSize))
            }

            guard data.count <= maxMessageSize else {
                try? await stream.close()
                return
            }

            let message = try KademliaProtobuf.decode(data)
            let response = try await handleMessage(message, from: context.remotePeer)

            // Write response with per-peer timeout
            let responseData = KademliaProtobuf.encode(response)
            try await withPeerTimeout {
                try await stream.writeLengthPrefixedMessage(responseData)
            }

        } catch {
            // Timeout or error - close stream silently
        }

        try? await context.stream.close()
    }

    private func handleMessage(_ message: KademliaMessage, from peer: PeerID) async throws -> KademliaMessage {
        switch message.type {
        case .findNode:
            emit(.requestReceived(from: peer, type: .findNode))
            guard let key = message.key else {
                throw KademliaError.protocolViolation("Missing key in FIND_NODE")
            }
            let targetKey: KademliaKey
            do {
                targetKey = try KademliaKey(validating: key)
            } catch {
                throw KademliaError.protocolViolation("Invalid key length in FIND_NODE: expected 32 bytes, got \(key.count)")
            }
            let closerPeers = routingTable.closestPeers(to: targetKey, excluding: [peer])
                .map { KademliaPeer(id: $0.peerID, addresses: $0.addresses) }
            emit(.responseSent(to: peer, type: .findNode))
            return .findNodeResponse(closerPeers: closerPeers)

        case .getValue:
            emit(.requestReceived(from: peer, type: .getValue))
            guard let key = message.key else {
                throw KademliaError.protocolViolation("Missing key in GET_VALUE")
            }
            // Check local store first
            if let record = recordStore.get(key) {
                emit(.responseSent(to: peer, type: .getValue))
                return .getValueResponse(record: record, closerPeers: [])
            }
            // Return closer peers
            let targetKey = KademliaKey(hashing: key)
            let closerPeers = routingTable.closestPeers(to: targetKey, excluding: [peer])
                .map { KademliaPeer(id: $0.peerID, addresses: $0.addresses) }
            emit(.responseSent(to: peer, type: .getValue))
            return .getValueResponse(record: nil, closerPeers: closerPeers)

        case .putValue:
            emit(.requestReceived(from: peer, type: .putValue))
            guard let record = message.record else {
                throw KademliaError.protocolViolation("Missing record in PUT_VALUE")
            }

            // Validate the record if a validator is configured
            if let validator = configuration.recordValidator {
                let validationResult = await validateRecord(record: record, from: peer, validator: validator)

                switch validationResult {
                case .accepted:
                    break  // Continue to store

                case .rejected(let reason):
                    emit(.recordRejected(key: record.key, from: peer, reason: reason))

                    switch configuration.onValidationFailure {
                    case .reject:
                        throw KademliaError.invalidRecord("Validation failed: \(reason)")

                    case .ignoreAndLog:
                        // Don't store, but return success to avoid protocol issues
                        emit(.responseSent(to: peer, type: .putValue))
                        return .putValueResponse(record: record)

                    case .acceptWithWarning:
                        // Store anyway, warning already emitted via recordRejected
                        break
                    }
                }
            }

            // Store the record
            recordStore.put(record)
            emit(.recordStored(key: record.key))
            emit(.responseSent(to: peer, type: .putValue))
            return .putValueResponse(record: record)

        case .getProviders:
            emit(.requestReceived(from: peer, type: .getProviders))
            guard let key = message.key else {
                throw KademliaError.protocolViolation("Missing key in GET_PROVIDERS")
            }
            let providers = providerStore.getProviders(for: key)
                .map { KademliaPeer(id: $0.peerID, addresses: $0.addresses) }
            let targetKey = KademliaKey(hashing: key)
            let closerPeers = routingTable.closestPeers(to: targetKey, excluding: [peer])
                .map { KademliaPeer(id: $0.peerID, addresses: $0.addresses) }
            emit(.responseSent(to: peer, type: .getProviders))
            return .getProvidersResponse(providers: providers, closerPeers: closerPeers)

        case .addProvider:
            emit(.requestReceived(from: peer, type: .addProvider))
            guard let key = message.key else {
                throw KademliaError.protocolViolation("Missing key in ADD_PROVIDER")
            }
            // Add provider records
            for provider in message.providerPeers {
                providerStore.addProvider(for: key, peerID: provider.id, addresses: provider.addresses)
            }
            emit(.responseSent(to: peer, type: .addProvider))
            // ADD_PROVIDER doesn't have a response in the spec, but we return an empty response
            return .getProvidersResponse(providers: [], closerPeers: [])

        case .ping:
            throw KademliaError.protocolViolation("PING is deprecated")
        }
    }

    // MARK: - Record Validation

    /// Result of record validation.
    private enum ValidationResult {
        case accepted
        case rejected(RecordRejectionReason)
    }

    /// Validates a record using the configured validator.
    ///
    /// - Parameters:
    ///   - record: The record to validate.
    ///   - from: The peer that sent the record.
    ///   - validator: The validator to use.
    /// - Returns: The validation result.
    private func validateRecord(
        record: KademliaRecord,
        from: PeerID,
        validator: any RecordValidator
    ) async -> ValidationResult {
        do {
            let isValid = try await validator.validate(record: record, from: from)
            if isValid {
                return .accepted
            } else {
                return .rejected(.validationFailed)
            }
        } catch {
            return .rejected(.validationError(String(describing: error)))
        }
    }

    // MARK: - Query Operations

    /// Finds the closest peers to a target.
    ///
    /// - Parameters:
    ///   - target: The target peer ID.
    ///   - opener: Stream opener for sending requests.
    /// - Returns: The closest peers found.
    public func findNode(_ target: PeerID, using opener: any StreamOpener) async throws -> [KademliaPeer] {
        let targetKey = KademliaKey(from: target)
        return try await findNode(targetKey, using: opener)
    }

    /// Finds the closest peers to a target key.
    ///
    /// - Parameters:
    ///   - targetKey: The target Kademlia key.
    ///   - opener: Stream opener for sending requests.
    /// - Returns: The closest peers found.
    public func findNode(_ targetKey: KademliaKey, using opener: any StreamOpener) async throws -> [KademliaPeer] {
        let queryInfo = QueryInfo(type: .findNode, targetKey: targetKey)
        emit(.queryStarted(queryInfo))

        let initialPeers = routingTable.closestPeers(to: targetKey)
            .map { KademliaPeer(id: $0.peerID, addresses: $0.addresses) }

        guard !initialPeers.isEmpty else {
            emit(.queryFailed(queryInfo, error: "No peers available"))
            throw KademliaError.noPeersAvailable
        }

        let query = KademliaQuery(
            type: .findNode(targetKey),
            config: KademliaQueryConfig(
                alpha: configuration.alphaValue,
                k: configuration.kValue,
                timeout: configuration.queryTimeout
            )
        )

        let delegate = QueryDelegateImpl(service: self, opener: opener)

        do {
            let result = try await query.execute(initialPeers: initialPeers, delegate: delegate)

            switch result {
            case .nodes(let peers):
                // Add found peers to routing table
                for peer in peers {
                    addPeer(peer.id, addresses: peer.addresses)
                }
                emit(.querySucceeded(queryInfo, result: .peers(count: peers.count)))
                return peers
            default:
                emit(.queryFailed(queryInfo, error: "Unexpected result type"))
                throw KademliaError.queryFailed("Unexpected result type")
            }
        } catch {
            emit(.queryFailed(queryInfo, error: error.localizedDescription))
            throw error
        }
    }

    /// Gets a value from the DHT.
    ///
    /// - Parameters:
    ///   - key: The record key.
    ///   - opener: Stream opener for sending requests.
    /// - Returns: The record if found.
    public func getValue(key: Data, using opener: any StreamOpener) async throws -> KademliaRecord {
        // Check local store first
        if let record = recordStore.get(key) {
            emit(.recordRetrieved(key: key, from: nil))
            return record
        }

        let targetKey = KademliaKey(hashing: key)
        let queryInfo = QueryInfo(type: .getValue, targetKey: targetKey)
        emit(.queryStarted(queryInfo))

        let initialPeers = routingTable.closestPeers(to: targetKey)
            .map { KademliaPeer(id: $0.peerID, addresses: $0.addresses) }

        guard !initialPeers.isEmpty else {
            emit(.queryFailed(queryInfo, error: "No peers available"))
            throw KademliaError.noPeersAvailable
        }

        let query = KademliaQuery(
            type: .getValue(key),
            config: KademliaQueryConfig(
                alpha: configuration.alphaValue,
                k: configuration.kValue,
                timeout: configuration.queryTimeout
            )
        )

        let delegate = QueryDelegateImpl(service: self, opener: opener)

        do {
            let result = try await query.execute(initialPeers: initialPeers, delegate: delegate)

            switch result {
            case .value(let record, let from):
                // Cache locally
                recordStore.put(record)
                emit(.recordRetrieved(key: key, from: from))
                emit(.querySucceeded(queryInfo, result: .value(from: from)))
                return record
            case .noValue(let closerPeers):
                emit(.recordNotFound(key: key))
                emit(.querySucceeded(queryInfo, result: .noValue(closestPeers: closerPeers.count)))
                throw KademliaError.recordNotFound
            default:
                emit(.queryFailed(queryInfo, error: "Unexpected result type"))
                throw KademliaError.queryFailed("Unexpected result type")
            }
        } catch {
            emit(.queryFailed(queryInfo, error: error.localizedDescription))
            throw error
        }
    }

    /// Stores a value in the DHT.
    ///
    /// - Parameters:
    ///   - key: The record key.
    ///   - value: The record value.
    ///   - opener: Stream opener for sending requests.
    /// - Returns: Number of peers the value was stored on.
    @discardableResult
    public func putValue(key: Data, value: Data, using opener: any StreamOpener) async throws -> Int {
        let record = KademliaRecord.create(key: key, value: value)

        // Store locally
        recordStore.put(record)
        emit(.recordStored(key: key))

        let targetKey = KademliaKey(hashing: key)
        let queryInfo = QueryInfo(type: .putValue, targetKey: targetKey)
        emit(.queryStarted(queryInfo))

        // Find closest peers
        let closestPeers = try await findNode(targetKey, using: opener)

        // Store on closest peers in parallel
        let storedCount = await storeOnPeers(record: record, peers: closestPeers, opener: opener)

        emit(.querySucceeded(queryInfo, result: .stored(toPeers: storedCount)))
        return storedCount
    }

    /// Gets providers for content.
    ///
    /// - Parameters:
    ///   - key: The content key.
    ///   - opener: Stream opener for sending requests.
    /// - Returns: The providers found.
    public func getProviders(for key: Data, using opener: any StreamOpener) async throws -> [KademliaPeer] {
        let targetKey = KademliaKey(hashing: key)
        let queryInfo = QueryInfo(type: .getProviders, targetKey: targetKey)
        emit(.queryStarted(queryInfo))

        // Check local store first
        let localProviders = providerStore.getProviders(for: key)
            .map { KademliaPeer(id: $0.peerID, addresses: $0.addresses) }

        let initialPeers = routingTable.closestPeers(to: targetKey)
            .map { KademliaPeer(id: $0.peerID, addresses: $0.addresses) }

        guard !initialPeers.isEmpty else {
            if !localProviders.isEmpty {
                emit(.providersFound(key: key, count: localProviders.count))
                emit(.querySucceeded(queryInfo, result: .providers(count: localProviders.count, closestPeers: 0)))
                return localProviders
            }
            emit(.queryFailed(queryInfo, error: "No peers available"))
            throw KademliaError.noPeersAvailable
        }

        let query = KademliaQuery(
            type: .getProviders(key),
            config: KademliaQueryConfig(
                alpha: configuration.alphaValue,
                k: configuration.kValue,
                timeout: configuration.queryTimeout
            )
        )

        let delegate = QueryDelegateImpl(service: self, opener: opener)

        do {
            let result = try await query.execute(initialPeers: initialPeers, delegate: delegate)

            switch result {
            case .providers(var providers, let closerPeers):
                // Merge with local providers
                for local in localProviders {
                    if !providers.contains(where: { $0.id == local.id }) {
                        providers.append(local)
                    }
                }
                emit(.providersFound(key: key, count: providers.count))
                emit(.querySucceeded(queryInfo, result: .providers(count: providers.count, closestPeers: closerPeers.count)))
                return providers
            default:
                emit(.queryFailed(queryInfo, error: "Unexpected result type"))
                throw KademliaError.queryFailed("Unexpected result type")
            }
        } catch {
            emit(.queryFailed(queryInfo, error: error.localizedDescription))
            throw error
        }
    }

    /// Announces as a provider for content.
    ///
    /// - Parameters:
    ///   - key: The content key.
    ///   - addresses: Local addresses to announce.
    ///   - opener: Stream opener for sending requests.
    /// - Returns: Number of peers the announcement was sent to.
    @discardableResult
    public func provide(key: Data, addresses: [Multiaddr], using opener: any StreamOpener) async throws -> Int {
        // Store locally
        providerStore.addProvider(for: key, peerID: localPeerID, addresses: addresses)
        emit(.providerAdded(key: key))

        let targetKey = KademliaKey(hashing: key)
        let queryInfo = QueryInfo(type: .addProvider, targetKey: targetKey)
        emit(.queryStarted(queryInfo))

        // Find closest peers
        let closestPeers = try await findNode(targetKey, using: opener)

        // Announce to closest peers in parallel
        let localProvider = KademliaPeer(id: localPeerID, addresses: addresses)
        let announcedCount = await announceToPeers(key: key, provider: localProvider, peers: closestPeers, opener: opener)

        emit(.providerAnnounced(key: key, toPeers: announcedCount))
        emit(.querySucceeded(queryInfo, result: .announced(toPeers: announcedCount)))
        return announcedCount
    }

    // MARK: - Private Helpers

    private func storeOnPeers(
        record: KademliaRecord,
        peers: [KademliaPeer],
        opener: any StreamOpener
    ) async -> Int {
        await withTaskGroup(of: Bool.self) { group in
            for peer in peers {
                group.addTask {
                    do {
                        try await self.sendPutValue(to: peer.id, record: record, opener: opener)
                        return true
                    } catch {
                        return false
                    }
                }
            }

            var count = 0
            for await success in group {
                if success { count += 1 }
            }
            return count
        }
    }

    private func announceToPeers(
        key: Data,
        provider: KademliaPeer,
        peers: [KademliaPeer],
        opener: any StreamOpener
    ) async -> Int {
        await withTaskGroup(of: Bool.self) { group in
            for peer in peers {
                group.addTask {
                    do {
                        try await self.sendAddProvider(to: peer.id, key: key, provider: provider, opener: opener)
                        return true
                    } catch {
                        return false
                    }
                }
            }

            var count = 0
            for await success in group {
                if success { count += 1 }
            }
            return count
        }
    }

    // MARK: - Message Sending

    fileprivate func sendFindNode(
        to peer: PeerID,
        key: KademliaKey,
        opener: any StreamOpener
    ) async throws -> [KademliaPeer] {
        let message = KademliaMessage.findNode(key: key.bytes)
        let response = try await sendMessage(message, to: peer, opener: opener)

        // Add responding peer to routing table
        addPeer(peer)

        return response.closerPeers
    }

    fileprivate func sendGetValue(
        to peer: PeerID,
        key: Data,
        opener: any StreamOpener
    ) async throws -> (record: KademliaRecord?, closerPeers: [KademliaPeer]) {
        let message = KademliaMessage.getValue(key: key)
        let response = try await sendMessage(message, to: peer, opener: opener)

        // Add responding peer to routing table
        addPeer(peer)

        return (response.record, response.closerPeers)
    }

    private func sendPutValue(
        to peer: PeerID,
        record: KademliaRecord,
        opener: any StreamOpener
    ) async throws {
        let message = KademliaMessage.putValue(record: record)
        _ = try await sendMessage(message, to: peer, opener: opener)

        // Add responding peer to routing table
        addPeer(peer)
    }

    fileprivate func sendGetProviders(
        to peer: PeerID,
        key: Data,
        opener: any StreamOpener
    ) async throws -> (providers: [KademliaPeer], closerPeers: [KademliaPeer]) {
        let message = KademliaMessage.getProviders(key: key)
        let response = try await sendMessage(message, to: peer, opener: opener)

        // Add responding peer to routing table
        addPeer(peer)

        return (response.providerPeers, response.closerPeers)
    }

    private func sendAddProvider(
        to peer: PeerID,
        key: Data,
        provider: KademliaPeer,
        opener: any StreamOpener
    ) async throws {
        let message = KademliaMessage.addProvider(key: key, providers: [provider])
        _ = try await sendMessage(message, to: peer, opener: opener)

        // Add responding peer to routing table
        addPeer(peer)
    }

    private func sendMessage(
        _ message: KademliaMessage,
        to peer: PeerID,
        opener: any StreamOpener
    ) async throws -> KademliaMessage {
        // Open stream with timeout (phase 1)
        let stream = try await withPeerTimeout {
            try await opener.newStream(to: peer, protocol: KademliaProtocol.protocolID)
        }

        do {
            // Send/receive with timeout (phase 2)
            let response = try await withPeerTimeout { [configuration] in
                let data = KademliaProtobuf.encode(message)
                try await stream.writeLengthPrefixedMessage(data)

                let responseData = try await stream.readLengthPrefixedMessage(maxSize: UInt64(configuration.maxMessageSize))
                return try KademliaProtobuf.decode(responseData)
            }
            try? await stream.close()
            return response
        } catch {
            // Ensure stream is closed on timeout or any error
            try? await stream.close()
            throw error
        }
    }

    // MARK: - Timeout Helpers

    /// Wraps an operation with the query timeout (for full query operations).
    ///
    /// This prevents queries from running indefinitely.
    private func withQueryTimeout<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: self.configuration.queryTimeout)
                throw KademliaError.timeout
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    /// Wraps an operation with the peer timeout (for individual peer interactions).
    ///
    /// This prevents malicious or slow peers from stalling operations indefinitely.
    /// Uses a shorter timeout than query timeout (default: 10 seconds vs 60 seconds).
    private func withPeerTimeout<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: self.configuration.peerTimeout)
                throw KademliaError.timeout
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    // MARK: - Length-Prefixed I/O

    private func readLengthPrefixed(from stream: MuxedStream) async throws -> Data {
        try await stream.readLengthPrefixedMessage(maxSize: UInt64(configuration.maxMessageSize))
    }

    private func writeLengthPrefixed(_ data: Data, to stream: MuxedStream) async throws {
        try await stream.writeLengthPrefixedMessage(data)
    }
}

// MARK: - Query Delegate Implementation

private final class QueryDelegateImpl: KademliaQueryDelegate, Sendable {
    private let service: KademliaService
    private let opener: any StreamOpener

    init(service: KademliaService, opener: any StreamOpener) {
        self.service = service
        self.opener = opener
    }

    func sendFindNode(to peer: PeerID, key: KademliaKey) async throws -> [KademliaPeer] {
        try await service.sendFindNode(to: peer, key: key, opener: opener)
    }

    func sendGetValue(to peer: PeerID, key: Data) async throws -> (record: KademliaRecord?, closerPeers: [KademliaPeer]) {
        try await service.sendGetValue(to: peer, key: key, opener: opener)
    }

    func sendGetProviders(to peer: PeerID, key: Data) async throws -> (providers: [KademliaPeer], closerPeers: [KademliaPeer]) {
        try await service.sendGetProviders(to: peer, key: key, opener: opener)
    }
}
