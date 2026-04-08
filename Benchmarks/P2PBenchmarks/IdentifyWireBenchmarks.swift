/// IdentifyWireBenchmarks - Benchmarks for Identify protobuf encoding
import Testing
import Foundation
@testable import P2PCore
@testable import P2PIdentify

@Suite("Identify Wire Benchmarks", .serialized)
struct IdentifyWireBenchmarks {

    @Test("IdentifyProtobuf.encode - full identify info")
    func encodeFullIdentifyInfo() throws {
        let keyPair = KeyPair.generateEd25519()
        let info = IdentifyInfo(
            publicKey: keyPair.publicKey,
            listenAddresses: try [
                Multiaddr("/ip4/127.0.0.1/tcp/4001"),
                Multiaddr("/ip4/10.0.0.5/tcp/4002"),
                Multiaddr("/ip6/::1/tcp/4003")
            ],
            protocols: [
                "/ipfs/id/1.0.0",
                "/ipfs/id/push/1.0.0",
                "/ipfs/ping/1.0.0",
                "/meshsub/1.1.0",
                "/ipfs/kad/1.0.0"
            ],
            observedAddress: try Multiaddr("/ip4/203.0.113.5/tcp/4101"),
            protocolVersion: "ipfs/0.1.0",
            agentVersion: "swift-libp2p/0.1.0"
        )

        try benchmark("IdentifyProtobuf.encode full info", iterations: 250_000) {
            blackHole(try IdentifyProtobuf.encode(info))
        }
    }

    @Test("IdentifyProtobuf.encode - minimal identify info")
    func encodeMinimalIdentifyInfo() throws {
        let info = IdentifyInfo(protocols: ["/ipfs/id/1.0.0"])

        try benchmark("IdentifyProtobuf.encode minimal info", iterations: 500_000) {
            blackHole(try IdentifyProtobuf.encode(info))
        }
    }
}
