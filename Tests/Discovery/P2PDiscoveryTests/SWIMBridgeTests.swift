import Testing
import Foundation
@testable import P2PDiscoverySWIM
@testable import P2PDiscovery
@testable import P2PCore
import SWIM

@Suite("SWIMBridge Tests")
struct SWIMBridgeTests {

    // MARK: - MemberID Conversion Tests

    @Test("Convert PeerID and address to MemberID")
    func toMemberID() throws {
        let keyPair = KeyPair.generateEd25519()
        let peerID = keyPair.peerID
        let address = try Multiaddr("/ip4/127.0.0.1/udp/7946")

        let memberID = SWIMBridge.toMemberID(peerID: peerID, address: address)

        #expect(memberID.id == peerID.description)
        #expect(memberID.address == address.description)
    }

    @Test("Convert MemberID back to PeerID")
    func toPeerID() throws {
        let keyPair = KeyPair.generateEd25519()
        let peerID = keyPair.peerID
        let address = try Multiaddr("/ip4/127.0.0.1/udp/7946")

        let memberID = SWIMBridge.toMemberID(peerID: peerID, address: address)
        let convertedPeerID = SWIMBridge.toPeerID(memberID: memberID)

        #expect(convertedPeerID == peerID)
    }

    @Test("Convert MemberID to Multiaddr")
    func toMultiaddr() throws {
        let keyPair = KeyPair.generateEd25519()
        let peerID = keyPair.peerID
        let address = try Multiaddr("/ip4/127.0.0.1/udp/7946")

        let memberID = SWIMBridge.toMemberID(peerID: peerID, address: address)
        let convertedAddr = SWIMBridge.toMultiaddr(memberID: memberID)

        #expect(convertedAddr == address)
    }

    @Test("Invalid PeerID string returns nil")
    func invalidPeerIDReturnsNil() {
        let memberID = MemberID(id: "invalid-peer-id", address: "/ip4/127.0.0.1/udp/7946")
        let peerID = SWIMBridge.toPeerID(memberID: memberID)

        #expect(peerID == nil)
    }

    @Test("Invalid Multiaddr string returns nil")
    func invalidMultiaddrReturnsNil() {
        let keyPair = KeyPair.generateEd25519()
        let memberID = MemberID(id: keyPair.peerID.description, address: "invalid-address")
        let addr = SWIMBridge.toMultiaddr(memberID: memberID)

        #expect(addr == nil)
    }

    // MARK: - ScoredCandidate Conversion Tests

    @Test("Convert alive member to scored candidate with score 1.0")
    func aliveMemberScore() throws {
        let keyPair = KeyPair.generateEd25519()
        let peerID = keyPair.peerID
        let address = try Multiaddr("/ip4/127.0.0.1/udp/7946")

        let memberID = SWIMBridge.toMemberID(peerID: peerID, address: address)
        let member = Member(id: memberID, status: .alive, incarnation: 0)

        let candidate = SWIMBridge.toScoredCandidate(member: member)

        #expect(candidate != nil)
        #expect(candidate?.peerID == peerID)
        #expect(candidate?.score == 1.0)
        #expect(candidate?.addresses.count == 1)
    }

    @Test("Convert suspect member to scored candidate with score 0.5")
    func suspectMemberScore() throws {
        let keyPair = KeyPair.generateEd25519()
        let peerID = keyPair.peerID
        let address = try Multiaddr("/ip4/127.0.0.1/udp/7946")

        let memberID = SWIMBridge.toMemberID(peerID: peerID, address: address)
        let member = Member(id: memberID, status: .suspect, incarnation: 0)

        let candidate = SWIMBridge.toScoredCandidate(member: member)

        #expect(candidate != nil)
        #expect(candidate?.score == 0.5)
    }

    @Test("Convert dead member to scored candidate with score 0.0")
    func deadMemberScore() throws {
        let keyPair = KeyPair.generateEd25519()
        let peerID = keyPair.peerID
        let address = try Multiaddr("/ip4/127.0.0.1/udp/7946")

        let memberID = SWIMBridge.toMemberID(peerID: peerID, address: address)
        let member = Member(id: memberID, status: .dead, incarnation: 0)

        let candidate = SWIMBridge.toScoredCandidate(member: member)

        #expect(candidate != nil)
        #expect(candidate?.score == 0.0)
    }

    @Test("Invalid member returns nil candidate")
    func invalidMemberReturnsNil() {
        let memberID = MemberID(id: "invalid-peer-id", address: "/ip4/127.0.0.1/udp/7946")
        let member = Member(id: memberID, status: .alive, incarnation: 0)

        let candidate = SWIMBridge.toScoredCandidate(member: member)

        #expect(candidate == nil)
    }

    // MARK: - Observation Conversion Tests

    @Test("Convert memberJoined event to reachable observation")
    func memberJoinedToObservation() throws {
        let observerKeyPair = KeyPair.generateEd25519()
        let observer = observerKeyPair.peerID

        let subjectKeyPair = KeyPair.generateEd25519()
        let subject = subjectKeyPair.peerID
        let address = try Multiaddr("/ip4/127.0.0.1/udp/7946")

        let memberID = SWIMBridge.toMemberID(peerID: subject, address: address)
        let member = Member(id: memberID, status: .alive, incarnation: 0)
        let event = SWIMEvent.memberJoined(member)

        let observation = SWIMBridge.toObservation(
            event: event,
            observer: observer,
            sequenceNumber: 1
        )

        #expect(observation != nil)
        #expect(observation?.subject == subject)
        #expect(observation?.observer == observer)
        #expect(observation?.kind == .reachable)
        #expect(observation?.sequenceNumber == 1)
        #expect(observation?.hints.count == 1)
    }

    @Test("Convert memberRecovered event to reachable observation")
    func memberRecoveredToObservation() throws {
        let observerKeyPair = KeyPair.generateEd25519()
        let observer = observerKeyPair.peerID

        let subjectKeyPair = KeyPair.generateEd25519()
        let subject = subjectKeyPair.peerID
        let address = try Multiaddr("/ip4/127.0.0.1/udp/7946")

        let memberID = SWIMBridge.toMemberID(peerID: subject, address: address)
        let member = Member(id: memberID, status: .alive, incarnation: 1)
        let event = SWIMEvent.memberRecovered(member)

        let observation = SWIMBridge.toObservation(
            event: event,
            observer: observer,
            sequenceNumber: 2
        )

        #expect(observation != nil)
        #expect(observation?.kind == .reachable)
    }

    @Test("Convert memberSuspected event to unreachable observation")
    func memberSuspectedToObservation() throws {
        let observerKeyPair = KeyPair.generateEd25519()
        let observer = observerKeyPair.peerID

        let subjectKeyPair = KeyPair.generateEd25519()
        let subject = subjectKeyPair.peerID
        let address = try Multiaddr("/ip4/127.0.0.1/udp/7946")

        let memberID = SWIMBridge.toMemberID(peerID: subject, address: address)
        let member = Member(id: memberID, status: .suspect, incarnation: 0)
        let event = SWIMEvent.memberSuspected(member)

        let observation = SWIMBridge.toObservation(
            event: event,
            observer: observer,
            sequenceNumber: 3
        )

        #expect(observation != nil)
        #expect(observation?.kind == .unreachable)
    }

    @Test("Convert memberFailed event to unreachable observation")
    func memberFailedToObservation() throws {
        let observerKeyPair = KeyPair.generateEd25519()
        let observer = observerKeyPair.peerID

        let subjectKeyPair = KeyPair.generateEd25519()
        let subject = subjectKeyPair.peerID
        let address = try Multiaddr("/ip4/127.0.0.1/udp/7946")

        let memberID = SWIMBridge.toMemberID(peerID: subject, address: address)
        let member = Member(id: memberID, status: .dead, incarnation: 0)
        let event = SWIMEvent.memberFailed(member)

        let observation = SWIMBridge.toObservation(
            event: event,
            observer: observer,
            sequenceNumber: 4
        )

        #expect(observation != nil)
        #expect(observation?.kind == .unreachable)
    }

    @Test("Convert memberLeft event to unreachable observation")
    func memberLeftToObservation() throws {
        let observerKeyPair = KeyPair.generateEd25519()
        let observer = observerKeyPair.peerID

        let subjectKeyPair = KeyPair.generateEd25519()
        let subject = subjectKeyPair.peerID
        let address = try Multiaddr("/ip4/127.0.0.1/udp/7946")

        let memberID = SWIMBridge.toMemberID(peerID: subject, address: address)
        let event = SWIMEvent.memberLeft(memberID)

        let observation = SWIMBridge.toObservation(
            event: event,
            observer: observer,
            sequenceNumber: 5
        )

        #expect(observation != nil)
        #expect(observation?.subject == subject)
        #expect(observation?.kind == .unreachable)
    }

    @Test("incarnationIncremented event returns nil observation")
    func incarnationIncrementedReturnsNil() {
        let observerKeyPair = KeyPair.generateEd25519()
        let observer = observerKeyPair.peerID

        let event = SWIMEvent.incarnationIncremented(1)

        let observation = SWIMBridge.toObservation(
            event: event,
            observer: observer,
            sequenceNumber: 6
        )

        #expect(observation == nil)
    }

    @Test("error event returns nil observation")
    func errorEventReturnsNil() {
        let observerKeyPair = KeyPair.generateEd25519()
        let observer = observerKeyPair.peerID

        struct MockError: Error {}
        let memberID = MemberID(id: "test", address: "test")
        let event = SWIMEvent.error(.sendFailed(to: memberID, underlying: MockError()))

        let observation = SWIMBridge.toObservation(
            event: event,
            observer: observer,
            sequenceNumber: 7
        )

        #expect(observation == nil)
    }

    // MARK: - Round-trip Tests

    @Test("PeerID round-trip through MemberID")
    func peerIDRoundTrip() throws {
        let keyPair = KeyPair.generateEd25519()
        let originalPeerID = keyPair.peerID
        let address = try Multiaddr("/ip4/192.168.1.100/udp/7946")

        let memberID = SWIMBridge.toMemberID(peerID: originalPeerID, address: address)
        let recoveredPeerID = SWIMBridge.toPeerID(memberID: memberID)

        #expect(recoveredPeerID == originalPeerID)
    }

    @Test("Multiaddr round-trip through MemberID")
    func multiaddrRoundTrip() throws {
        let keyPair = KeyPair.generateEd25519()
        let peerID = keyPair.peerID
        let originalAddr = try Multiaddr("/ip4/10.0.0.1/udp/7946")

        let memberID = SWIMBridge.toMemberID(peerID: peerID, address: originalAddr)
        let recoveredAddr = SWIMBridge.toMultiaddr(memberID: memberID)

        #expect(recoveredAddr == originalAddr)
    }
}
