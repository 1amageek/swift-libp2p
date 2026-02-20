/// P2PDiscoverySWIM - SWIM-based membership and failure detection
import Foundation
import P2PCore
import P2PDiscovery
import SWIM
import NIOUDPTransport
import Synchronization

/// Configuration for SWIM-based membership.
public struct SWIMMembershipConfiguration: Sendable {

    /// The UDP port for SWIM protocol messages.
    public var port: Int

    /// The host address to bind to (e.g., "0.0.0.0" to listen on all interfaces).
    public var bindHost: String

    /// The host address to advertise to other peers.
    /// If nil, a routable address will be auto-detected.
    /// Must be a routable address (not "0.0.0.0" or "::").
    public var advertisedHost: String?

    /// SWIM protocol configuration.
    public var swimConfig: SWIMConfiguration

    public init(
        port: Int = 7946,
        bindHost: String = "0.0.0.0",
        advertisedHost: String? = nil,
        swimConfig: SWIMConfiguration = .default
    ) {
        self.port = port
        self.bindHost = bindHost
        self.advertisedHost = advertisedHost
        self.swimConfig = swimConfig
    }

    /// Legacy initializer for backwards compatibility.
    @available(*, deprecated, renamed: "init(port:bindHost:advertisedHost:swimConfig:)")
    public init(
        port: Int = 7946,
        host: String,
        swimConfig: SWIMConfiguration = .default
    ) {
        self.port = port
        self.bindHost = host
        // If host is not 0.0.0.0, use it as advertised address too
        self.advertisedHost = (host == "0.0.0.0" || host == "::") ? nil : host
        self.swimConfig = swimConfig
    }

    /// Default configuration.
    public static let `default` = SWIMMembershipConfiguration()
}

/// SWIM-based membership management and failure detection.
///
/// Uses the SWIM protocol to track cluster membership and detect failed nodes.
/// Integrates with the P2P discovery system through the DiscoveryService protocol.
public actor SWIMMembership: DiscoveryService {

    // MARK: - Properties

    private let localPeerID: PeerID
    private let configuration: SWIMMembershipConfiguration
    private var transport: SWIMTransportAdapter?
    private var swim: SWIMInstance?

    private var isStarted = false
    private var sequenceNumber: UInt64 = 0
    private var localAddress: Multiaddr?
    private var forwardTask: Task<Void, Never>?

    private nonisolated let broadcaster = EventBroadcaster<Observation>()

    // MARK: - Initialization

    /// Creates a new SWIM membership service.
    ///
    /// - Parameters:
    ///   - localPeerID: The local peer's ID.
    ///   - configuration: Configuration options.
    public init(
        localPeerID: PeerID,
        configuration: SWIMMembershipConfiguration = .default
    ) {
        self.localPeerID = localPeerID
        self.configuration = configuration
    }

    deinit {
        broadcaster.shutdown()
    }

    // MARK: - Lifecycle

    /// Starts the SWIM membership service.
    public func start() async throws {
        guard !isStarted else {
            throw SWIMMembershipError.alreadyStarted
        }

        // Create and start transport (binds to bindHost)
        let transport = SWIMTransportAdapter(
            port: configuration.port,
            host: configuration.bindHost
        )
        try await transport.start()
        self.transport = transport

        // Determine the advertised address (must be routable)
        let advertisedHost = try resolveAdvertisedHost()

        // Create local member with routable advertised address
        let localMember = Member(
            id: SWIMBridge.toMemberID(
                peerID: localPeerID,
                address: try Multiaddr("/ip4/\(advertisedHost)/udp/\(configuration.port)")
            )
        )

        // Create SWIM instance
        let swim = SWIMInstance(
            localMember: localMember,
            config: configuration.swimConfig,
            transport: transport
        )
        self.swim = swim

        // Start SWIM protocol
        await swim.start()
        isStarted = true

        // Store local address (advertised, not bind)
        self.localAddress = try Multiaddr("/ip4/\(advertisedHost)/udp/\(configuration.port)")

        // Start event forwarding
        forwardTask = Task { [weak self] in
            guard let self = self else { return }
            await self.forwardSWIMEvents()
        }
    }

    /// Resolves the host address to advertise to other peers.
    ///
    /// - Returns: A routable IP address
    /// - Throws: `SWIMMembershipError.noRoutableAddress` if no routable address found
    private func resolveAdvertisedHost() throws -> String {
        // If explicitly configured, use that (but validate it's routable)
        if let configured = configuration.advertisedHost {
            guard !Self.isUnroutableAddress(configured) else {
                throw SWIMMembershipError.unroutableAddress(configured)
            }
            return configured
        }

        // If bind host is routable, use it
        if !Self.isUnroutableAddress(configuration.bindHost) {
            return configuration.bindHost
        }

        // Auto-detect a routable local address
        if let detected = Self.detectRoutableAddress() {
            return detected
        }

        throw SWIMMembershipError.noRoutableAddress
    }

    /// Checks if an address is unroutable (bind-only).
    private static func isUnroutableAddress(_ address: String) -> Bool {
        address == "0.0.0.0" || address == "::" || address == "0:0:0:0:0:0:0:0"
    }

    /// Attempts to detect a routable local IPv4 address.
    private static func detectRoutableAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            return nil
        }
        defer { freeifaddrs(ifaddr) }

        var result: String?

        var current = firstAddr
        while true {
            let interface = current.pointee

            // Only consider AF_INET (IPv4) for now
            if let ifaAddr = interface.ifa_addr, ifaAddr.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)

                // Skip loopback
                if name != "lo0" && name != "lo" {
                    var addr = ifaAddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                    var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    inet_ntop(AF_INET, &addr.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN))
                    let addressString = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)

                    // Skip link-local addresses (169.254.x.x)
                    if !addressString.hasPrefix("169.254.") && !addressString.hasPrefix("127.") {
                        // Prefer en0 (primary interface on macOS)
                        if name == "en0" {
                            return addressString
                        }
                        // Otherwise, keep the first non-loopback address found
                        if result == nil {
                            result = addressString
                        }
                    }
                }
            }

            guard let next = interface.ifa_next else { break }
            current = next
        }

        return result
    }

    /// Shuts down the SWIM membership service.
    public func shutdown() async {
        guard isStarted else { return }

        forwardTask?.cancel()
        forwardTask = nil

        await swim?.leave()
        await swim?.shutdown()
        await transport?.shutdown()

        swim = nil
        transport = nil
        isStarted = false
        sequenceNumber = 0
        broadcaster.shutdown()
    }

    // MARK: - SWIM-specific Methods

    /// Joins the cluster by contacting seed peers.
    ///
    /// - Parameter seeds: Peer IDs of seed nodes to contact.
    public func join(seeds: [(PeerID, Multiaddr)]) async throws {
        guard isStarted, let swim = swim else {
            throw SWIMMembershipError.notStarted
        }

        let seedMemberIDs = seeds.map { (peerID, address) in
            SWIMBridge.toMemberID(peerID: peerID, address: address)
        }

        try await swim.join(seeds: seedMemberIDs)
    }

    /// Gracefully leaves the cluster.
    public func leave() async {
        await swim?.leave()
    }

    /// Returns all current members.
    public var members: [Member] {
        get async {
            await swim?.members ?? []
        }
    }

    /// Returns the count of alive members.
    public var aliveCount: Int {
        get async {
            await swim?.aliveCount ?? 0
        }
    }

    // MARK: - DiscoveryService Protocol

    /// Announces our presence (SWIM uses join instead).
    public func announce(addresses: [Multiaddr]) async throws {
        // SWIM doesn't use explicit announcements - membership is managed through join
        // Store the addresses for reference
        if let first = addresses.first {
            self.localAddress = first
        }
    }

    /// Finds candidates for a specific peer.
    public func find(peer: PeerID) async throws -> [ScoredCandidate] {
        guard let swim = swim else {
            return []
        }

        let targetID = peer.description
        let members = await swim.members

        return members.compactMap { member -> ScoredCandidate? in
            guard member.id.id == targetID else { return nil }
            return SWIMBridge.toScoredCandidate(member: member)
        }
    }

    /// Subscribes to observations about a specific peer.
    nonisolated public func subscribe(to peer: PeerID) -> AsyncStream<Observation> {
        let targetID = peer.description
        // Capture nonisolated property before Task to avoid actor hop
        let observationStream = self.observations

        return AsyncStream { continuation in
            Task {
                for await observation in observationStream {
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
        guard let swim = swim else { return [] }

        let members = await swim.members
        return members.compactMap { member in
            SWIMBridge.toPeerID(memberID: member.id)
        }.filter { $0 != localPeerID }
    }

    /// Returns all observations as a stream.
    /// Each call returns an independent stream (multi-consumer safe).
    public nonisolated var observations: AsyncStream<Observation> {
        broadcaster.subscribe()
    }

    // MARK: - Private Methods

    private func forwardSWIMEvents() async {
        guard let swim = swim else { return }

        let events = swim.events
        for await event in events {
            sequenceNumber += 1

            if let observation = SWIMBridge.toObservation(
                event: event,
                observer: localPeerID,
                sequenceNumber: sequenceNumber
            ) {
                broadcaster.emit(observation)
            }
        }
    }
}

// MARK: - Errors

/// Errors that can occur in SWIM membership.
public enum SWIMMembershipError: Error, Sendable {
    /// The service has not been started.
    case notStarted
    /// The service is already started.
    case alreadyStarted
    /// Failed to join the cluster.
    case joinFailed(String)
    /// Transport error.
    case transportError(String)
    /// No routable address could be determined for advertising.
    case noRoutableAddress
    /// The specified address is not routable.
    case unroutableAddress(String)
}
