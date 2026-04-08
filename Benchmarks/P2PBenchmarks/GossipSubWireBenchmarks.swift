/// GossipSubWireBenchmarks - Benchmarks for signing and protobuf wire encoding
import Testing
import Foundation
import NIOCore
import P2PCore
import P2PGossipSub

@Suite("GossipSub Wire Benchmarks", .serialized)
struct GossipSubWireBenchmarks {

    @Test("Builder.sign - signed publish message")
    func signBuilder() throws {
        let privateKey = PrivateKey.generateEd25519()
        let peerID = privateKey.publicKey.peerID
        let topic = Topic("/meshsub/1.1.0/some-application/blocks/v1/json")
        let data = Data(repeating: 0x42, count: 256)
        let seqno = Data([0, 1, 2, 3, 4, 5, 6, 7])
        let builder = GossipSubMessage.Builder(data: data, topic: topic)
            .source(peerID)
            .sequenceNumber(seqno)

        try benchmark("GossipSubMessage.Builder.sign", iterations: 100_000) {
            blackHole(try builder.sign(with: privateKey))
        }
    }

    @Test("verifySignature - signed publish message")
    func verifySignature() throws {
        let privateKey = PrivateKey.generateEd25519()
        let peerID = privateKey.publicKey.peerID
        let topic = Topic("/meshsub/1.1.0/some-application/blocks/v1/json")
        let data = Data(repeating: 0x42, count: 256)
        let seqno = Data([0, 1, 2, 3, 4, 5, 6, 7])
        let message = try GossipSubMessage.Builder(data: data, topic: topic)
            .source(peerID)
            .sequenceNumber(seqno)
            .sign(with: privateKey)
            .build()

        benchmark("GossipSubMessage.verifySignature", iterations: 100_000) {
            blackHole(message.verifySignature())
        }
    }

    @Test("GossipSubProtobuf.encode - publish RPC")
    func encodePublishRPC() throws {
        let privateKey = PrivateKey.generateEd25519()
        let peerID = privateKey.publicKey.peerID
        let topic = Topic("/meshsub/1.1.0/some-application/blocks/v1/json")
        let data = Data(repeating: 0x42, count: 256)
        let seqno = Data([0, 1, 2, 3, 4, 5, 6, 7])
        let message = try GossipSubMessage.Builder(data: data, topic: topic)
            .source(peerID)
            .sequenceNumber(seqno)
            .sign(with: privateKey)
            .build()
        let rpc = GossipSubRPC(messages: [message])

        benchmark("GossipSubProtobuf.encode publish RPC", iterations: 250_000) {
            blackHole(GossipSubProtobuf.encode(rpc))
        }
    }

    @Test("GossipSubProtobuf.encode - control RPC")
    func encodeControlRPC() {
        let topic = Topic("/meshsub/1.1.0/some-application/blocks/v1/json")
        let ids = (0..<20).map { index in
            MessageID(bytes: Data(repeating: UInt8(index), count: 20))
        }
        var control = ControlMessageBatch()
        control.add(.ihave(.init(topic: topic, messageIDs: ids)))
        control.add(.iwant(.init(messageIDs: Array(ids.prefix(10)))))
        control.add(.graft(.init(topic: topic)))
        control.add(.idontwant(.init(messageIDs: Array(ids.suffix(8)))))
        let rpc = GossipSubRPC(control: control)

        benchmark("GossipSubProtobuf.encode control RPC", iterations: 250_000) {
            blackHole(GossipSubProtobuf.encode(rpc))
        }
    }

    @Test("Length-prefixed framing - publish RPC")
    func framePublishRPC() throws {
        let privateKey = PrivateKey.generateEd25519()
        let peerID = privateKey.publicKey.peerID
        let topic = Topic("/meshsub/1.1.0/some-application/blocks/v1/json")
        let data = Data(repeating: 0x42, count: 256)
        let seqno = Data([0, 1, 2, 3, 4, 5, 6, 7])
        let message = try GossipSubMessage.Builder(data: data, topic: topic)
            .source(peerID)
            .sequenceNumber(seqno)
            .sign(with: privateKey)
            .build()
        let encoded = GossipSubProtobuf.encode(GossipSubRPC(messages: [message]))
        let allocator = ByteBufferAllocator()

        benchmark("GossipSub RPC framing publish RPC", iterations: 250_000) {
            var buffer = allocator.buffer(capacity: encoded.count + 10)
            Varint.encode(UInt64(encoded.count), into: &buffer)
            buffer.writeBytes(encoded)
            blackHole(buffer)
        }
    }
}
