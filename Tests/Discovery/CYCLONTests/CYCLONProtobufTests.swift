import Testing
import Foundation
import P2PCore
@testable import P2PDiscoveryCYCLON

@Suite("CYCLON Protobuf Tests")
struct CYCLONProtobufTests {

    private func makePeerID() -> PeerID {
        KeyPair.generateEd25519().peerID
    }

    @Test("Encode and decode shuffle request")
    func shuffleRequestRoundtrip() throws {
        let entries = [
            CYCLONEntry(peerID: makePeerID(), addresses: [], age: 0),
            CYCLONEntry(peerID: makePeerID(), addresses: [], age: 5),
            CYCLONEntry(peerID: makePeerID(), addresses: [], age: 10),
        ]

        let message = CYCLONMessage.shuffleRequest(entries: entries)
        let encoded = CYCLONProtobuf.encode(message)
        let decoded = try CYCLONProtobuf.decode(encoded)

        guard case .shuffleRequest(let decodedEntries) = decoded else {
            Issue.record("Expected shuffleRequest")
            return
        }

        #expect(decodedEntries.count == 3)
        for (original, decoded) in zip(entries, decodedEntries) {
            #expect(original.peerID == decoded.peerID)
            #expect(original.age == decoded.age)
        }
    }

    @Test("Encode and decode shuffle response")
    func shuffleResponseRoundtrip() throws {
        let entries = [
            CYCLONEntry(peerID: makePeerID(), addresses: [], age: 7),
        ]

        let message = CYCLONMessage.shuffleResponse(entries: entries)
        let encoded = CYCLONProtobuf.encode(message)
        let decoded = try CYCLONProtobuf.decode(encoded)

        guard case .shuffleResponse(let decodedEntries) = decoded else {
            Issue.record("Expected shuffleResponse")
            return
        }

        #expect(decodedEntries.count == 1)
        #expect(decodedEntries[0].peerID == entries[0].peerID)
        #expect(decodedEntries[0].age == 7)
    }

    @Test("Empty entries list roundtrip")
    func emptyEntriesRoundtrip() throws {
        let message = CYCLONMessage.shuffleRequest(entries: [])
        let encoded = CYCLONProtobuf.encode(message)
        let decoded = try CYCLONProtobuf.decode(encoded)

        guard case .shuffleRequest(let decodedEntries) = decoded else {
            Issue.record("Expected shuffleRequest")
            return
        }

        #expect(decodedEntries.isEmpty)
    }

    @Test("Entry with addresses roundtrip")
    func entryWithAddressesRoundtrip() throws {
        let addr1 = try Multiaddr("/ip4/127.0.0.1/tcp/4001")
        let addr2 = try Multiaddr("/ip4/192.168.1.1/tcp/8080")
        let entry = CYCLONEntry(
            peerID: makePeerID(),
            addresses: [addr1, addr2],
            age: 3
        )

        let message = CYCLONMessage.shuffleRequest(entries: [entry])
        let encoded = CYCLONProtobuf.encode(message)
        let decoded = try CYCLONProtobuf.decode(encoded)

        guard case .shuffleRequest(let decodedEntries) = decoded else {
            Issue.record("Expected shuffleRequest")
            return
        }

        #expect(decodedEntries.count == 1)
        #expect(decodedEntries[0].addresses.count == 2)
        #expect(decodedEntries[0].addresses[0].description == addr1.description)
        #expect(decodedEntries[0].addresses[1].description == addr2.description)
        #expect(decodedEntries[0].age == 3)
    }

    @Test("Large age value roundtrip")
    func largeAgeRoundtrip() throws {
        let entry = CYCLONEntry(peerID: makePeerID(), addresses: [], age: UInt64.max)
        let message = CYCLONMessage.shuffleResponse(entries: [entry])
        let encoded = CYCLONProtobuf.encode(message)
        let decoded = try CYCLONProtobuf.decode(encoded)

        guard case .shuffleResponse(let decodedEntries) = decoded else {
            Issue.record("Expected shuffleResponse")
            return
        }

        #expect(decodedEntries[0].age == UInt64.max)
    }

    @Test("Decode invalid data throws error")
    func decodeInvalidData() {
        let garbage = Data([0xFF, 0xFF, 0xFF])
        #expect(throws: (any Error).self) {
            try CYCLONProtobuf.decode(garbage)
        }
    }

    @Test("Decode empty data throws error")
    func decodeEmptyData() {
        #expect(throws: (any Error).self) {
            try CYCLONProtobuf.decode(Data())
        }
    }
}
