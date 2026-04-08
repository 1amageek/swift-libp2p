/// IPNSBenchmarks - Benchmarks for IPNS record encoding
import Testing
import Foundation
import P2PCore
@testable import P2PKademlia

@Suite("IPNS Benchmarks", .serialized)
struct IPNSBenchmarks {

    @Test("IPNSRecord.encode - signed record")
    func encodeSignedRecord() throws {
        let keyPair = KeyPair.generateEd25519()
        let record = try IPNSRecord.create(
            value: Array("/ipfs/bafybeigdyrzt6examplecontentpath".utf8),
            sequence: 42,
            validity: Date(timeIntervalSince1970: 1_775_689_600),
            keyPair: keyPair
        )

        benchmark("IPNSRecord.encode signed", iterations: 250_000) {
            blackHole(record.encode())
        }
    }

    @Test("IPNSRecord.dataForSigning")
    func dataForSigning() {
        let value = Array("/ipns/k51qzi5uqu5dl-example".utf8)
        let validity = Date(timeIntervalSince1970: 1_775_689_600)

        benchmark("IPNSRecord.dataForSigning", iterations: 500_000) {
            blackHole(IPNSRecord.dataForSigning(value: value, validityType: .eol, validity: validity))
        }
    }
}
