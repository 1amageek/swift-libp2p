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
    /// - Parameters:
    ///   - peerID: The peer ID.
    ///   - address: The multiaddress for this peer.
    /// - Returns: A SWIM MemberID.
    public static func toMemberID(peerID: PeerID, address: Multiaddr) -> MemberID {
        MemberID(id: peerID.description, address: address.description)
    }

    /// Creates a PeerID from a SWIM MemberID.
    ///
    /// - Parameter memberID: The SWIM member ID.
    /// - Returns: A PeerID, or nil if parsing fails.
    public static func toPeerID(memberID: MemberID) -> PeerID? {
        try? PeerID(string: memberID.id)
    }

    /// Creates a Multiaddr from a MemberID's address.
    ///
    /// - Parameter memberID: The SWIM member ID.
    /// - Returns: A Multiaddr, or nil if parsing fails.
    public static func toMultiaddr(memberID: MemberID) -> Multiaddr? {
        try? Multiaddr(memberID.address)
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
    ) -> Observation? {
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

            return Observation(
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

            return Observation(
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
        kind: Observation.Kind,
        observer: PeerID,
        sequenceNumber: UInt64
    ) -> Observation? {
        guard let peerID = toPeerID(memberID: member.id) else {
            return nil
        }

        var hints: [Multiaddr] = []
        if let addr = toMultiaddr(memberID: member.id) {
            hints.append(addr)
        }

        return Observation(
            subject: peerID,
            observer: observer,
            kind: kind,
            hints: hints,
            timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
            sequenceNumber: sequenceNumber
        )
    }
}
