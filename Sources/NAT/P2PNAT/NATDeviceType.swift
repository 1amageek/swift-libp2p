/// NATDeviceType - NAT device type classification
///
/// Classifies the NAT behavior based on externally observed addresses.
/// Used to determine whether hole punching is feasible.

import P2PCore
import Synchronization

/// The type of NAT device, classified by endpoint mapping behavior.
///
/// - `endpointIndependent`: Cone NAT - the same external address is used regardless
///   of the destination. Hole punching is feasible.
/// - `endpointDependent`: Symmetric NAT - a different external port is assigned for
///   each destination. Hole punching is difficult or impossible.
/// - `unknown`: Not enough data to classify.
public enum NATDeviceType: Sendable, Equatable {
    /// Cone NAT - hole punching possible
    case endpointIndependent
    /// Symmetric NAT - hole punching difficult
    case endpointDependent
    /// Not enough data to determine
    case unknown
}

/// Detects NAT device type by analyzing externally observed addresses.
///
/// The detector groups observations by local listening address (the interface/port
/// we are listening on), then checks how many distinct external addresses were
/// observed for each local address. If most local addresses map to a single
/// external address, the NAT is endpoint-independent (Cone). If many distinct
/// external addresses are observed per local address, the NAT is
/// endpoint-dependent (Symmetric).
public final class NATTypeDetector: Sendable {

    /// A summary of an address observation from an external peer.
    public struct ObservationSummary: Sendable, Equatable {
        /// The local address we were listening on when this observation was made.
        public let localAddress: Multiaddr
        /// The external address the remote peer reported seeing us as.
        public let observedAddress: Multiaddr
        /// The number of distinct observers that reported this observation.
        public let observerCount: Int

        public init(localAddress: Multiaddr, observedAddress: Multiaddr, observerCount: Int) {
            self.localAddress = localAddress
            self.observedAddress = observedAddress
            self.observerCount = observerCount
        }
    }

    /// Minimum number of total observations required to make a determination.
    public let minimumObservations: Int

    /// Minimum number of distinct observers across all observations required.
    public let minimumDistinctObservers: Int

    /// The ratio threshold: if the fraction of local address groups that map
    /// to a single external address is at or above this value, the NAT is
    /// classified as endpoint-independent.
    public let independentThreshold: Double

    private let state: Mutex<State>

    private struct State: Sendable {
        var lastResult: NATDeviceType = .unknown
    }

    /// Creates a new NATTypeDetector.
    ///
    /// - Parameters:
    ///   - minimumObservations: Minimum total observations needed (default: 3)
    ///   - minimumDistinctObservers: Minimum distinct observers needed (default: 2)
    ///   - independentThreshold: Ratio of single-external groups to classify as independent (default: 0.8)
    public init(
        minimumObservations: Int = 3,
        minimumDistinctObservers: Int = 2,
        independentThreshold: Double = 0.8
    ) {
        self.minimumObservations = minimumObservations
        self.minimumDistinctObservers = minimumDistinctObservers
        self.independentThreshold = independentThreshold
        self.state = Mutex(State())
    }

    /// Detects the NAT type from a set of observation summaries.
    ///
    /// The algorithm:
    /// 1. Checks that there are enough total observations and distinct observers.
    /// 2. Groups observations by local address (the address we are listening on).
    /// 3. For each local address group, counts how many distinct external
    ///    address/port combinations were observed.
    /// 4. If most groups have exactly 1 distinct external address, the NAT is
    ///    endpoint-independent (Cone NAT).
    /// 5. If many groups have multiple distinct external addresses, the NAT is
    ///    endpoint-dependent (Symmetric NAT).
    ///
    /// - Parameter observations: The observation data to analyze
    /// - Returns: The detected NAT device type
    public func detectType(from observations: [ObservationSummary]) -> NATDeviceType {
        let result = classify(observations)
        state.withLock { $0.lastResult = result }
        return result
    }

    /// Returns the last detection result without recomputing.
    public var lastDetectedType: NATDeviceType {
        state.withLock { $0.lastResult }
    }

    // MARK: - Private

    private func classify(_ observations: [ObservationSummary]) -> NATDeviceType {
        // Check minimum total observations
        guard observations.count >= minimumObservations else {
            return .unknown
        }

        // Check minimum distinct observers
        let totalDistinctObservers = observations.reduce(0) { $0 + $1.observerCount }
        guard totalDistinctObservers >= minimumDistinctObservers else {
            return .unknown
        }

        // Group observations by local address
        var groupsByLocal: [String: Set<String>] = [:]
        for observation in observations {
            let localKey = observation.localAddress.description
            let externalKey = externalAddressKey(observation.observedAddress)
            groupsByLocal[localKey, default: []].insert(externalKey)
        }

        // Need at least one group to make a determination
        guard !groupsByLocal.isEmpty else {
            return .unknown
        }

        // Count how many groups have exactly 1 distinct external address
        let singleExternalCount = groupsByLocal.values.filter { $0.count == 1 }.count
        let totalGroups = groupsByLocal.count

        let ratio = Double(singleExternalCount) / Double(totalGroups)

        if ratio >= independentThreshold {
            return .endpointIndependent
        } else {
            return .endpointDependent
        }
    }

    /// Extracts a key for the external address including the port.
    ///
    /// For NAT type detection, the port matters: Symmetric NATs assign
    /// different ports for different destinations, while Cone NATs reuse
    /// the same external port. We include IP + port in the key.
    private func externalAddressKey(_ addr: Multiaddr) -> String {
        var parts: [String] = []
        for proto in addr.protocols {
            switch proto {
            case .ip4(let ip):
                parts.append("ip4/\(ip)")
            case .ip6(let ip):
                parts.append("ip6/\(ip)")
            case .tcp(let port):
                parts.append("tcp/\(port)")
            case .udp(let port):
                parts.append("udp/\(port)")
            case .quic, .quicV1:
                parts.append("quic")
            default:
                continue
            }
        }
        return parts.joined(separator: "/")
    }
}
