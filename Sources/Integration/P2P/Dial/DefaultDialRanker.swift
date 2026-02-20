/// DefaultDialRanker - Happy Eyeballs (RFC 8305) style address ranking
///
/// Priority order:
/// 1. QUIC IPv6 (best case: encrypted, multiplexed, modern)
/// 2. QUIC IPv4 (after 250ms delay)
/// 3. TCP IPv6 (after 250ms delay)
/// 4. TCP IPv4 (after 250ms delay)

import P2PCore

public final class DefaultDialRanker: DialRanker, Sendable {

    /// Delay between each group.
    public let groupDelay: Duration

    /// Delay before starting relay addresses (after all direct groups).
    public let relayDelay: Duration

    public init(
        groupDelay: Duration = .milliseconds(250),
        relayDelay: Duration = .milliseconds(500)
    ) {
        self.groupDelay = groupDelay
        self.relayDelay = relayDelay
    }

    public func rankAddresses(_ addresses: [Multiaddr]) -> [DialGroup] {
        var quicIPv6: [Multiaddr] = []
        var quicIPv4: [Multiaddr] = []
        var tcpIPv6: [Multiaddr] = []
        var tcpIPv4: [Multiaddr] = []
        var other: [Multiaddr] = []
        var relay: [Multiaddr] = []

        for addr in addresses {
            if isCircuitRelay(addr) {
                relay.append(addr)
                continue
            }
            let isV6 = isIPv6(addr)
            if isQUIC(addr) {
                if isV6 { quicIPv6.append(addr) }
                else { quicIPv4.append(addr) }
            } else if isTCP(addr) {
                if isV6 { tcpIPv6.append(addr) }
                else { tcpIPv4.append(addr) }
            } else {
                other.append(addr)
            }
        }

        var groups: [DialGroup] = []

        if !quicIPv6.isEmpty {
            groups.append(DialGroup(addresses: quicIPv6, delay: .zero))
        }
        if !quicIPv4.isEmpty {
            groups.append(DialGroup(addresses: quicIPv4, delay: groups.isEmpty ? .zero : groupDelay))
        }
        if !tcpIPv6.isEmpty {
            groups.append(DialGroup(addresses: tcpIPv6, delay: groups.isEmpty ? .zero : groupDelay))
        }
        if !tcpIPv4.isEmpty {
            groups.append(DialGroup(addresses: tcpIPv4, delay: groups.isEmpty ? .zero : groupDelay))
        }
        if !other.isEmpty {
            groups.append(DialGroup(addresses: other, delay: groups.isEmpty ? .zero : groupDelay))
        }
        if !relay.isEmpty {
            groups.append(DialGroup(addresses: relay, delay: groups.isEmpty ? .zero : relayDelay))
        }

        return groups
    }

    // MARK: - Private

    private func isIPv6(_ addr: Multiaddr) -> Bool {
        addr.protocols.contains { if case .ip6 = $0 { return true }; return false }
    }

    private func isQUIC(_ addr: Multiaddr) -> Bool {
        addr.protocols.contains { proto in
            switch proto {
            case .quic, .quicV1: return true
            default: return false
            }
        }
    }

    private func isTCP(_ addr: Multiaddr) -> Bool {
        addr.protocols.contains { if case .tcp = $0 { return true }; return false }
    }

    private func isCircuitRelay(_ addr: Multiaddr) -> Bool {
        addr.protocols.contains { if case .p2pCircuit = $0 { return true }; return false }
    }
}
