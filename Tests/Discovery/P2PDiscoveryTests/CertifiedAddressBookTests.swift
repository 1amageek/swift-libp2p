import Testing
import Foundation
import Synchronization
@testable import P2PDiscovery
@testable import P2PCore

// MARK: - Test Helpers

private func makeKeyPair() -> KeyPair {
    KeyPair.generateEd25519()
}

private func makePeerID() -> PeerID {
    PeerID(publicKey: makeKeyPair().publicKey)
}

private func makeEnvelope(
    keyPair: KeyPair,
    seq: UInt64,
    addresses: [Multiaddr] = []
) throws -> Envelope {
    let record = PeerRecord.make(keyPair: keyPair, seq: seq, addresses: addresses)
    return try Envelope.seal(record: record, with: keyPair)
}

// MARK: - Accept Valid Envelope

@Suite("CertifiedAddressBook Accept/Reject")
struct CertifiedAddressBookAcceptTests {

    @Test("Accept valid envelope and retrieve record")
    func acceptValidEnvelope() throws {
        let book = CertifiedAddressBook()
        let keyPair = makeKeyPair()
        let addr = try Multiaddr("/ip4/127.0.0.1/tcp/4001")
        let envelope = try makeEnvelope(keyPair: keyPair, seq: 1, addresses: [addr])

        let accepted = try book.consumePeerRecord(envelope)

        #expect(accepted)
        let stored = book.peerRecord(for: keyPair.peerID)
        #expect(stored != nil)
        #expect(stored == envelope)
    }

    @Test("Reject tampered envelope with invalid signature")
    func rejectTamperedEnvelope() throws {
        let book = CertifiedAddressBook()
        let keyPair = makeKeyPair()
        let addr = try Multiaddr("/ip4/127.0.0.1/tcp/4001")
        let envelope = try makeEnvelope(keyPair: keyPair, seq: 1, addresses: [addr])

        // Tamper with the payload to invalidate the signature
        var tamperedPayload = envelope.payload
        if tamperedPayload.count > 0 {
            tamperedPayload[0] ^= 0xFF
        }

        // Reconstruct an envelope with tampered payload but original signature
        // We need to go through marshal/unmarshal to create the tampered envelope
        let marshaledOriginal = try envelope.marshal()
        var tamperedData = marshaledOriginal

        // Find where the payload starts and tamper with one byte in the payload region
        // Instead, let's construct a tampered envelope by manipulating the marshaled data
        // The simplest approach: flip a byte somewhere in the middle of the serialized data
        let midpoint = tamperedData.count / 2
        tamperedData[midpoint] ^= 0xFF

        // Try to unmarshal the tampered data - it might fail at unmarshal or at verify
        #expect(throws: (any Error).self) {
            let tampered = try Envelope.unmarshal(tamperedData)
            _ = try book.consumePeerRecord(tampered)
        }
    }

    @Test("Reject envelope signed by different key than record PeerID")
    func rejectPeerIDMismatch() throws {
        let book = CertifiedAddressBook()
        let recordKeyPair = makeKeyPair()
        let signerKeyPair = makeKeyPair()

        // Create a record with one key pair's PeerID but sign with another
        let record = PeerRecord.make(keyPair: recordKeyPair, seq: 1, addresses: [])
        let envelope = try Envelope.seal(record: record, with: signerKeyPair)

        #expect(throws: CertifiedAddressBookError.self) {
            _ = try book.consumePeerRecord(envelope)
        }
    }

    @Test("Reject envelope with wrong payload type")
    func rejectWrongPayloadType() throws {
        let book = CertifiedAddressBook()

        // Create a custom record type that is not a PeerRecord
        struct CustomRecord: SignedRecord {
            static let domain = "custom-record"
            static let codec = Data([0xFF, 0xFE])
            func marshal() throws -> Data { Data([0x01]) }
            static func unmarshal(_ data: Data) throws -> CustomRecord { CustomRecord() }
        }

        let keyPair = makeKeyPair()
        let customEnvelope = try Envelope.seal(record: CustomRecord(), with: keyPair)

        #expect(throws: CertifiedAddressBookError.self) {
            _ = try book.consumePeerRecord(customEnvelope)
        }
    }
}

// MARK: - Sequence Number Ordering

@Suite("CertifiedAddressBook Sequence Number Ordering")
struct CertifiedAddressBookSequenceTests {

    @Test("Accept newer record with higher sequence number")
    func acceptNewerRecord() throws {
        let book = CertifiedAddressBook()
        let keyPair = makeKeyPair()
        let addr1 = try Multiaddr("/ip4/127.0.0.1/tcp/4001")
        let addr2 = try Multiaddr("/ip4/127.0.0.1/tcp/4002")

        let envelope1 = try makeEnvelope(keyPair: keyPair, seq: 1, addresses: [addr1])
        let envelope2 = try makeEnvelope(keyPair: keyPair, seq: 2, addresses: [addr2])

        let accepted1 = try book.consumePeerRecord(envelope1)
        #expect(accepted1)

        let accepted2 = try book.consumePeerRecord(envelope2)
        #expect(accepted2)

        // Should have the newer record's addresses
        let addresses = book.certifiedAddresses(for: keyPair.peerID)
        #expect(addresses.count == 1)
        #expect(addresses.first == addr2)
    }

    @Test("Reject older record with lower sequence number")
    func rejectOlderRecord() throws {
        let book = CertifiedAddressBook()
        let keyPair = makeKeyPair()
        let addr1 = try Multiaddr("/ip4/127.0.0.1/tcp/4001")
        let addr2 = try Multiaddr("/ip4/127.0.0.1/tcp/4002")

        let envelope1 = try makeEnvelope(keyPair: keyPair, seq: 5, addresses: [addr1])
        let envelope2 = try makeEnvelope(keyPair: keyPair, seq: 3, addresses: [addr2])

        let accepted1 = try book.consumePeerRecord(envelope1)
        #expect(accepted1)

        let accepted2 = try book.consumePeerRecord(envelope2)
        #expect(!accepted2)

        // Should still have the original record's addresses
        let addresses = book.certifiedAddresses(for: keyPair.peerID)
        #expect(addresses.count == 1)
        #expect(addresses.first == addr1)
    }

    @Test("Reject record with same sequence number")
    func rejectSameSequenceNumber() throws {
        let book = CertifiedAddressBook()
        let keyPair = makeKeyPair()
        let addr1 = try Multiaddr("/ip4/127.0.0.1/tcp/4001")
        let addr2 = try Multiaddr("/ip4/127.0.0.1/tcp/4002")

        let envelope1 = try makeEnvelope(keyPair: keyPair, seq: 5, addresses: [addr1])
        let envelope2 = try makeEnvelope(keyPair: keyPair, seq: 5, addresses: [addr2])

        let accepted1 = try book.consumePeerRecord(envelope1)
        #expect(accepted1)

        let accepted2 = try book.consumePeerRecord(envelope2)
        #expect(!accepted2)

        // Should still have the first record's addresses
        let addresses = book.certifiedAddresses(for: keyPair.peerID)
        #expect(addresses.first == addr1)
    }
}

// MARK: - Address Retrieval

@Suite("CertifiedAddressBook Address Retrieval")
struct CertifiedAddressBookAddressTests {

    @Test("certifiedAddresses returns addresses from record")
    func returnsCertifiedAddresses() throws {
        let book = CertifiedAddressBook()
        let keyPair = makeKeyPair()
        let addr1 = try Multiaddr("/ip4/192.168.1.1/tcp/4001")
        let addr2 = try Multiaddr("/ip4/192.168.1.2/tcp/4002")

        let envelope = try makeEnvelope(keyPair: keyPair, seq: 1, addresses: [addr1, addr2])
        let accepted = try book.consumePeerRecord(envelope)

        #expect(accepted)
        let addresses = book.certifiedAddresses(for: keyPair.peerID)
        #expect(addresses.count == 2)
        #expect(Set(addresses) == Set([addr1, addr2]))
    }

    @Test("certifiedAddresses returns empty for unknown peer")
    func emptyForUnknownPeer() {
        let book = CertifiedAddressBook()
        let peer = makePeerID()
        let addresses = book.certifiedAddresses(for: peer)
        #expect(addresses.isEmpty)
    }

    @Test("peerRecord returns nil for unknown peer")
    func nilForUnknownPeer() {
        let book = CertifiedAddressBook()
        let peer = makePeerID()
        #expect(book.peerRecord(for: peer) == nil)
    }
}

// MARK: - All Certified Peers

@Suite("CertifiedAddressBook All Peers")
struct CertifiedAddressBookAllPeersTests {

    @Test("allCertifiedPeers lists all stored peers")
    func listsAllPeers() throws {
        let book = CertifiedAddressBook()
        let keyPair1 = makeKeyPair()
        let keyPair2 = makeKeyPair()
        let keyPair3 = makeKeyPair()

        let envelope1 = try makeEnvelope(keyPair: keyPair1, seq: 1)
        let envelope2 = try makeEnvelope(keyPair: keyPair2, seq: 1)
        let envelope3 = try makeEnvelope(keyPair: keyPair3, seq: 1)

        _ = try book.consumePeerRecord(envelope1)
        _ = try book.consumePeerRecord(envelope2)
        _ = try book.consumePeerRecord(envelope3)

        let peers = Set(book.allCertifiedPeers())
        #expect(peers.count == 3)
        #expect(peers.contains(keyPair1.peerID))
        #expect(peers.contains(keyPair2.peerID))
        #expect(peers.contains(keyPair3.peerID))
    }

    @Test("allCertifiedPeers returns empty when no records stored")
    func emptyWhenNoRecords() {
        let book = CertifiedAddressBook()
        #expect(book.allCertifiedPeers().isEmpty)
    }
}

// MARK: - Events

@Suite("CertifiedAddressBook Events")
struct CertifiedAddressBookEventTests {

    @Test("Events emitted on accept", .timeLimit(.minutes(1)))
    func emitsAcceptEvent() async throws {
        let book = CertifiedAddressBook()
        let keyPair = makeKeyPair()
        let envelope = try makeEnvelope(keyPair: keyPair, seq: 1)

        let eventStream = book.events
        let collected = Mutex<[CertifiedAddressBookEvent]>([])

        let task = Task {
            for await event in eventStream {
                collected.withLock { $0.append(event) }
            }
        }

        // Give time for consumer to start
        try await Task.sleep(for: .milliseconds(50))

        _ = try book.consumePeerRecord(envelope)

        // Give time for event to propagate
        try await Task.sleep(for: .milliseconds(50))

        task.cancel()

        let events = collected.withLock { $0 }
        #expect(events.count == 1)
        guard case .recordAccepted(let peerID) = events.first else {
            #expect(Bool(false), "Expected recordAccepted event")
            return
        }
        #expect(peerID == keyPair.peerID)
    }

    @Test("Events emitted on reject due to older sequence", .timeLimit(.minutes(1)))
    func emitsRejectEvent() async throws {
        let book = CertifiedAddressBook()
        let keyPair = makeKeyPair()
        let envelope1 = try makeEnvelope(keyPair: keyPair, seq: 5)
        let envelope2 = try makeEnvelope(keyPair: keyPair, seq: 2)

        _ = try book.consumePeerRecord(envelope1)

        let eventStream = book.events
        let collected = Mutex<[CertifiedAddressBookEvent]>([])

        let task = Task {
            for await event in eventStream {
                collected.withLock { $0.append(event) }
            }
        }

        try await Task.sleep(for: .milliseconds(50))

        _ = try book.consumePeerRecord(envelope2)

        try await Task.sleep(for: .milliseconds(50))

        task.cancel()

        let events = collected.withLock { $0 }
        #expect(events.count == 1)
        guard case .recordRejected(let peerID, _) = events.first else {
            #expect(Bool(false), "Expected recordRejected event")
            return
        }
        #expect(peerID == keyPair.peerID)
    }
}

// MARK: - Multiple Peers

@Suite("CertifiedAddressBook Multiple Peers")
struct CertifiedAddressBookMultiplePeersTests {

    @Test("Multiple peers stored independently")
    func multiplePeersIndependent() throws {
        let book = CertifiedAddressBook()
        let keyPair1 = makeKeyPair()
        let keyPair2 = makeKeyPair()
        let addr1 = try Multiaddr("/ip4/10.0.0.1/tcp/4001")
        let addr2 = try Multiaddr("/ip4/10.0.0.2/tcp/4002")

        let envelope1 = try makeEnvelope(keyPair: keyPair1, seq: 1, addresses: [addr1])
        let envelope2 = try makeEnvelope(keyPair: keyPair2, seq: 1, addresses: [addr2])

        _ = try book.consumePeerRecord(envelope1)
        _ = try book.consumePeerRecord(envelope2)

        let addrs1 = book.certifiedAddresses(for: keyPair1.peerID)
        let addrs2 = book.certifiedAddresses(for: keyPair2.peerID)

        #expect(addrs1.count == 1)
        #expect(addrs1.first == addr1)
        #expect(addrs2.count == 1)
        #expect(addrs2.first == addr2)
    }

    @Test("Updating one peer does not affect another")
    func updateDoesNotAffectOther() throws {
        let book = CertifiedAddressBook()
        let keyPair1 = makeKeyPair()
        let keyPair2 = makeKeyPair()
        let addr1 = try Multiaddr("/ip4/10.0.0.1/tcp/4001")
        let addr2 = try Multiaddr("/ip4/10.0.0.2/tcp/4002")
        let addr3 = try Multiaddr("/ip4/10.0.0.3/tcp/4003")

        let envelope1 = try makeEnvelope(keyPair: keyPair1, seq: 1, addresses: [addr1])
        let envelope2 = try makeEnvelope(keyPair: keyPair2, seq: 1, addresses: [addr2])

        _ = try book.consumePeerRecord(envelope1)
        _ = try book.consumePeerRecord(envelope2)

        // Update peer1 with new addresses
        let envelope1Updated = try makeEnvelope(keyPair: keyPair1, seq: 2, addresses: [addr3])
        _ = try book.consumePeerRecord(envelope1Updated)

        // peer2 should be unaffected
        let addrs2 = book.certifiedAddresses(for: keyPair2.peerID)
        #expect(addrs2.count == 1)
        #expect(addrs2.first == addr2)

        // peer1 should have new addresses
        let addrs1 = book.certifiedAddresses(for: keyPair1.peerID)
        #expect(addrs1.count == 1)
        #expect(addrs1.first == addr3)
    }
}

// MARK: - Shutdown

@Suite("CertifiedAddressBook Shutdown")
struct CertifiedAddressBookShutdownTests {

    @Test("Shutdown clears all records")
    func shutdownClearsRecords() throws {
        let book = CertifiedAddressBook()
        let keyPair = makeKeyPair()
        let envelope = try makeEnvelope(keyPair: keyPair, seq: 1)

        _ = try book.consumePeerRecord(envelope)
        #expect(book.allCertifiedPeers().count == 1)

        book.shutdown()

        #expect(book.allCertifiedPeers().isEmpty)
        #expect(book.peerRecord(for: keyPair.peerID) == nil)
        #expect(book.certifiedAddresses(for: keyPair.peerID).isEmpty)
    }

    @Test("Shutdown is idempotent")
    func shutdownIdempotent() throws {
        let book = CertifiedAddressBook()
        let keyPair = makeKeyPair()
        let envelope = try makeEnvelope(keyPair: keyPair, seq: 1)

        _ = try book.consumePeerRecord(envelope)

        book.shutdown()
        book.shutdown()

        #expect(book.allCertifiedPeers().isEmpty)
    }

    @Test("Can accept records after shutdown")
    func acceptAfterShutdown() throws {
        let book = CertifiedAddressBook()
        let keyPair = makeKeyPair()
        let envelope1 = try makeEnvelope(keyPair: keyPair, seq: 1)

        _ = try book.consumePeerRecord(envelope1)
        book.shutdown()

        // After shutdown, new records should be accepted
        let envelope2 = try makeEnvelope(keyPair: keyPair, seq: 2)
        let accepted = try book.consumePeerRecord(envelope2)
        #expect(accepted)
        #expect(book.allCertifiedPeers().count == 1)
    }
}

// MARK: - Edge Cases

@Suite("CertifiedAddressBook Edge Cases")
struct CertifiedAddressBookEdgeCaseTests {

    @Test("Record with no addresses is accepted")
    func emptyAddressesAccepted() throws {
        let book = CertifiedAddressBook()
        let keyPair = makeKeyPair()
        let envelope = try makeEnvelope(keyPair: keyPair, seq: 1, addresses: [])

        let accepted = try book.consumePeerRecord(envelope)
        #expect(accepted)

        let addresses = book.certifiedAddresses(for: keyPair.peerID)
        #expect(addresses.isEmpty)
    }

    @Test("Record with sequence number 0 is accepted as first record")
    func sequenceZeroAccepted() throws {
        let book = CertifiedAddressBook()
        let keyPair = makeKeyPair()
        let envelope = try makeEnvelope(keyPair: keyPair, seq: 0)

        let accepted = try book.consumePeerRecord(envelope)
        #expect(accepted)
    }

    @Test("Record with many addresses is accepted")
    func manyAddressesAccepted() throws {
        let book = CertifiedAddressBook()
        let keyPair = makeKeyPair()

        var addresses: [Multiaddr] = []
        for i in 0..<20 {
            let addr = try Multiaddr("/ip4/10.0.0.\(i % 256)/tcp/\(4000 + i)")
            addresses.append(addr)
        }

        let envelope = try makeEnvelope(keyPair: keyPair, seq: 1, addresses: addresses)
        let accepted = try book.consumePeerRecord(envelope)
        #expect(accepted)

        let storedAddresses = book.certifiedAddresses(for: keyPair.peerID)
        #expect(storedAddresses.count == 20)
    }

    @Test("ECDSA key pair envelope is accepted")
    func ecdsaKeyPairAccepted() throws {
        let book = CertifiedAddressBook()
        let keyPair = KeyPair.generateECDSA()
        let addr = try Multiaddr("/ip4/127.0.0.1/tcp/4001")
        let record = PeerRecord.make(keyPair: keyPair, seq: 1, addresses: [addr])
        let envelope = try Envelope.seal(record: record, with: keyPair)

        let accepted = try book.consumePeerRecord(envelope)
        #expect(accepted)

        let addresses = book.certifiedAddresses(for: keyPair.peerID)
        #expect(addresses.count == 1)
        #expect(addresses.first == addr)
    }
}
