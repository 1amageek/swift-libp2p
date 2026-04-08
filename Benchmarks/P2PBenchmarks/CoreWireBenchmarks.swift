/// CoreWireBenchmarks - Benchmarks for core protobuf and record decoding
import Testing
import Foundation
@testable import P2PCore

@Suite("Core Wire Benchmarks", .serialized)
struct CoreWireBenchmarks {

    @Test("PublicKey protobuf decode - Ed25519")
    func decodeEd25519PublicKey() throws {
        let keyPair = KeyPair.generateEd25519()
        let encoded = keyPair.publicKey.protobufEncoded

        try benchmark("PublicKey.decode protobuf ed25519", iterations: 500_000) {
            blackHole(try PublicKey(protobufEncoded: encoded))
        }
    }

    @Test("Envelope.unmarshal - signed PeerRecord")
    func unmarshalSignedPeerRecordEnvelope() throws {
        let keyPair = KeyPair.generateEd25519()
        let record = PeerRecord.make(
            keyPair: keyPair,
            seq: 42,
            addresses: try [
                Multiaddr("/ip4/127.0.0.1/tcp/4001"),
                Multiaddr("/ip4/10.0.0.5/tcp/4002"),
                Multiaddr("/ip6/::1/tcp/4003")
            ]
        )
        let envelope = try Envelope.seal(record: record, with: keyPair)
        let encoded = try envelope.marshal()

        try benchmark("Envelope.unmarshal signed PeerRecord", iterations: 200_000) {
            blackHole(try Envelope.unmarshal(encoded))
        }
    }
}
