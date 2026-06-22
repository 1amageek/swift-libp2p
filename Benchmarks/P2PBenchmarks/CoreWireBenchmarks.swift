/// CoreWireBenchmarks - Benchmarks for core protobuf and record decoding
import Testing
import Foundation
@testable import P2PCore

@Suite("Core Wire Benchmarks", .serialized)
struct CoreWireBenchmarks {

    @Test("Multihash bytes decode - SHA-256")
    func decodeSHA256Multihash() throws {
        let inputs = (0..<4).map { index in
            Multihash.sha256(Data(repeating: UInt8(index), count: 256)).bytes
        }
        var index = 0

        try benchmark("Multihash.decode sha256", iterations: 500_000) {
            let encoded = inputs[index & 3]
            index &+= 1
            blackHole(try Multihash(bytes: encoded))
        }

        index = 0

        try benchmark("Multihash.decode sha256 legacy", iterations: 500_000) {
            let encoded = inputs[index & 3]
            index &+= 1
            // `Multihash.bytes` is `[UInt8]` in the Embedded-clean core; the
            // legacy `Data`-based decoder takes the same bytes as `Data`.
            blackHole(try Self.legacyDecodeMultihash(Data(encoded)))
        }
    }

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

    private static func legacyDecodeMultihash(_ data: Data) throws -> Multihash {
        let (codeValue, codeBytes) = try Varint.decode(data)
        guard let code = HashCode(rawValue: codeValue) else {
            throw MultihashError.unknownCode(codeValue)
        }

        let remaining = data.dropFirst(codeBytes)
        let (length, lengthBytes) = try Varint.decode(Data(remaining))
        guard length <= Multihash.maxDigestLength else {
            throw MultihashError.digestTooLarge(length)
        }

        let digestLength = Int(length)
        let digestStart = remaining.dropFirst(lengthBytes)
        guard digestStart.count >= digestLength else {
            throw MultihashError.insufficientData
        }

        return Multihash(code: code, digest: Data(digestStart.prefix(digestLength)))
    }
}
