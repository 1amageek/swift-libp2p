/// P2PDiscoveryMDNS - mDNS-based peer discovery for local networks
import Foundation
import P2PCore
import P2PDiscovery
import P2PProtocols
import mDNS
import Synchronization

/// mDNS-based peer discovery for local area networks.
///
/// Uses Multicast DNS (RFC 6762) and DNS-SD (RFC 6763) to discover
/// and advertise libp2p peers on the local network.
public actor MDNSDiscovery: DiscoveryService {

    // MARK: - Properties

    public let localPeerID: PeerID
    private let configuration: MDNSConfiguration
    private let advertisedServiceName: String
    private var browser: ServiceBrowser?
    private var advertiser: ServiceAdvertiser?

    private var knownServicesByPeerID: [PeerID: Service] = [:]
    private var peerIDByServiceName: [String: PeerID] = [:]
    private var serviceNameByPeerID: [PeerID: String] = [:]
    private var lastBrowserError: DNSError?
    private var sequenceNumber: UInt64 = 0
    private var isStarted = false
    private var forwardTask: Task<Void, Never>?

    private nonisolated let broadcaster = EventBroadcaster<PeerObservation>()

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
        switch configuration.peerNameStrategy {
        case .random:
            self.advertisedServiceName = "p2p-\(UUID().uuidString.lowercased())"
        case .peerID:
            self.advertisedServiceName = localPeerID.description
        }
    }

    deinit {
        broadcaster.shutdown()
    }

    // MARK: - Lifecycle

    /// Starts the mDNS discovery service.
    ///
    /// This method is idempotent — calling it when already started is a no-op.
    public func start() async throws {
        guard !isStarted else { return }

        // Create browser configuration
        var browserConfig = ServiceBrowser.Configuration()
        browserConfig.queryInterval = configuration.queryInterval
        browserConfig.autoResolve = true
        browserConfig.useIPv4 = configuration.useIPv4
        browserConfig.useIPv6 = configuration.useIPv6
        browserConfig.networkInterface = configuration.networkInterface

        let browser = ServiceBrowser(configuration: browserConfig)
        self.browser = browser

        // Create advertiser configuration
        var advertiserConfig = ServiceAdvertiser.Configuration()
        advertiserConfig.ttl = configuration.ttl
        advertiserConfig.useIPv4 = configuration.useIPv4
        advertiserConfig.useIPv6 = configuration.useIPv6
        advertiserConfig.networkInterface = configuration.networkInterface

        let advertiser = ServiceAdvertiser(configuration: advertiserConfig)
        self.advertiser = advertiser

        try await browser.start()
        try await advertiser.start()
        try await browser.browse(for: configuration.fullServiceType)

        isStarted = true
        lastBrowserError = nil

        // Start event forwarding task
        forwardTask = Task { [weak self] in
            guard let self = self else { return }
            await self.forwardBrowserEvents()
        }
    }

    /// Shuts down the mDNS discovery service.
    public func shutdown() async {
        guard isStarted else { return }

        forwardTask?.cancel()
        forwardTask = nil

        await browser?.shutdown()
        await advertiser?.shutdown()

        // Clear references to allow new instances on next start()
        browser = nil
        advertiser = nil

        isStarted = false
        knownServicesByPeerID.removeAll()
        peerIDByServiceName.removeAll()
        serviceNameByPeerID.removeAll()
        lastBrowserError = nil
        sequenceNumber = 0
        broadcaster.shutdown()
    }

    // MARK: - DiscoveryService Protocol

    /// Announces our presence with the given addresses.
    public func announce(addresses: [Multiaddr]) async throws {
        guard isStarted, let advertiser = advertiser else {
            throw MDNSDiscoveryError.notStarted
        }

        // Extract port from first address, default to 4001
        let port = extractPort(from: addresses) ?? 4001

        let service = PeerIDServiceCodec.encode(
            peerID: localPeerID,
            addresses: addresses,
            port: port,
            configuration: configuration,
            serviceName: advertisedServiceName
        )

        try await advertiser.register(service)
    }

    /// Finds candidates for a specific peer.
    public func find(peer: PeerID) async throws -> [ScoredCandidate] {
        if let service = knownServicesByPeerID[peer] {
            let candidate = try PeerIDServiceCodec.decode(service: service, observer: localPeerID)
            return [candidate]
        }

        if let browserError = lastBrowserError {
            throw MDNSDiscoveryError.browserError(browserError)
        }

        return []
    }

    /// Subscribes to observations about a specific peer.
    /// Pass a peer ID to filter, or use `.any` pattern by subscribing to all.
    nonisolated public func subscribe(to peer: PeerID) -> AsyncStream<PeerObservation> {
        let targetID = peer.description
        let stream = broadcaster.subscribe()
        return AsyncStream { continuation in
            let task = Task {
                for await observation in stream where observation.subject.description == targetID {
                    continuation.yield(observation)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// Returns all known peer IDs.
    public func collectKnownPeers() async -> [PeerID] {
        Array(knownServicesByPeerID.keys)
    }

    /// Returns all observations as a stream (for general subscription).
    /// Each call returns an independent stream (multi-consumer safe).
    nonisolated public var observations: AsyncStream<PeerObservation> {
        broadcaster.subscribe()
    }

    // MARK: - Private Methods

    private func forwardBrowserEvents() async {
        guard let browser = browser else { return }

        for await event in await browser.events {
            switch event {
            case .found(let service):
                handleServiceFound(service)

            case .updated(let service):
                handleServiceUpdated(service)

            case .removed(let service):
                handleServiceRemoved(service)

            case .error(let error):
                lastBrowserError = error
            }
        }
    }

    private func handleServiceFound(_ service: Service) {
        // Ignore our own service
        guard service.name != localPeerID.description else { return }

        sequenceNumber += 1

        do {
            let observation = try PeerIDServiceCodec.toObservation(
                service: service,
                kind: .announcement,
                observer: localPeerID,
                sequenceNumber: sequenceNumber
            )
            lastBrowserError = nil
            if let previousName = serviceNameByPeerID[observation.subject], previousName != service.name {
                peerIDByServiceName.removeValue(forKey: previousName)
            }
            knownServicesByPeerID[observation.subject] = service
            peerIDByServiceName[service.name] = observation.subject
            serviceNameByPeerID[observation.subject] = service.name
            broadcaster.emit(observation)
        } catch {
            // Invalid service name - not a valid libp2p peer, skip
        }
    }

    private func handleServiceUpdated(_ service: Service) {
        guard service.name != localPeerID.description else { return }

        sequenceNumber += 1

        do {
            let observation = try PeerIDServiceCodec.toObservation(
                service: service,
                kind: .reachable,
                observer: localPeerID,
                sequenceNumber: sequenceNumber
            )
            lastBrowserError = nil
            if let previousName = serviceNameByPeerID[observation.subject], previousName != service.name {
                peerIDByServiceName.removeValue(forKey: previousName)
            }
            knownServicesByPeerID[observation.subject] = service
            peerIDByServiceName[service.name] = observation.subject
            serviceNameByPeerID[observation.subject] = service.name
            broadcaster.emit(observation)
        } catch {
            // Invalid service name - not a valid libp2p peer, skip
        }
    }

    private func handleServiceRemoved(_ service: Service) {
        guard service.name != localPeerID.description else { return }

        sequenceNumber += 1
        lastBrowserError = nil

        var removedPeerID = peerIDByServiceName.removeValue(forKey: service.name)

        if removedPeerID == nil {
            do {
                removedPeerID = try PeerIDServiceCodec.inferPeerID(from: service)
            } catch {
                // Cannot identify removed peer
            }
        }

        guard let peerID = removedPeerID else {
            return
        }

        serviceNameByPeerID.removeValue(forKey: peerID)
        let knownService = knownServicesByPeerID.removeValue(forKey: peerID)

        var hints: [Multiaddr] = []
        if let knownService {
            do {
                let candidate = try PeerIDServiceCodec.decode(service: knownService, observer: localPeerID)
                hints = candidate.addresses
            } catch {
                hints = []
            }
        }

        let observation = PeerObservation(
            subject: peerID,
            observer: localPeerID,
            kind: .unreachable,
            hints: hints,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            sequenceNumber: sequenceNumber
        )
        broadcaster.emit(observation)
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

// MARK: - DiscoveryBehaviour

extension MDNSDiscovery: DiscoveryBehaviour {
    public func attach(to context: any NodeContext) async {
        do {
            try await start()
        } catch {
            // mDNS start failure is non-fatal — service simply won't discover peers
        }
    }

    // shutdown(): already defined as async method
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
    /// Service browser reported an operational error.
    case browserError(DNSError)
}
