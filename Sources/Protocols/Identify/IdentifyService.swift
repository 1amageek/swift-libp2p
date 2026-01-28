/// IdentifyService - Identify protocol implementation
import Foundation
import P2PCore
import P2PMux
import P2PProtocols
import Synchronization

/// Logger for IdentifyService operations.
private let logger = Logger(label: "p2p.identify")

/// Configuration for IdentifyService.
public struct IdentifyConfiguration: Sendable {
    /// The protocol version to advertise.
    public var protocolVersion: String

    /// The agent version to advertise.
    public var agentVersion: String

    /// Timeout for identify operations.
    public var timeout: Duration

    /// Time-to-live for cached peer info.
    /// Default: 24 hours (peer info is relatively stable).
    public var cacheTTL: Duration

    /// Maximum number of cached peers.
    /// Default: 1000.
    public var maxCacheSize: Int

    /// Interval for background cache cleanup.
    /// Set to nil to disable periodic cleanup (lazy-only mode).
    /// Default: 5 minutes.
    public var cleanupInterval: Duration?

    /// Whether to automatically push identify updates when local addresses change.
    /// Default: true
    public var autoPush: Bool

    /// Maximum number of concurrent push operations.
    /// Default: 10
    public var maxConcurrentPushes: Int

    public init(
        protocolVersion: String = "ipfs/0.1.0",
        agentVersion: String = "swift-libp2p/0.1.0",
        timeout: Duration = .seconds(60),
        cacheTTL: Duration = .seconds(24 * 60 * 60),
        maxCacheSize: Int = 1000,
        cleanupInterval: Duration? = .seconds(300),
        autoPush: Bool = true,
        maxConcurrentPushes: Int = 10
    ) {
        self.protocolVersion = protocolVersion
        self.agentVersion = agentVersion
        self.timeout = timeout
        self.cacheTTL = cacheTTL
        self.maxCacheSize = maxCacheSize
        self.cleanupInterval = cleanupInterval
        self.autoPush = autoPush
        self.maxConcurrentPushes = maxConcurrentPushes
    }
}

/// Events emitted by IdentifyService.
public enum IdentifyEvent: Sendable {
    /// Received identification from a peer.
    case received(peer: PeerID, info: IdentifyInfo)

    /// Sent our identification to a peer.
    case sent(peer: PeerID)

    /// Received a push update from a peer.
    case pushReceived(peer: PeerID, info: IdentifyInfo)

    /// Auto-push triggered due to address change.
    case autoPushTriggered(peerCount: Int)

    /// Auto-push to a peer failed (non-fatal).
    case autoPushFailed(peer: PeerID, error: IdentifyError)

    /// Error during identification.
    case error(peer: PeerID?, IdentifyError)

    /// Background maintenance completed.
    case maintenanceCompleted(entriesRemoved: Int)
}

/// Service for the Identify protocol.
///
/// Handles both `/ipfs/id/1.0.0` (query) and `/ipfs/id/push/1.0.0` (push).
///
/// ## Usage
///
/// ```swift
/// let identifyService = IdentifyService(configuration: .init(
///     agentVersion: "my-app/1.0.0"
/// ))
///
/// // Register handlers with node
/// await identifyService.registerHandlers(
///     registry: node,
///     localKeyPair: keyPair,
///     getListenAddresses: { addresses },
///     getSupportedProtocols: { protocols }
/// )
///
/// // Identify a connected peer
/// let info = try await identifyService.identify(peer, using: node)
/// print("Peer agent: \(info.agentVersion)")
/// ```
public final class IdentifyService: ProtocolService, EventEmitting, Sendable {

    // MARK: - ProtocolService

    public var protocolIDs: [String] {
        [LibP2PProtocol.identify, LibP2PProtocol.identifyPush]
    }

    // MARK: - Properties

    /// Configuration for this service.
    public let configuration: IdentifyConfiguration

    /// Event state (dedicated).
    private let eventState: Mutex<EventState>

    private struct EventState: Sendable {
        var continuation: AsyncStream<IdentifyEvent>.Continuation?
        var stream: AsyncStream<IdentifyEvent>?
    }

    /// Cache state (separated from event state).
    private let cacheState: Mutex<CacheState>

    /// Internal cache entry with expiration metadata.
    private struct CachedPeerInfo: Sendable {
        let info: IdentifyInfo
        let cachedAt: ContinuousClock.Instant
        let expiresAt: ContinuousClock.Instant
    }

    /// Internal cache state.
    private struct CacheState: Sendable {
        /// Cached peer info by PeerID.
        var entries: [PeerID: CachedPeerInfo]

        /// Access order for LRU eviction (most recent at end).
        var accessOrder: [PeerID]

        init() {
            self.entries = [:]
            self.accessOrder = []
        }
    }

    /// Auto-push state for tracking connected peers.
    private let autoPushState: Mutex<AutoPushState>

    /// Reference to stream opener for auto-push.
    private final class OpenerRef: Sendable {
        let opener: any StreamOpener
        init(_ opener: any StreamOpener) {
            self.opener = opener
        }
    }

    /// Internal auto-push state.
    private struct AutoPushState: Sendable {
        /// Currently connected peers that support identify push.
        var connectedPeers: Set<PeerID> = []

        /// Reference to opener for making streams.
        var openerRef: OpenerRef?

        /// Reference to local key pair for signing.
        var localKeyPair: KeyPair?

        /// Closure to get current listen addresses.
        var getListenAddresses: (@Sendable () async -> [Multiaddr])?

        /// Closure to get current supported protocols.
        var getSupportedProtocols: (@Sendable () async -> [String])?
    }

    /// Background cleanup task.
    private let cleanupTask: Mutex<Task<Void, Never>?>

    /// Event stream for monitoring identify events.
    public var events: AsyncStream<IdentifyEvent> {
        eventState.withLock { state in
            if let existing = state.stream {
                return existing
            }
            let (stream, continuation) = AsyncStream<IdentifyEvent>.makeStream()
            state.stream = stream
            state.continuation = continuation
            return stream
        }
    }

    // MARK: - Initialization

    public init(configuration: IdentifyConfiguration = .init()) {
        self.configuration = configuration
        self.eventState = Mutex(EventState())
        self.cacheState = Mutex(CacheState())
        self.autoPushState = Mutex(AutoPushState())
        self.cleanupTask = Mutex(nil)
    }

    // MARK: - Handler Registration

    /// Registers identify protocol handlers.
    ///
    /// - Parameters:
    ///   - registry: The handler registry to register with
    ///   - localKeyPair: The local key pair
    ///   - getListenAddresses: Closure to get current listen addresses
    ///   - getSupportedProtocols: Closure to get current supported protocols
    ///   - opener: Optional stream opener for auto-push (required if autoPush is enabled)
    public func registerHandlers(
        registry: any HandlerRegistry,
        localKeyPair: KeyPair,
        getListenAddresses: @escaping @Sendable () async -> [Multiaddr],
        getSupportedProtocols: @escaping @Sendable () async -> [String],
        opener: (any StreamOpener)? = nil
    ) async {
        let config = self.configuration

        // Store references for auto-push
        if config.autoPush, let opener = opener {
            autoPushState.withLock { state in
                state.openerRef = OpenerRef(opener)
                state.localKeyPair = localKeyPair
                state.getListenAddresses = getListenAddresses
                state.getSupportedProtocols = getSupportedProtocols
            }
        }

        // Handler for identify requests
        await registry.handle(LibP2PProtocol.identify) { [weak self] context in
            guard let self = self else { return }

            do {
                // Build our info with the observed address
                let listenAddrs = await getListenAddresses()
                let protocols = await getSupportedProtocols()

                let info = IdentifyInfo(
                    publicKey: localKeyPair.publicKey,
                    listenAddresses: listenAddrs,
                    protocols: protocols,
                    observedAddress: context.remoteAddress,
                    protocolVersion: config.protocolVersion,
                    agentVersion: config.agentVersion,
                    signedPeerRecord: nil
                )

                // Encode and send
                let data = try IdentifyProtobuf.encode(info)
                try await context.stream.write(data)
                try await context.stream.close()

                self.emit(.sent(peer: context.remotePeer))
            } catch let sendError {
                self.emit(.error(peer: context.remotePeer, .streamError(sendError.localizedDescription)))
                do {
                    try await context.stream.close()
                } catch {
                    logger.debug("Failed to close identify stream: \(error)")
                }
            }
        }

        // Handler for identify push
        await registry.handle(LibP2PProtocol.identifyPush) { [weak self] context in
            guard let self = self else { return }

            do {
                // Read the push data
                let data = try await self.readAll(from: context.stream)
                let info = try IdentifyProtobuf.decode(data)

                // Verify signed peer record if present
                if let envelope = info.signedPeerRecord {
                    try self.verifySignedPeerRecord(envelope, expectedPeer: context.remotePeer)
                }

                // Update cache
                self.cacheInfo(info, for: context.remotePeer)

                self.emit(.pushReceived(peer: context.remotePeer, info: info))
            } catch let identifyError as IdentifyError {
                self.emit(.error(peer: context.remotePeer, identifyError))
            } catch {
                self.emit(.error(peer: context.remotePeer, .streamError(error.localizedDescription)))
            }

            do {
                try await context.stream.close()
            } catch {
                logger.debug("Failed to close identify push stream: \(error)")
            }
        }
    }

    // MARK: - Public API

    /// Identifies a connected peer.
    ///
    /// Opens a stream and requests the peer's identification info.
    ///
    /// - Parameters:
    ///   - peer: The peer to identify
    ///   - opener: The stream opener to use
    /// - Returns: The peer's identification info
    public func identify(_ peer: PeerID, using opener: any StreamOpener) async throws -> IdentifyInfo {
        // Open identify stream
        let stream = try await opener.newStream(to: peer, protocol: LibP2PProtocol.identify)

        defer {
            Task {
                do {
                    try await stream.close()
                } catch {
                    logger.debug("Failed to close identify stream: \(error)")
                }
            }
        }

        // Read the identify response with timeout
        let data = try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try await self.readAll(from: stream)
            }

            group.addTask {
                try await Task.sleep(for: self.configuration.timeout)
                throw IdentifyError.timeout
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }

        let info = try IdentifyProtobuf.decode(data)

        // Verify peer ID if public key is present
        if let publicKey = info.publicKey {
            let infoPeerID = PeerID(publicKey: publicKey)
            if infoPeerID != peer {
                throw IdentifyError.peerIDMismatch(expected: peer, actual: infoPeerID)
            }
        }

        // Verify signed peer record if present
        if let envelope = info.signedPeerRecord {
            try verifySignedPeerRecord(envelope, expectedPeer: peer)
        }

        // Cache the info
        cacheInfo(info, for: peer)

        // Emit event
        emit(.received(peer: peer, info: info))

        return info
    }

    /// Pushes our identification info to a peer.
    ///
    /// - Parameters:
    ///   - peer: The peer to push to
    ///   - opener: The stream opener to use
    ///   - localKeyPair: Our key pair
    ///   - listenAddresses: Our listen addresses
    ///   - supportedProtocols: Our supported protocols
    public func push(
        to peer: PeerID,
        using opener: any StreamOpener,
        localKeyPair: KeyPair,
        listenAddresses: [Multiaddr],
        supportedProtocols: [String]
    ) async throws {
        // Open push stream
        let stream = try await opener.newStream(to: peer, protocol: LibP2PProtocol.identifyPush)

        defer {
            Task {
                do {
                    try await stream.close()
                } catch {
                    logger.debug("Failed to close identify push stream: \(error)")
                }
            }
        }

        // Build and send our info
        let info = IdentifyInfo(
            publicKey: localKeyPair.publicKey,
            listenAddresses: listenAddresses,
            protocols: supportedProtocols,
            observedAddress: nil,
            protocolVersion: configuration.protocolVersion,
            agentVersion: configuration.agentVersion,
            signedPeerRecord: nil
        )

        let data = try IdentifyProtobuf.encode(info)
        try await stream.write(data)

        emit(.sent(peer: peer))
    }

    // MARK: - Peer Tracking for Auto-Push

    /// Notifies the service that a peer connected.
    ///
    /// Call this when a new peer connection is established.
    /// The peer will receive auto-push updates when local addresses change.
    ///
    /// - Parameter peer: The connected peer ID
    public func peerConnected(_ peer: PeerID) {
        _ = autoPushState.withLock { state in
            state.connectedPeers.insert(peer)
        }
    }

    /// Notifies the service that a peer disconnected.
    ///
    /// Call this when a peer connection is closed.
    ///
    /// - Parameter peer: The disconnected peer ID
    public func peerDisconnected(_ peer: PeerID) {
        _ = autoPushState.withLock { state in
            state.connectedPeers.remove(peer)
        }
    }

    /// Returns the set of connected peers being tracked.
    public var connectedPeers: Set<PeerID> {
        autoPushState.withLock { $0.connectedPeers }
    }

    /// Notifies the service that local addresses have changed.
    ///
    /// When `autoPush` is enabled, this will trigger a push to all
    /// connected peers with the new address information.
    ///
    /// - Parameter newAddresses: The new listen addresses (if nil, will fetch via getListenAddresses)
    public func notifyAddressesChanged(newAddresses: [Multiaddr]? = nil) {
        guard configuration.autoPush else { return }

        // Get current state
        let (peers, openerRef, keyPair, getAddrs, getProtos): (
            Set<PeerID>, OpenerRef?, KeyPair?,
            (@Sendable () async -> [Multiaddr])?,
            (@Sendable () async -> [String])?
        ) = autoPushState.withLock { state in
            (state.connectedPeers, state.openerRef, state.localKeyPair,
             state.getListenAddresses, state.getSupportedProtocols)
        }

        guard !peers.isEmpty else { return }
        guard let opener = openerRef?.opener,
              let keyPair = keyPair,
              let getAddresses = getAddrs,
              let getProtocols = getProtos else {
            logger.debug("Auto-push not configured: missing opener or credentials")
            return
        }

        emit(.autoPushTriggered(peerCount: peers.count))

        // Run auto-push in background
        Task { [weak self, configuration] in
            guard let self = self else { return }

            let addresses: [Multiaddr]
            if let newAddrs = newAddresses {
                addresses = newAddrs
            } else {
                addresses = await getAddresses()
            }
            let protocols = await getProtocols()

            // Use TaskGroup for concurrent pushes with limit
            await withTaskGroup(of: Void.self) { group in
                var inFlight = 0

                for peer in peers {
                    // Limit concurrent pushes
                    if inFlight >= configuration.maxConcurrentPushes {
                        await group.next()
                        inFlight -= 1
                    }

                    inFlight += 1
                    group.addTask {
                        do {
                            try await self.push(
                                to: peer,
                                using: opener,
                                localKeyPair: keyPair,
                                listenAddresses: addresses,
                                supportedProtocols: protocols
                            )
                        } catch {
                            let identifyError: IdentifyError
                            if let err = error as? IdentifyError {
                                identifyError = err
                            } else {
                                identifyError = .streamError(error.localizedDescription)
                            }
                            self.emit(.autoPushFailed(peer: peer, error: identifyError))
                        }
                    }
                }

                // Wait for remaining tasks
                await group.waitForAll()
            }
        }
    }

    /// Returns cached info for a peer.
    ///
    /// Returns `nil` if the entry has expired (lazy cleanup).
    public func cachedInfo(for peer: PeerID) -> IdentifyInfo? {
        cacheState.withLock { state in
            guard let cached = state.entries[peer] else { return nil }

            // Check expiration (lazy cleanup)
            let now = ContinuousClock.now
            if cached.expiresAt <= now {
                state.entries.removeValue(forKey: peer)
                if let index = state.accessOrder.firstIndex(of: peer) {
                    state.accessOrder.remove(at: index)
                }
                return nil
            }

            // Update LRU order (move to end = most recent)
            if let index = state.accessOrder.firstIndex(of: peer) {
                state.accessOrder.remove(at: index)
                state.accessOrder.append(peer)
            }

            return cached.info
        }
    }

    /// Returns all cached peer info (excludes expired entries).
    public var allCachedInfo: [PeerID: IdentifyInfo] {
        let now = ContinuousClock.now
        return cacheState.withLock { state in
            var result: [PeerID: IdentifyInfo] = [:]
            for (peer, cached) in state.entries where cached.expiresAt > now {
                result[peer] = cached.info
            }
            return result
        }
    }

    /// Clears cached info for a peer.
    public func clearCache(for peer: PeerID) {
        cacheState.withLock { state in
            state.entries.removeValue(forKey: peer)
            if let index = state.accessOrder.firstIndex(of: peer) {
                state.accessOrder.remove(at: index)
            }
        }
    }

    /// Clears all cached info.
    public func clearAllCache() {
        cacheState.withLock { state in
            state.entries.removeAll()
            state.accessOrder.removeAll()
        }
    }

    // MARK: - Cache Operations

    /// Adds or updates cached info for a peer.
    ///
    /// - Parameters:
    ///   - info: The identify info to cache
    ///   - peer: The peer ID to cache for
    internal func cacheInfo(_ info: IdentifyInfo, for peer: PeerID) {
        let now = ContinuousClock.now
        let expiresAt = now.advanced(by: configuration.cacheTTL)

        cacheState.withLock { state in
            // Update LRU order (move to end = most recent)
            if let index = state.accessOrder.firstIndex(of: peer) {
                state.accessOrder.remove(at: index)
            }
            state.accessOrder.append(peer)

            // Check capacity - evict if needed for new entry
            if state.entries[peer] == nil && state.entries.count >= configuration.maxCacheSize {
                evictEntries(from: &state, count: 1)
            }

            state.entries[peer] = CachedPeerInfo(
                info: info,
                cachedAt: now,
                expiresAt: expiresAt
            )
        }
    }

    /// Evicts entries using strategy: expired first, then LRU.
    ///
    /// - Parameters:
    ///   - state: The cache state to modify
    ///   - count: Number of entries to evict
    /// - Returns: Number of entries actually evicted
    @discardableResult
    private func evictEntries(from state: inout CacheState, count: Int) -> Int {
        let now = ContinuousClock.now
        var evicted = 0
        var toEvict: [PeerID] = []

        // Phase 1: Prioritize expired entries
        for peer in state.accessOrder where evicted < count {
            if let cached = state.entries[peer], cached.expiresAt <= now {
                toEvict.append(peer)
                evicted += 1
            }
        }

        // Phase 2: LRU (oldest first) if still need more
        var lruIndex = 0
        while evicted < count && lruIndex < state.accessOrder.count {
            let peer = state.accessOrder[lruIndex]
            if !toEvict.contains(peer) {
                toEvict.append(peer)
                evicted += 1
            }
            lruIndex += 1
        }

        // Execute eviction
        for peer in toEvict {
            state.entries.removeValue(forKey: peer)
            if let index = state.accessOrder.firstIndex(of: peer) {
                state.accessOrder.remove(at: index)
            }
        }

        return evicted
    }

    /// Cleans up expired entries from the cache.
    ///
    /// - Returns: Number of entries removed
    @discardableResult
    public func cleanup() -> Int {
        let now = ContinuousClock.now

        return cacheState.withLock { state in
            let expiredPeers = state.entries.filter { $0.value.expiresAt <= now }.map { $0.key }

            for peer in expiredPeers {
                state.entries.removeValue(forKey: peer)
                if let index = state.accessOrder.firstIndex(of: peer) {
                    state.accessOrder.remove(at: index)
                }
            }

            return expiredPeers.count
        }
    }

    // MARK: - Maintenance

    /// Starts the background maintenance task.
    ///
    /// The task periodically cleans up expired cache entries.
    /// Call `stopMaintenance()` or `shutdown()` to stop.
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
                let removed = cleanup()
                if removed > 0 {
                    emit(.maintenanceCompleted(entriesRemoved: removed))
                }
            } catch {
                break // Task cancelled
            }
        }
    }

    // MARK: - Helpers

    /// Verifies a signed peer record from an identify response.
    ///
    /// This method ensures that:
    /// 1. The envelope signature is valid
    /// 2. The peer ID in the record matches the expected peer
    ///
    /// - Parameters:
    ///   - envelope: The signed envelope containing the peer record
    ///   - expectedPeer: The peer ID we expect the record to be for
    /// - Throws: `IdentifyError.invalidSignedPeerRecord` if verification fails
    private func verifySignedPeerRecord(_ envelope: Envelope, expectedPeer: PeerID) throws {
        // Verify signature and extract record
        let peerRecord: PeerRecord
        do {
            peerRecord = try envelope.record(as: PeerRecord.self)
        } catch EnvelopeError.invalidSignature {
            throw IdentifyError.invalidSignedPeerRecord("Signature verification failed")
        } catch EnvelopeError.payloadTypeMismatch {
            throw IdentifyError.invalidSignedPeerRecord("Payload type is not a peer record")
        } catch {
            throw IdentifyError.invalidSignedPeerRecord("Failed to decode peer record: \(error)")
        }

        // Verify peer ID matches
        if peerRecord.peerID != expectedPeer {
            throw IdentifyError.invalidSignedPeerRecord(
                "Peer ID mismatch: expected \(expectedPeer), got \(peerRecord.peerID)"
            )
        }

        // Also verify that the envelope's signer matches
        if envelope.peerID != expectedPeer {
            throw IdentifyError.invalidSignedPeerRecord(
                "Envelope signer mismatch: expected \(expectedPeer), got \(envelope.peerID)"
            )
        }
    }

    /// Reads all data from a stream until EOF.
    ///
    /// - Parameters:
    ///   - stream: The stream to read from
    ///   - maxSize: Maximum bytes to read (default 64KB)
    /// - Returns: All data read until EOF
    /// - Throws: `IdentifyError.messageTooLarge` if the message exceeds maxSize
    private func readAll(from stream: MuxedStream, maxSize: Int = 64 * 1024) async throws -> Data {
        var buffer = Data()

        while true {
            let chunk = try await stream.read()
            if chunk.isEmpty {
                break // EOF - normal termination
            }
            buffer.append(chunk)

            // Check if buffer exceeds maximum allowed size
            if buffer.count > maxSize {
                throw IdentifyError.messageTooLarge(size: buffer.count, max: maxSize)
            }
        }

        return buffer
    }

    private func emit(_ event: IdentifyEvent) {
        _ = eventState.withLock { state in
            state.continuation?.yield(event)
        }
    }

    // MARK: - Shutdown

    /// Shuts down the service and finishes the event stream.
    ///
    /// Call this method when the service is no longer needed to properly
    /// terminate any consumers waiting on the `events` stream.
    /// Also stops the background maintenance task if running.
    public func shutdown() {
        stopMaintenance()

        // Clear auto-push state
        autoPushState.withLock { state in
            state.connectedPeers.removeAll()
            state.openerRef = nil
            state.localKeyPair = nil
            state.getListenAddresses = nil
            state.getSupportedProtocols = nil
        }

        eventState.withLock { state in
            state.continuation?.finish()
            state.continuation = nil
            state.stream = nil
        }
    }
}
