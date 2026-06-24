/// P2PDiscoveryMDNS - mDNS-based peer discovery for local networks
import Foundation
import P2PCore
import P2PDiscovery
import P2PProtocols
import MDNS
import Synchronization
import Logging

/// mDNS-based peer discovery for local area networks.
///
/// Uses Multicast DNS (RFC 6762) and DNS-SD (RFC 6763) to discover
/// and advertise libp2p peers on the local network.
///
/// ## Removal detection (not surfaced by the new facade)
///
/// The Tier-1 `MDNS` facade vends discovered services as a flat
/// `MDNSDiscoveries` sequence of `MDNSService` upserts. On a goodbye (TTL 0) it
/// re-emits the last-known `MDNSService` value, which is indistinguishable from
/// an add/update at the value level. Consequently this service emits only
/// `.announcement` / `.reachable` (upsert) observations and does NOT synthesize
/// `.unreachable` observations — doing so would be fabricating an event the
/// facade cannot reliably signal. `knownServicesByPeerID` is therefore an
/// upsert-only cache.
public actor MDNSDiscovery: DiscoveryService {

    // MARK: - Properties

    public let localPeerID: PeerID
    private let configuration: MDNSConfiguration
    private let advertisedServiceName: String
    private var browser: MDNSBrowser?
    private var responder: MDNSResponder?

    private var knownServicesByPeerID: [PeerID: MDNSService] = [:]
    private var peerIDByServiceName: [String: PeerID] = [:]
    private var serviceNameByPeerID: [PeerID: String] = [:]
    private var lastBrowserError: MDNSError?
    private var lastShutdownError: MDNSError?
    private var sequenceNumber: UInt64 = 0
    private var isStarted = false
    private var forwardTask: Task<Void, Never>?

    private nonisolated let broadcaster = EventBroadcaster<PeerObservation>()
    private nonisolated let logger = Logger(label: "p2p.discovery.mdns")

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
        DiscoveryServiceOwnershipRegistry.preconditionAccessible(self)
        guard !isStarted else { return }

        // Create browser configuration. The facade browser auto-starts on the
        // first `browse(_:)`; there is no separate `start()`.
        var browserConfig = MDNSBrowser.Configuration()
        browserConfig.queryInterval = configuration.queryInterval
        browserConfig.autoResolve = true
        browserConfig.useIPv4 = configuration.useIPv4
        browserConfig.useIPv6 = configuration.useIPv6
        browserConfig.networkInterface = configuration.networkInterface

        let browser = MDNSBrowser(configuration: browserConfig)
        self.browser = browser

        // Create responder configuration. The facade responder auto-starts on
        // the first `advertise(_:)`; there is no separate `start()`.
        var responderConfig = MDNSResponder.Configuration()
        responderConfig.ttl = configuration.ttl
        responderConfig.useIPv4 = configuration.useIPv4
        responderConfig.useIPv6 = configuration.useIPv6
        responderConfig.networkInterface = configuration.networkInterface

        let responder = MDNSResponder(configuration: responderConfig)
        self.responder = responder

        let discoveries: MDNSDiscoveries
        do {
            discoveries = try await browser.browse(configuration.fullServiceType)
        } catch {
            // `browse` throws `MDNSError` (typed). Browser failed to start/browse:
            // clear references and surface the failure rather than leaving a
            // half-started service. (A plain `catch` is used instead of
            // `catch let error as MDNSError`, which crashes SILGen in this
            // toolchain.)
            self.browser = nil
            self.responder = nil
            throw MDNSDiscoveryError.browserError(error)
        }

        isStarted = true
        lastBrowserError = nil

        // Start event forwarding task over the typed discovery sequence.
        forwardTask = Task { [weak self] in
            guard let self else { return }
            await self.forwardDiscoveries(discoveries)
        }
    }

    /// Shuts down the mDNS discovery service.
    public func shutdown() async throws {
        DiscoveryServiceOwnershipRegistry.preconditionAccessible(self)
        guard isStarted else { return }

        forwardTask?.cancel()
        forwardTask = nil

        // Browser/responder `stop()` do not throw; any prior browse error stays
        // recorded in `lastBrowserError`.
        if let browser {
            await browser.stop()
        }
        if let responder {
            await responder.stop()
        }
        lastShutdownError = nil

        // Clear references to allow new instances on next start()
        browser = nil
        responder = nil

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
        DiscoveryServiceOwnershipRegistry.preconditionAccessible(self)
        guard isStarted, let responder = responder else {
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

        do {
            try await responder.advertise(service)
        } catch {
            // `advertise` throws `MDNSError` (typed). A plain `catch` is used
            // instead of `catch let error as MDNSError`, which crashes SILGen in
            // this toolchain.
            throw MDNSDiscoveryError.browserError(error)
        }
    }

    /// Finds candidates for a specific peer.
    public func find(peer: PeerID) async throws -> [ScoredCandidate] {
        DiscoveryServiceOwnershipRegistry.preconditionAccessible(self)
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
        DiscoveryServiceOwnershipRegistry.preconditionAccessible(self)
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
        DiscoveryServiceOwnershipRegistry.preconditionAccessible(self)
        return Array(knownServicesByPeerID.keys)
    }

    /// Returns all observations as a stream (for general subscription).
    /// Each call returns an independent stream (multi-consumer safe).
    nonisolated public var observations: AsyncStream<PeerObservation> {
        DiscoveryServiceOwnershipRegistry.preconditionAccessible(self)
        return broadcaster.subscribe()
    }

    // MARK: - Private Methods

    /// Iterates the typed discovery sequence, upserting each yielded service.
    ///
    /// A thrown `MDNSError` is recorded in `lastBrowserError` (not swallowed) so
    /// `find(peer:)` can surface a systemic browser failure to callers.
    private func forwardDiscoveries(_ discoveries: MDNSDiscoveries) async {
        do {
            for try await service in discoveries {
                handleServiceUpsert(service)
            }
        } catch {
            // The discovery sequence throws `MDNSError` (typed). Record it (not
            // swallowed) so `find(peer:)` can surface a systemic failure. A plain
            // `catch` is used instead of `catch let error as MDNSError`, which
            // crashes SILGen in this toolchain.
            lastBrowserError = error
        }
    }

    /// Upserts a discovered service into the cache and emits an observation.
    ///
    /// The facade does not distinguish add vs. update vs. goodbye at the value
    /// level (see the type doc), so every yielded service is treated as a
    /// `.reachable` upsert when already known, otherwise `.announcement`.
    private func handleServiceUpsert(_ service: MDNSService) {
        // Ignore our own advertised service.
        guard service.name != advertisedServiceName,
              service.name != localPeerID.description else { return }

        sequenceNumber += 1

        let kind: PeerObservation.Kind
        do {
            let peerID = try PeerIDServiceCodec.inferPeerID(from: service)
            kind = knownServicesByPeerID[peerID] == nil ? .announcement : .reachable

            let observation = try PeerIDServiceCodec.toObservation(
                service: service,
                kind: kind,
                observer: localPeerID,
                sequenceNumber: sequenceNumber
            )
            lastBrowserError = nil
            if let previousName = serviceNameByPeerID[peerID], previousName != service.name {
                peerIDByServiceName.removeValue(forKey: previousName)
            }
            knownServicesByPeerID[peerID] = service
            peerIDByServiceName[service.name] = peerID
            serviceNameByPeerID[peerID] = service.name
            broadcaster.emit(observation)
        } catch {
            // Invalid service name / not a valid libp2p peer - skip
            // (per-element validation, not a systemic failure).
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

extension MDNSDiscovery {
    public func activate() async {
        do {
            try await start()
        } catch {
            // mDNS start failure is non-fatal (the service simply won't discover
            // peers) but must not be swallowed silently.
            logger.warning("mDNS discovery failed to start", metadata: [
                "error": "\(error)",
            ])
        }
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
    /// The mDNS browser/responder reported an operational error.
    case browserError(MDNSError)
}
