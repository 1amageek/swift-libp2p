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

    public init(
        protocolVersion: String = "ipfs/0.1.0",
        agentVersion: String = "swift-libp2p/0.1.0",
        timeout: Duration = .seconds(60)
    ) {
        self.protocolVersion = protocolVersion
        self.agentVersion = agentVersion
        self.timeout = timeout
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

    /// Error during identification.
    case error(peer: PeerID?, IdentifyError)
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

    /// Peer information cache.
    private let peerInfoCache: Mutex<[PeerID: IdentifyInfo]>

    /// Event stream continuation.
    private let eventState: Mutex<EventState>

    private struct EventState: Sendable {
        var continuation: AsyncStream<IdentifyEvent>.Continuation?
        var stream: AsyncStream<IdentifyEvent>?
    }

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
        self.peerInfoCache = Mutex([:])
        self.eventState = Mutex(EventState())
    }

    // MARK: - Handler Registration

    /// Registers identify protocol handlers.
    ///
    /// - Parameters:
    ///   - registry: The handler registry to register with
    ///   - localKeyPair: The local key pair
    ///   - getListenAddresses: Closure to get current listen addresses
    ///   - getSupportedProtocols: Closure to get current supported protocols
    public func registerHandlers(
        registry: any HandlerRegistry,
        localKeyPair: KeyPair,
        getListenAddresses: @escaping @Sendable () async -> [Multiaddr],
        getSupportedProtocols: @escaping @Sendable () async -> [String]
    ) async {
        let config = self.configuration

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

                // Update cache
                self.peerInfoCache.withLock { cache in
                    cache[context.remotePeer] = info
                }

                self.emit(.pushReceived(peer: context.remotePeer, info: info))
            } catch let pushError {
                self.emit(.error(peer: context.remotePeer, .streamError(pushError.localizedDescription)))
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

        // Cache the info
        peerInfoCache.withLock { cache in
            cache[peer] = info
        }

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

    /// Returns cached info for a peer.
    public func cachedInfo(for peer: PeerID) -> IdentifyInfo? {
        peerInfoCache.withLock { cache in
            cache[peer]
        }
    }

    /// Returns all cached peer info.
    public var allCachedInfo: [PeerID: IdentifyInfo] {
        peerInfoCache.withLock { $0 }
    }

    /// Clears cached info for a peer.
    public func clearCache(for peer: PeerID) {
        peerInfoCache.withLock { cache in
            cache.removeValue(forKey: peer)
        }
    }

    /// Clears all cached info.
    public func clearAllCache() {
        peerInfoCache.withLock { cache in
            cache.removeAll()
        }
    }

    // MARK: - Helpers

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
        eventState.withLock { state in
            state.continuation?.yield(event)
        }
    }

    // MARK: - Shutdown

    /// Shuts down the service and finishes the event stream.
    ///
    /// Call this method when the service is no longer needed to properly
    /// terminate any consumers waiting on the `events` stream.
    public func shutdown() {
        eventState.withLock { state in
            state.continuation?.finish()
            state.continuation = nil
            state.stream = nil
        }
    }
}
