/// NoiseCryptoBenchmarks - Benchmarks for NoiseCipherState / NoiseSymmetricState
import Testing
import Foundation
import Crypto
@testable import P2PSecurityNoise

@Suite("NoiseCrypto Benchmarks")
struct NoiseCryptoBenchmarks {

    // MARK: - CipherState

    @Test("encrypt 32B - ChaChaPoly + stack nonce")
    func encrypt32B() throws {
        let key = SymmetricKey(size: .bits256)
        let plaintext = Data(repeating: 0xAA, count: 32)
        let ad = Data()
        try benchmark("NoiseCipherState encrypt 32B", iterations: 500_000) {
            var cipher = NoiseCipherState(key: key)
            blackHole(try cipher.encryptWithAD(ad, plaintext: plaintext))
        }
    }

    @Test("encrypt 256B - typical Noise message")
    func encrypt256B() throws {
        let key = SymmetricKey(size: .bits256)
        let plaintext = Data(repeating: 0xBB, count: 256)
        let ad = Data(repeating: 0x01, count: 32)
        try benchmark("NoiseCipherState encrypt 256B", iterations: 500_000) {
            var cipher = NoiseCipherState(key: key)
            blackHole(try cipher.encryptWithAD(ad, plaintext: plaintext))
        }
    }

    @Test("decrypt 256B - decryption + authentication")
    func decrypt256B() throws {
        let key = SymmetricKey(size: .bits256)
        let plaintext = Data(repeating: 0xCC, count: 256)
        let ad = Data(repeating: 0x02, count: 32)
        // Pre-encrypt to get valid ciphertext
        var encryptor = NoiseCipherState(key: key)
        let ciphertext = try encryptor.encryptWithAD(ad, plaintext: plaintext)
        try benchmark("NoiseCipherState decrypt 256B", iterations: 500_000) {
            var cipher = NoiseCipherState(key: key)
            blackHole(try cipher.decryptWithAD(ad, ciphertext: ciphertext))
        }
    }

    @Test("roundtrip 1KB - encrypt + decrypt")
    func roundtrip1KB() throws {
        let key = SymmetricKey(size: .bits256)
        let plaintext = Data(repeating: 0xDD, count: 1024)
        let ad = Data()
        try benchmark("NoiseCipherState roundtrip 1KB", iterations: 100_000) {
            var encCipher = NoiseCipherState(key: key)
            let ct = try encCipher.encryptWithAD(ad, plaintext: plaintext)
            var decCipher = NoiseCipherState(key: key)
            blackHole(try decCipher.decryptWithAD(ad, ciphertext: ct))
        }
    }

    // MARK: - SymmetricState

    @Test("mixHash - SHA-256(h || data)")
    func mixHash() {
        var state = NoiseSymmetricState(protocolName: "Noise_XX_25519_ChaChaPoly_SHA256")
        let data = Data(repeating: 0xEE, count: 32)
        benchmark("NoiseSymmetricState mixHash", iterations: 500_000) {
            state.mixHash(data)
        }
    }

    @Test("mixKey - HKDF key derivation")
    func mixKey() {
        let ikm = Data(repeating: 0xFF, count: 32)
        benchmark("NoiseSymmetricState mixKey", iterations: 100_000) {
            var state = NoiseSymmetricState(protocolName: "Noise_XX_25519_ChaChaPoly_SHA256")
            state.mixKey(ikm)
            blackHole(state.chainingKey)
        }
    }

    @Test("split - derive 2 CipherStates")
    func split() {
        var state = NoiseSymmetricState(protocolName: "Noise_XX_25519_ChaChaPoly_SHA256")
        state.mixKey(Data(repeating: 0x42, count: 32))
        benchmark("NoiseSymmetricState split", iterations: 100_000) {
            let (c1, c2) = state.split()
            blackHole(c1)
            blackHole(c2)
        }
    }

    @Test("100 consecutive encrypts - nonce increment scenario")
    func consecutiveEncrypts100() throws {
        let key = SymmetricKey(size: .bits256)
        let plaintext = Data(repeating: 0xAB, count: 64)
        let ad = Data()
        try benchmark("NoiseCipherState 100x encrypt", iterations: 10_000) {
            var cipher = NoiseCipherState(key: key)
            for _ in 0..<100 {
                blackHole(try cipher.encryptWithAD(ad, plaintext: plaintext))
            }
        }
    }
}
