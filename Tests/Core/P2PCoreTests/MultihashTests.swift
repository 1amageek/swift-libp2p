import Testing
import Foundation
@testable import P2PCore

@Suite("Multihash Tests")
struct MultihashTests {

    @Test("Identity multihash bytes roundtrip")
    func identityBytesRoundtrip() throws {
        let original = Multihash.identity(Data("hello multihash".utf8))

        let restored = try Multihash(bytes: original.bytes)

        #expect(restored == original)
        #expect(restored.code == .identity)
        #expect(restored.digest == Data("hello multihash".utf8))
    }

    @Test("SHA-256 multihash bytes roundtrip")
    func sha256BytesRoundtrip() throws {
        let original = Multihash.sha256(Data("hello multihash".utf8))

        let restored = try Multihash(bytes: original.bytes)

        #expect(restored == original)
        #expect(restored.code == .sha2_256)
    }

    @Test("Truncated multihash throws insufficientData")
    func truncatedBytesThrow() throws {
        let original = Multihash.sha256(Data("hello multihash".utf8))
        let truncated = Data(original.bytes.dropLast())

        do {
            _ = try Multihash(bytes: truncated)
            Issue.record("Expected Multihash(bytes:) to throw for truncated input")
        } catch let error as MultihashError {
            #expect(error == .insufficientData)
        }
    }

    @Test("Oversized digest length throws digestTooLarge")
    func oversizedDigestThrows() throws {
        var bytes = Data()
        Varint.encode(HashCode.identity.rawValue, into: &bytes)
        Varint.encode(UInt64(Multihash.maxDigestLength + 1), into: &bytes)

        do {
            _ = try Multihash(bytes: bytes)
            Issue.record("Expected Multihash(bytes:) to reject oversized digest length")
        } catch let error as MultihashError {
            #expect(error == .digestTooLarge(UInt64(Multihash.maxDigestLength + 1)))
        }
    }
}
