import Foundation
import Testing
@testable import P2PDiscoveryBeacon

@Suite("MicroPoW")
struct MicroPoWTests {

    @Test("solve and verify")
    func solveAndVerify() {
        let truncID: UInt16 = 0x1234
        let nonce: UInt32 = 0xABCD0000
        let pow = MicroPoW.solve(truncID: truncID, nonce: nonce, difficulty: 8)
        #expect(MicroPoW.verify(truncID: truncID, nonce: nonce, pow: pow, difficulty: 8))
    }

    @Test("verify with wrong PoW")
    func verifyWithWrongPoW() {
        let truncID: UInt16 = 0x1234
        let nonce: UInt32 = 0xABCD0000
        let pow = MicroPoW.solve(truncID: truncID, nonce: nonce, difficulty: 8)
        let wrongPow = (pow.0 ^ 0xFF, pow.1, pow.2)
        #expect(!MicroPoW.verify(truncID: truncID, nonce: nonce, pow: wrongPow, difficulty: 8))
    }

    @Test("verify with wrong nonce")
    func verifyWithWrongNonce() {
        let truncID: UInt16 = 0x5678
        let nonce: UInt32 = 0x11111111
        let pow = MicroPoW.solve(truncID: truncID, nonce: nonce, difficulty: 8)
        #expect(!MicroPoW.verify(truncID: truncID, nonce: nonce + 1, pow: pow, difficulty: 8))
    }

    @Test("default difficulty is 16")
    func defaultDifficultyIs16() {
        #expect(MicroPoW.defaultDifficulty == 16)
    }

    @Test("difficulty 8 is faster")
    func difficulty8IsFaster() {
        let pow = MicroPoW.solve(truncID: 0x9999, nonce: 0x22222222, difficulty: 8)
        #expect(MicroPoW.verify(truncID: 0x9999, nonce: 0x22222222, pow: pow, difficulty: 8))
    }

    @Test("difficulty 0 always valid")
    func difficulty0AlwaysValid() {
        #expect(MicroPoW.verify(truncID: 0, nonce: 0, pow: (0, 0, 0), difficulty: 0))
        #expect(MicroPoW.verify(truncID: 0xFFFF, nonce: 0xFFFFFFFF, pow: (0xFF, 0xFF, 0xFF), difficulty: 0))
    }

    @Test("different inputs different PoW")
    func differentInputsDifferentPoW() {
        let pow1 = MicroPoW.solve(truncID: 0x0001, nonce: 1, difficulty: 8)
        let pow2 = MicroPoW.solve(truncID: 0x0002, nonce: 1, difficulty: 8)
        let different = pow1.0 != pow2.0 || pow1.1 != pow2.1 || pow1.2 != pow2.2
        #expect(different)
    }
}
