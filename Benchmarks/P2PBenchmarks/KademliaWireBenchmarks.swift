/// KademliaWireBenchmarks - Benchmarks for Kademlia protobuf encoding
import Testing
import Foundation
import NIOCore
@testable import P2PCore
@testable import P2PKademlia

@Suite("Kademlia Wire Benchmarks", .serialized)
struct KademliaWireBenchmarks {

    @Test("KademliaProtobuf.encode - find node response")
    func encodeFindNodeResponse() throws {
        let peers = try samplePeers(count: 20)
        let message = KademliaMessage.findNodeResponse(closerPeers: peers)

        benchmark("KademliaProtobuf.encode findNodeResponse", iterations: 250_000) {
            blackHole(KademliaProtobuf.encode(message))
        }
    }

    @Test("KademliaProtobuf.encode(into:) - find node response")
    func encodeIntoFindNodeResponse() throws {
        let peers = try samplePeers(count: 20)
        let message = KademliaMessage.findNodeResponse(closerPeers: peers)
        let allocator = ByteBufferAllocator()

        benchmark("KademliaProtobuf.encode(into:) findNodeResponse", iterations: 250_000) {
            var buffer = allocator.buffer(capacity: 0)
            KademliaProtobuf.encode(message, into: &buffer)
            blackHole(buffer)
        }
    }

    @Test("KademliaProtobuf.encode - get value response")
    func encodeGetValueResponse() throws {
        let peers = try samplePeers(count: 8)
        let record = KademliaRecord(
            key: Data("kad:key:/providers/example".utf8),
            value: Data(repeating: 0x42, count: 512),
            timeReceived: "2026-04-08T22:00:00Z"
        )
        let message = KademliaMessage.getValueResponse(record: record, closerPeers: peers)

        benchmark("KademliaProtobuf.encode getValueResponse", iterations: 200_000) {
            blackHole(KademliaProtobuf.encode(message))
        }
    }

    @Test("KademliaProtobuf.encode(into:) - get value response")
    func encodeIntoGetValueResponse() throws {
        let peers = try samplePeers(count: 8)
        let record = KademliaRecord(
            key: Data("kad:key:/providers/example".utf8),
            value: Data(repeating: 0x42, count: 512),
            timeReceived: "2026-04-08T22:00:00Z"
        )
        let message = KademliaMessage.getValueResponse(record: record, closerPeers: peers)
        let allocator = ByteBufferAllocator()

        benchmark("KademliaProtobuf.encode(into:) getValueResponse", iterations: 200_000) {
            var buffer = allocator.buffer(capacity: 0)
            KademliaProtobuf.encode(message, into: &buffer)
            blackHole(buffer)
        }
    }

    @Test("KademliaProtobuf.decode - find node response")
    func decodeFindNodeResponse() throws {
        let peers = try samplePeers(count: 20)
        let encoded = KademliaProtobuf.encode(.findNodeResponse(closerPeers: peers))

        try benchmark("KademliaProtobuf.decode findNodeResponse", iterations: 250_000) {
            blackHole(try KademliaProtobuf.decode(encoded))
        }
    }

    @Test("KademliaProtobuf.decode - get value response")
    func decodeGetValueResponse() throws {
        let peers = try samplePeers(count: 8)
        let record = KademliaRecord(
            key: Data("kad:key:/providers/example".utf8),
            value: Data(repeating: 0x42, count: 512),
            timeReceived: "2026-04-08T22:00:00Z"
        )
        let encoded = KademliaProtobuf.encode(.getValueResponse(record: record, closerPeers: peers))

        try benchmark("KademliaProtobuf.decode getValueResponse", iterations: 200_000) {
            blackHole(try KademliaProtobuf.decode(encoded))
        }
    }

    private func samplePeers(count: Int) throws -> [KademliaPeer] {
        let baseAddresses = try [
            Multiaddr("/ip4/127.0.0.1/tcp/4001"),
            Multiaddr("/ip4/10.0.0.5/tcp/4002"),
            Multiaddr("/ip6/::1/tcp/4003")
        ]

        return (0..<count).map { index in
            let keyPair = KeyPair.generateEd25519()
            let addresses = Array(baseAddresses.prefix((index % baseAddresses.count) + 1))
            return KademliaPeer(
                id: keyPair.peerID,
                addresses: addresses,
                connectionType: .connected
            )
        }
    }
}
