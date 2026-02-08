/// ObservedAddressManager - Tracks externally observed addresses
///
/// When other peers tell us via Identify what address they see us as,
/// we track these observations. An address is "confirmed" when enough
/// distinct peers report the same thin-waist group (same IP + transport
/// type, regardless of port).

import P2PCore
import Synchronization

public final class ObservedAddressManager: Sendable {

    /// Minimum observations from distinct peers needed to confirm an address.
    public let confirmationThreshold: Int

    /// How long observations remain valid before expiring.
    public let observationTTL: Duration

    private let state: Mutex<State>

    private struct Observation: Sendable {
        let address: Multiaddr
        let observer: PeerID
        let localAddress: Multiaddr
        let timestamp: ContinuousClock.Instant
    }

    private struct State: Sendable {
        var observations: [Observation] = []
    }

    public init(
        confirmationThreshold: Int = 4,
        observationTTL: Duration = .seconds(1800)  // 30 min
    ) {
        self.confirmationThreshold = confirmationThreshold
        self.observationTTL = observationTTL
        self.state = Mutex(State())
    }

    /// Records an observation from a remote peer.
    ///
    /// - Parameters:
    ///   - observed: The address the remote peer reports seeing us as
    ///   - observer: The PeerID of the observing peer
    ///   - localAddr: Our local address for the connection that produced this observation
    public func recordObservation(observed: Multiaddr, by observer: PeerID, localAddr: Multiaddr) {
        let now = ContinuousClock.now
        state.withLock { s in
            // Remove expired observations
            s.observations.removeAll { now - $0.timestamp > observationTTL }

            // Remove previous observation from the same observer for the same local address.
            // A given peer should only contribute one observation per local endpoint.
            s.observations.removeAll {
                $0.observer == observer && $0.localAddress == localAddr
            }

            // Add new observation
            s.observations.append(Observation(
                address: observed,
                observer: observer,
                localAddress: localAddr,
                timestamp: now
            ))
        }
    }

    /// Returns addresses confirmed by enough distinct observers.
    ///
    /// Observations are grouped by thin-waist (same IP family + transport type,
    /// regardless of port). A group is confirmed when the number of distinct
    /// observers meets or exceeds `confirmationThreshold`. The most commonly
    /// reported specific address within each confirmed group is returned.
    public func confirmedAddresses() -> [Multiaddr] {
        let now = ContinuousClock.now
        return state.withLock { s in
            // Remove expired
            s.observations.removeAll { now - $0.timestamp > observationTTL }

            // Group by thin-waist (IP + transport type)
            var groups: [String: [Observation]] = [:]
            for obs in s.observations {
                let key = thinWaistKey(obs.address)
                groups[key, default: []].append(obs)
            }

            // Find groups with enough distinct observers
            var confirmed: [Multiaddr] = []
            for (_, observations) in groups {
                let distinctObservers = Set(observations.map(\.observer))
                if distinctObservers.count >= confirmationThreshold {
                    // Use the most common specific address in this group
                    if let best = mostCommonAddress(observations) {
                        confirmed.append(best)
                    }
                }
            }
            return confirmed
        }
    }

    /// Returns all observed addresses with the count of distinct observers for each.
    ///
    /// Results are sorted by count in descending order.
    public func allObservedAddresses() -> [(address: Multiaddr, count: Int)] {
        let now = ContinuousClock.now
        return state.withLock { s in
            s.observations.removeAll { now - $0.timestamp > observationTTL }

            var counts: [Multiaddr: Set<PeerID>] = [:]
            for obs in s.observations {
                counts[obs.address, default: []].insert(obs.observer)
            }

            return counts.map { (address: $0.key, count: $0.value.count) }
                .sorted { $0.count > $1.count }
        }
    }

    /// Removes all observations.
    public func reset() {
        state.withLock { $0.observations.removeAll() }
    }

    // MARK: - Private

    /// Extracts a thin-waist grouping key from a multiaddr.
    ///
    /// Groups addresses by IP family + IP address + transport protocol,
    /// ignoring port numbers. For example, `/ip4/1.2.3.4/tcp/4001` and
    /// `/ip4/1.2.3.4/tcp/5001` produce the same key: `"ip4/1.2.3.4/tcp"`.
    private func thinWaistKey(_ addr: Multiaddr) -> String {
        var parts: [String] = []
        for proto in addr.protocols {
            switch proto {
            case .ip4(let ip):
                parts.append("ip4/\(ip)")
            case .ip6(let ip):
                parts.append("ip6/\(ip)")
            case .tcp:
                parts.append("tcp")
            case .udp:
                parts.append("udp")
            case .quic, .quicV1:
                parts.append("quic")
            default:
                continue
            }
        }
        return parts.joined(separator: "/")
    }

    /// Returns the most frequently reported address among a set of observations.
    private func mostCommonAddress(_ observations: [Observation]) -> Multiaddr? {
        var counts: [Multiaddr: Int] = [:]
        for obs in observations {
            counts[obs.address, default: 0] += 1
        }
        return counts.max(by: { $0.value < $1.value })?.key
    }
}
