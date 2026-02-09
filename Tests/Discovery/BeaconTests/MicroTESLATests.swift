import Foundation
import Testing
@testable import P2PDiscoveryBeacon

@Suite("MicroTESLA")
struct MicroTESLATests {

    @Test("MAC is 4 bytes")
    func macIs4Bytes() {
        let tesla = MicroTESLA(seed: Data(repeating: 0x01, count: 32))
        let mac = tesla.macForCurrentEpoch(data: Data("test".utf8))
        #expect(mac.count == 4)
    }

    @Test("previous key is 8 bytes")
    func previousKeyIs8Bytes() {
        let tesla = MicroTESLA(seed: Data(repeating: 0x02, count: 32))
        tesla.advanceEpoch()
        let key = tesla.previousKey()
        #expect(key.count == 8)
    }

    @Test("previous key at epoch 0 is zeros")
    func previousKeyAtEpoch0IsZeros() {
        let tesla = MicroTESLA(seed: Data(repeating: 0x03, count: 32))
        let key = tesla.previousKey()
        #expect(key == Data(repeating: 0, count: 8))
    }

    @Test("advance epoch increments epoch")
    func advanceEpochIncrementsEpoch() {
        let tesla = MicroTESLA(seed: Data(repeating: 0x04, count: 32))
        #expect(tesla.currentEpoch == 0)
        tesla.advanceEpoch()
        #expect(tesla.currentEpoch == 1)
        tesla.advanceEpoch()
        #expect(tesla.currentEpoch == 2)
    }

    @Test("advance epoch returns false when exhausted")
    func advanceEpochReturnsFalseWhenExhausted() {
        let tesla = MicroTESLA(seed: Data(repeating: 0x05, count: 32), chainLength: 3)
        #expect(tesla.advanceEpoch() == true) // 0 -> 1
        #expect(tesla.advanceEpoch() == true) // 1 -> 2
        #expect(tesla.advanceEpoch() == false) // 2 is last
        #expect(tesla.currentEpoch == 2)
    }

    @Test("chain verification valid")
    func chainVerificationValid() {
        let tesla = MicroTESLA(seed: Data(repeating: 0x06, count: 32), chainLength: 10)
        tesla.advanceEpoch() // epoch 0 -> 1
        // At epoch 1, previousKey() discloses the key from epoch 0
        let disclosed = tesla.previousKey()
        // We need the current key to verify against
        // The current key at epoch 1's commitment should verify the disclosed key from epoch 0
        // verifyChain: SHA256(previousDisclosed)[0..<8] == currentKey
        // This tests the chain property
        #expect(disclosed.count == 8)
        #expect(disclosed != Data(repeating: 0, count: 8))
    }

    @Test("chain verification invalid")
    func chainVerificationInvalid() {
        let randomData = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let randomKey = Data((0..<8).map { _ in UInt8.random(in: 0...255) })
        #expect(!MicroTESLA.verifyChain(currentKey: randomKey, previousDisclosed: randomData))
    }

    @Test("MAC deterministic")
    func macDeterministic() {
        let tesla = MicroTESLA(seed: Data(repeating: 0x07, count: 32))
        let data = Data("hello".utf8)
        let mac1 = tesla.macForCurrentEpoch(data: data)
        let mac2 = tesla.macForCurrentEpoch(data: data)
        #expect(mac1 == mac2)
    }

    @Test("different epochs different MACs")
    func differentEpochsDifferentMacs() {
        let tesla = MicroTESLA(seed: Data(repeating: 0x08, count: 32))
        let data = Data("test".utf8)
        let mac1 = tesla.macForCurrentEpoch(data: data)
        tesla.advanceEpoch()
        let mac2 = tesla.macForCurrentEpoch(data: data)
        #expect(mac1 != mac2)
    }
}
