/// P2PDiscoveryMDNS - mDNS-based peer discovery for local networks
import Foundation
import P2PCore
import P2PDiscovery
import mDNS
import Synchronization

/// mDNS-based peer discovery for local area networks.
///
/// Uses Multicast DNS (RFC 6762) and DNS-SD (RFC 6763) to discover
/// and advertise libp2p peers on the local network.
public actor MDNSDiscovery: DiscoveryService {

    // MARK: - Properties

    private let localPeerID: PeerID
    private let configuration: MDNSConfiguration
    private let browser: ServiceBrowser
    private let advertiser: ServiceAdvertiser

    private var knownServices: [String: Service] = [:]
    private var sequenceNumber: UInt64 = 0
    private var isStarted = false
    private var forwardTask: Task<Void, Never>?

    private var eventContinuation: AsyncStream<Observation>.Continuation?
    private nonisolated let eventStream: AsyncStream<Observation>

    // MARK: - Initialization

    /// Creates a new mDNS discovery service.
    ///
    /// - Parameters:
    ///   - localPeerID: The local peer's ID.
    ///   - configuration: Configuration options.
    public init(
        localPeerID: PeerID,
        configuration: MDNSConfiguration = .default
    ) {
        self.localPeerID = localPeerID
        self.configuration = configuration

        // Create browser configuration
        var browserConfig = ServiceBrowser.Configuration()
        browserConfig.queryInterval = configuration.queryInterval
        browserConfig.autoResolve = true
        browserConfig.useIPv4 = configuration.useIPv4
        browserConfig.useIPv6 = configuration.useIPv6
        browserConfig.networkInterface = configuration.networkInterface

        self.browser = ServiceBrowser(configuration: browserConfig)

        // Create advertiser configuration
        var advertiserConfig = ServiceAdvertiser.Configuration()
        advertiserConfig.ttl = configuration.ttl
        advertiserConfig.useIPv4 = configuration.useIPv4
        advertiserConfig.useIPv6 = configuration.useIPv6
        advertiserConfig.networkInterface = configuration.networkInterface

        self.advertiser = ServiceAdvertiser(configuration: advertiserConfig)

        // Create event stream
        var continuation: AsyncStream<Observation>.Continuation!
        self.eventStream = AsyncStream { cont in
            continuation = cont
        }
        self.eventContinuation = continuation
    }

    deinit {
        eventContinuation?.finish()
    }

    // MARK: - Lifecycle

    /// Starts the mDNS discovery service.
    public func start() async throws {
        guard !isStarted else { return }

        try await browser.start()
        try await advertiser.start()
        try await browser.browse(for: configuration.fullServiceType)

        isStarted = true

        // Start event forwarding task
        forwardTask = Task { [weak self] in
            guard let self = self else { return }
            await self.forwardBrowserEvents()
        }
    }

    /// Stops the mDNS discovery service.
    public func stop() async {
        guard isStarted else { return }

        forwardTask?.cancel()
        forwardTask = nil

        await browser.stop()
        await advertiser.stop()
        isStarted = false
        eventContinuation?.finish()
    }

    // MARK: - DiscoveryService Protocol

    /// Announces our presence with the given addresses.
    public func announce(addresses: [Multiaddr]) async throws {
        guard isStarted else {
            throw MDNSDiscoveryError.notStarted
        }

        // Extract port from first address, default to 4001
        let port = extractPort(from: addresses) ?? 4001

        let service = PeerIDServiceCodec.encode(
            peerID: localPeerID,
            addresses: addresses,
            port: port,
            configuration: configuration
        )

        try await advertiser.register(service)
    }

    /// Finds candidates for a specific peer.
    public func find(peer: PeerID) async throws -> [ScoredCandidate] {
        let targetName = peer.description

        if let service = knownServices[targetName] {
            if let candidate = PeerIDServiceCodec.decode(service: service, observer: localPeerID) {
                return [candidate]
            }
        }

        return []
    }

    /// Subscribes to observations about a specific peer.
    /// Pass a peer ID to filter, or use `.any` pattern by subscribing to all.
    nonisolated public func subscribe(to peer: PeerID) -> AsyncStream<Observation> {
        let targetID = peer.description

        return AsyncStream { continuation in
            Task { [weak self] in
                guard let self = self else {
                    continuation.finish()
                    return
                }

                for await observation in self.eventStream {
                    if observation.subject.description == targetID {
                        continuation.yield(observation)
                    }
                }
                continuation.finish()
            }
        }
    }

    /// Returns all known peer IDs.
    public func knownPeers() async -> [PeerID] {
        knownServices.compactMap { (name, _) in
            try? PeerID(string: name)
        }.filter { $0 != localPeerID }
    }

    /// Returns all observations as a stream (for general subscription).
    nonisolated public var observations: AsyncStream<Observation> {
        eventStream
    }

    // MARK: - Private Methods

    private func forwardBrowserEvents() async {
        for await event in await browser.events {
            switch event {
            case .found(let service):
                handleServiceFound(service)

            case .updated(let service):
                handleServiceUpdated(service)

            case .removed(let service):
                handleServiceRemoved(service)

            case .error:
                // Log error but continue
                break
            }
        }
    }

    private func handleServiceFound(_ service: Service) {
        // Ignore our own service
        guard service.name != localPeerID.description else { return }

        knownServices[service.name] = service
        sequenceNumber += 1

        if let observation = PeerIDServiceCodec.toObservation(
            service: service,
            kind: .announcement,
            observer: localPeerID,
            sequenceNumber: sequenceNumber
        ) {
            eventContinuation?.yield(observation)
        }
    }

    private func handleServiceUpdated(_ service: Service) {
        guard service.name != localPeerID.description else { return }

        knownServices[service.name] = service
        sequenceNumber += 1

        if let observation = PeerIDServiceCodec.toObservation(
            service: service,
            kind: .reachable,
            observer: localPeerID,
            sequenceNumber: sequenceNumber
        ) {
            eventContinuation?.yield(observation)
        }
    }

    private func handleServiceRemoved(_ service: Service) {
        guard service.name != localPeerID.description else { return }

        knownServices.removeValue(forKey: service.name)
        sequenceNumber += 1

        if let observation = PeerIDServiceCodec.toObservation(
            service: service,
            kind: .unreachable,
            observer: localPeerID,
            sequenceNumber: sequenceNumber
        ) {
            eventContinuation?.yield(observation)
        }
    }

    private func extractPort(from addresses: [Multiaddr]) -> UInt16? {
        for addr in addresses {
            for component in addr.protocols {
                switch component {
                case .tcp(let port), .udp(let port):
                    return port
                default:
                    continue
                }
            }
        }
        return nil
    }
}

// MARK: - Errors

/// Errors that can occur during mDNS discovery.
public enum MDNSDiscoveryError: Error, Sendable {
    /// The discovery service has not been started.
    case notStarted
    /// The discovery service is already started.
    case alreadyStarted
    /// Failed to parse peer ID from service name.
    case invalidPeerID(String)
}
