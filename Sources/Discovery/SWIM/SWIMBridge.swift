/// P2PDiscoverySWIM - Bridge between SWIM types and P2P types
import Foundation
import P2PCore
import P2PDiscovery
import SWIM

/// Bridges between SWIM protocol types and libp2p types.
public enum SWIMBridge {

    // MARK: - PeerID <-> MemberID Conversion

    /// Creates a SWIM MemberID from a PeerID and address.
    ///
    /// Extracts host and port from the Multiaddr to produce a `host:port` string
    /// compatible with `SWIMTransportAdapter.send()` which uses `SocketAddress(hostPort:)`.
    ///
    /// - Parameters:
    ///   - peerID: The peer ID.
    ///   - address: The multiaddress for this peer.
    /// - Returns: A SWIM MemberID with address in `host:port` format.
    public static func toMemberID(peerID: PeerID, address: Multiaddr) -> MemberID {
        let hostPort = extractHostPort(from: address) ?? address.description
        return MemberID(id: peerID.description, address: hostPort)
    }

    /// Extracts `host:port` from a Multiaddr (e.g., `/ip4/127.0.0.1/udp/17947` → `"127.0.0.1:17947"`).
    ///
    /// Supports `/ip4/.../udp/...` and `/ip4/.../tcp/...` (and ip6 equivalents).
    ///
    /// - Parameter address: The multiaddress to extract from.
    /// - Returns: A `host:port` string, or nil if extraction fails.
    private static func extractHostPort(from address: Multiaddr) -> String? {
        var host: String?
        var port: UInt16?

        for proto in address.protocols {
            switch proto {
            case .ip4(let addr):
                host = addr
            case .ip6(let addr):
                host = addr
            case .udp(let p):
                port = p
            case .tcp(let p):
                port = p
            default:
                break
            }
        }

        guard let h = host, let p = port else { return nil }
        return "\(h):\(p)"
    }

    /// Creates a PeerID from a SWIM MemberID.
    ///
    /// - Parameter memberID: The SWIM member ID.
    /// - Returns: A PeerID, or nil if parsing fails.
    public static func toPeerID(memberID: MemberID) -> PeerID? {
        do {
            return try PeerID(string: memberID.id)
        } catch {
            return nil
        }
    }

    /// Creates a Multiaddr from a MemberID's address.
    ///
    /// Handles both `host:port` format (from toMemberID) and Multiaddr string format.
    ///
    /// - Parameter memberID: The SWIM member ID.
    /// - Returns: A Multiaddr, or nil if parsing fails.
    public static func toMultiaddr(memberID: MemberID) -> Multiaddr? {
        let address = memberID.address

        // Try host:port format first (produced by toMemberID)
        if !address.hasPrefix("/"), let lastColon = address.lastIndex(of: ":") {
            let host = String(address[address.startIndex..<lastColon])
            let portStr = String(address[address.index(after: lastColon)...])
            if let port = UInt16(portStr) {
                do {
                    return try Multiaddr("/ip4/\(host)/udp/\(port)")
                } catch {
                    return nil
                }
            }
        }

        // Fall back to Multiaddr string format
        do {
            return try Multiaddr(address)
        } catch {
            return nil
        }
    }

    // MARK: - Member -> ScoredCandidate Conversion

    /// Converts a SWIM Member to a ScoredCandidate.
    ///
    /// The score is calculated based on the member's status:
    /// - Alive: 1.0
    /// - Suspect: 0.5
    /// - Dead: 0.0
    ///
    /// - Parameter member: The SWIM member.
    /// - Returns: A ScoredCandidate, or nil if conversion fails.
    public static func toScoredCandidate(member: Member) -> ScoredCandidate? {
        guard let peerID = toPeerID(memberID: member.id) else {
            return nil
        }

        var addresses: [Multiaddr] = []
        if let addr = toMultiaddr(memberID: member.id) {
            addresses.append(addr)
        }

        let score: Double = switch member.status {
        case .alive: 1.0
        case .suspect: 0.5
        case .dead: 0.0
        }

        return ScoredCandidate(
            peerID: peerID,
            addresses: addresses,
            score: score
        )
    }

    // MARK: - SWIMEvent -> Observation Conversion

    /// Converts a SWIM event to an Observation.
    ///
    /// - Parameters:
    ///   - event: The SWIM event.
    ///   - observer: The local peer ID observing the event.
    ///   - sequenceNumber: The sequence number for ordering.
    /// - Returns: An Observation, or nil if conversion fails or event is not relevant.
    public static func toObservation(
        event: SWIMEvent,
        observer: PeerID,
        sequenceNumber: UInt64
    ) -> PeerObservation? {
        switch event {
        case .memberJoined(let member):
            return memberToObservation(
                member: member,
                kind: .reachable,
                observer: observer,
                sequenceNumber: sequenceNumber
            )

        case .memberRecovered(let member):
            return memberToObservation(
                member: member,
                kind: .reachable,
                observer: observer,
                sequenceNumber: sequenceNumber
            )

        case .memberSuspected(let member):
            // Suspected is a soft unreachable - still might recover
            return memberToObservation(
                member: member,
                kind: .unreachable,
                observer: observer,
                sequenceNumber: sequenceNumber
            )

        case .memberFailed(let member):
            return memberToObservation(
                member: member,
                kind: .unreachable,
                observer: observer,
                sequenceNumber: sequenceNumber
            )

        case .memberLeft(let memberID):
            guard let peerID = toPeerID(memberID: memberID) else {
                return nil
            }

            var hints: [Multiaddr] = []
            if let addr = toMultiaddr(memberID: memberID) {
                hints.append(addr)
            }

            return PeerObservation(
                subject: peerID,
                observer: observer,
                kind: .unreachable,
                hints: hints,
                timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                sequenceNumber: sequenceNumber
            )

        case .memberRemoved(let memberID):
            guard let peerID = toPeerID(memberID: memberID) else {
                return nil
            }

            var hints: [Multiaddr] = []
            if let addr = toMultiaddr(memberID: memberID) {
                hints.append(addr)
            }

            return PeerObservation(
                subject: peerID,
                observer: observer,
                kind: .unreachable,
                hints: hints,
                timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
                sequenceNumber: sequenceNumber
            )

        case .incarnationIncremented:
            // Internal event, not relevant for observations
            return nil

        case .error:
            // Error events don't map to observations
            return nil
        }
    }

    // MARK: - Private Helpers

    private static func memberToObservation(
        member: Member,
        kind: PeerObservation.Kind,
        observer: PeerID,
        sequenceNumber: UInt64
    ) -> PeerObservation? {
        guard let peerID = toPeerID(memberID: member.id) else {
            return nil
        }

        var hints: [Multiaddr] = []
        if let addr = toMultiaddr(memberID: member.id) {
            hints.append(addr)
        }

        return PeerObservation(
            subject: peerID,
            observer: observer,
            kind: kind,
            hints: hints,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            sequenceNumber: sequenceNumber
        )
    }
}
