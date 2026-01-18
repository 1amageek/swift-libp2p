/// IdentifyProtobufTests - Unit tests for Identify protobuf encoding/decoding
import Testing
import Foundation
@testable import P2PIdentify
@testable import P2PCore

@Suite("Identify Protobuf Tests")
struct IdentifyProtobufTests {

    @Test("Empty IdentifyInfo encodes and decodes correctly")
    func testEmptyInfo() throws {
        let info = IdentifyInfo()
        let encoded = IdentifyProtobuf.encode(info)
        let decoded = try IdentifyProtobuf.decode(encoded)

        #expect(decoded.publicKey == nil)
        #expect(decoded.listenAddresses.isEmpty)
        #expect(decoded.protocols.isEmpty)
        #expect(decoded.observedAddress == nil)
        #expect(decoded.protocolVersion == nil)
        #expect(decoded.agentVersion == nil)
        #expect(decoded.signedPeerRecord == nil)
    }

    @Test("IdentifyInfo with all fields encodes and decodes correctly")
    func testFullInfo() throws {
        let keyPair = KeyPair.generateEd25519()
        let listenAddr = Multiaddr("/ip4/127.0.0.1/tcp/4001")
        let observedAddr = Multiaddr("/ip4/1.2.3.4/tcp/5678")

        let info = IdentifyInfo(
            publicKey: keyPair.publicKey,
            listenAddresses: [listenAddr],
            protocols: ["/ipfs/ping/1.0.0", "/ipfs/id/1.0.0"],
            observedAddress: observedAddr,
            protocolVersion: "ipfs/0.1.0",
            agentVersion: "swift-libp2p/0.1.0",
            signedPeerRecord: nil
        )

        let encoded = IdentifyProtobuf.encode(info)
        let decoded = try IdentifyProtobuf.decode(encoded)

        #expect(decoded.publicKey != nil)
        #expect(decoded.listenAddresses.count == 1)
        #expect(decoded.listenAddresses.first == listenAddr)
        #expect(decoded.protocols.count == 2)
        #expect(decoded.protocols.contains("/ipfs/ping/1.0.0"))
        #expect(decoded.protocols.contains("/ipfs/id/1.0.0"))
        #expect(decoded.observedAddress == observedAddr)
        #expect(decoded.protocolVersion == "ipfs/0.1.0")
        #expect(decoded.agentVersion == "swift-libp2p/0.1.0")
    }

    @Test("Multiple listen addresses encode correctly")
    func testMultipleListenAddresses() throws {
        let addr1 = Multiaddr("/ip4/127.0.0.1/tcp/4001")
        let addr2 = Multiaddr("/ip4/0.0.0.0/tcp/4002")
        let addr3 = Multiaddr("/ip6/::1/tcp/4003")

        let info = IdentifyInfo(
            listenAddresses: [addr1, addr2, addr3]
        )

        let encoded = IdentifyProtobuf.encode(info)
        let decoded = try IdentifyProtobuf.decode(encoded)

        #expect(decoded.listenAddresses.count == 3)
        // Compare bytes to handle IPv6 format differences (::1 vs 0:0:0:0:0:0:0:1)
        #expect(decoded.listenAddresses[0].bytes == addr1.bytes)
        #expect(decoded.listenAddresses[1].bytes == addr2.bytes)
        #expect(decoded.listenAddresses[2].bytes == addr3.bytes)
    }

    @Test("Multiple protocols encode correctly")
    func testMultipleProtocols() throws {
        let protocols = [
            "/ipfs/id/1.0.0",
            "/ipfs/id/push/1.0.0",
            "/ipfs/ping/1.0.0",
            "/my/custom/protocol/1.0.0"
        ]

        let info = IdentifyInfo(protocols: protocols)

        let encoded = IdentifyProtobuf.encode(info)
        let decoded = try IdentifyProtobuf.decode(encoded)

        #expect(decoded.protocols.count == 4)
        for proto in protocols {
            #expect(decoded.protocols.contains(proto))
        }
    }

    @Test("Decoding ignores unknown fields")
    func testUnknownFields() throws {
        let info = IdentifyInfo(agentVersion: "test/1.0.0")
        var encoded = IdentifyProtobuf.encode(info)

        // Add unknown field 9 (wire type 2)
        encoded.append(0x4A) // field 9, wire type 2
        encoded.append(0x03) // length 3
        encoded.append(contentsOf: [0xAA, 0xBB, 0xCC])

        let decoded = try IdentifyProtobuf.decode(encoded)

        #expect(decoded.agentVersion == "test/1.0.0")
    }

    @Test("PeerID can be extracted from public key")
    func testPeerIDExtraction() throws {
        let keyPair = KeyPair.generateEd25519()
        let info = IdentifyInfo(publicKey: keyPair.publicKey)

        #expect(info.peerID == keyPair.peerID)
    }

    @Test("Empty data decodes to empty info")
    func testEmptyDataDecode() throws {
        let decoded = try IdentifyProtobuf.decode(Data())

        #expect(decoded.publicKey == nil)
        #expect(decoded.listenAddresses.isEmpty)
        #expect(decoded.protocols.isEmpty)
    }
}
