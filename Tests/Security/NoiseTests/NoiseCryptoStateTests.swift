/// NoiseCryptoStateTests - Unit tests for Noise cryptographic primitives
import Testing
import Foundation
import Crypto
import P2PCore
@testable import P2PSecurityNoise

@Suite("NoiseCryptoState Tests")
struct NoiseCryptoStateTests {

    // MARK: - CipherState Tests

    @Test("CipherState encrypts and decrypts correctly")
    func testCipherStateEncryptDecrypt() throws {
        let key = SymmetricKey(size: .bits256)
        var encryptState = NoiseCipherState(key: key)
        var decryptState = NoiseCipherState(key: key)

        let plaintext = Data("Hello, Noise Protocol!".utf8)
        let ad = Data("associated data".utf8)

        let ciphertext = try encryptState.encryptWithAD(ad, plaintext: plaintext)
        let decrypted = try decryptState.decryptWithAD(ad, ciphertext: ciphertext)

        #expect(decrypted == plaintext)
        #expect(ciphertext != plaintext)
        #expect(ciphertext.count == plaintext.count + 16) // +16 for auth tag
    }

    @Test("CipherState accepts ByteBufferView without pre-converting to Data")
    func testCipherStateByteBufferViewInput() throws {
        let key = SymmetricKey(size: .bits256)
        var encryptState = NoiseCipherState(key: key)
        var decryptState = NoiseCipherState(key: key)

        let plaintextBuffer = ByteBuffer(bytes: Data("Hello, ByteBufferView!".utf8))
        let associatedDataBuffer = ByteBuffer(bytes: Data("buffer-ad".utf8))

        let ciphertext = try encryptState.encryptWithAD(
            associatedDataBuffer.readableBytesView,
            plaintext: plaintextBuffer.readableBytesView
        )
        let ciphertextBuffer = ByteBuffer(bytes: ciphertext)
        let decrypted = try decryptState.decryptWithAD(
            associatedDataBuffer.readableBytesView,
            ciphertext: ciphertextBuffer.readableBytesView
        )

        #expect(decrypted == Data("Hello, ByteBufferView!".utf8))
    }

    @Test("CipherState without key passes through plaintext")
    func testCipherStateNoKeyPassthrough() throws {
        var state = NoiseCipherState()

        let plaintext = Data("plaintext data".utf8)
        let ad = Data()

        let result = try state.encryptWithAD(ad, plaintext: plaintext)
        #expect(result == plaintext)

        let decrypted = try state.decryptWithAD(ad, ciphertext: plaintext)
        #expect(decrypted == plaintext)
    }

    @Test("CipherState nonce increments after each operation")
    func testCipherStateNonceIncrement() throws {
        let key = SymmetricKey(size: .bits256)
        var state = NoiseCipherState(key: key)

        let plaintext = Data("test".utf8)

        // Encrypt multiple times - each should use different nonce
        let ct1 = try state.encryptWithAD(Data(), plaintext: plaintext)
        let ct2 = try state.encryptWithAD(Data(), plaintext: plaintext)
        let ct3 = try state.encryptWithAD(Data(), plaintext: plaintext)

        // Same plaintext should produce different ciphertexts due to different nonces
        #expect(ct1 != ct2)
        #expect(ct2 != ct3)
        #expect(ct1 != ct3)
    }

    @Test("CipherState decryption fails with wrong key")
    func testCipherStateDecryptWrongKey() throws {
        let key1 = SymmetricKey(size: .bits256)
        let key2 = SymmetricKey(size: .bits256)

        var encryptState = NoiseCipherState(key: key1)
        var decryptState = NoiseCipherState(key: key2)

        let plaintext = Data("secret message".utf8)
        let ciphertext = try encryptState.encryptWithAD(Data(), plaintext: plaintext)

        #expect(throws: (any Error).self) {
            _ = try decryptState.decryptWithAD(Data(), ciphertext: ciphertext)
        }
    }

    @Test("CipherState decryption fails with tampered auth tag")
    func testCipherStateAuthTagTamper() throws {
        let key = SymmetricKey(size: .bits256)
        var encryptState = NoiseCipherState(key: key)
        var decryptState = NoiseCipherState(key: key)

        let plaintext = Data("secret message".utf8)
        var ciphertext = try encryptState.encryptWithAD(Data(), plaintext: plaintext)

        // Ensure ciphertext is valid before tampering
        #expect(!ciphertext.isEmpty)

        // Tamper with the last byte (part of auth tag)
        let lastIndex = ciphertext.index(before: ciphertext.endIndex)
        ciphertext[lastIndex] ^= 0xFF

        #expect(throws: (any Error).self) {
            _ = try decryptState.decryptWithAD(Data(), ciphertext: ciphertext)
        }
    }

    @Test("CipherState decryption fails with tampered ciphertext")
    func testCipherStateCiphertextTamper() throws {
        let key = SymmetricKey(size: .bits256)
        var encryptState = NoiseCipherState(key: key)
        var decryptState = NoiseCipherState(key: key)

        let plaintext = Data("secret message".utf8)
        var ciphertext = try encryptState.encryptWithAD(Data(), plaintext: plaintext)

        // Ensure ciphertext is valid before tampering
        #expect(!ciphertext.isEmpty)

        // Tamper with the first byte (ciphertext portion)
        ciphertext[ciphertext.startIndex] ^= 0xFF

        #expect(throws: (any Error).self) {
            _ = try decryptState.decryptWithAD(Data(), ciphertext: ciphertext)
        }
    }

    @Test("CipherState decryption fails with wrong associated data")
    func testCipherStateWrongAD() throws {
        let key = SymmetricKey(size: .bits256)
        var encryptState = NoiseCipherState(key: key)
        var decryptState = NoiseCipherState(key: key)

        let plaintext = Data("secret message".utf8)
        let ciphertext = try encryptState.encryptWithAD(Data("ad1".utf8), plaintext: plaintext)

        #expect(throws: (any Error).self) {
            _ = try decryptState.decryptWithAD(Data("ad2".utf8), ciphertext: ciphertext)
        }
    }

    // MARK: - SymmetricState Tests

    @Test("SymmetricState initializes correctly with protocol name")
    func testSymmetricStateInitialization() {
        let state = NoiseSymmetricState(protocolName: noiseProtocolName)

        // Protocol name is 34 bytes > 32, so it should be hashed
        #expect(state.handshakeHash.count == 32)
        #expect(state.chainingKey.count == 32)
        #expect(state.chainingKey == state.handshakeHash)
    }

    @Test("SymmetricState initializes with short protocol name")
    func testSymmetricStateShortProtocolName() {
        let shortName = "Noise_XX"
        let state = NoiseSymmetricState(protocolName: shortName)

        // Short name should be zero-padded, not hashed
        #expect(state.handshakeHash.count == 32)

        var expected = Data(shortName.utf8)
        expected.append(contentsOf: repeatElement(0 as UInt8, count: 32 - shortName.utf8.count))
        #expect(state.handshakeHash == expected)
    }

    @Test("SymmetricState mixHash updates handshake hash")
    func testSymmetricStateMixHash() {
        var state = NoiseSymmetricState(protocolName: noiseProtocolName)
        let originalHash = state.handshakeHash

        state.mixHash(Data("some data".utf8))

        #expect(state.handshakeHash != originalHash)
        #expect(state.handshakeHash.count == 32)
    }

    @Test("SymmetricState mixKey updates chaining key and cipher state")
    func testSymmetricStateMixKey() {
        var state = NoiseSymmetricState(protocolName: noiseProtocolName)
        let originalCK = state.chainingKey

        #expect(!state.cipherState.hasKey())

        state.mixKey(Data(repeating: 0x42, count: 32))

        #expect(state.chainingKey != originalCK)
        #expect(state.chainingKey.count == 32)
        #expect(state.cipherState.hasKey())
    }

    @Test("SymmetricState encryptAndHash works correctly")
    func testSymmetricStateEncryptAndHash() throws {
        var state = NoiseSymmetricState(protocolName: noiseProtocolName)

        // Mix in some key material to enable encryption
        state.mixKey(Data(repeating: 0x42, count: 32))

        let originalHash = state.handshakeHash
        let plaintext = Data("test plaintext".utf8)

        let ciphertext = try state.encryptAndHash(plaintext)

        // Ciphertext should be different from plaintext
        #expect(ciphertext != plaintext)
        // Hash should be updated
        #expect(state.handshakeHash != originalHash)
    }

    @Test("SymmetricState decryptAndHash works correctly")
    func testSymmetricStateDecryptAndHash() throws {
        var encryptState = NoiseSymmetricState(protocolName: noiseProtocolName)
        var decryptState = NoiseSymmetricState(protocolName: noiseProtocolName)

        // Same key material for both
        let keyMaterial = Data(repeating: 0x42, count: 32)
        encryptState.mixKey(keyMaterial)
        decryptState.mixKey(keyMaterial)

        let plaintext = Data("test plaintext".utf8)
        let ciphertext = try encryptState.encryptAndHash(plaintext)
        let decrypted = try decryptState.decryptAndHash(ciphertext)

        #expect(decrypted == plaintext)
        // Both should have the same handshake hash after the operation
        #expect(encryptState.handshakeHash == decryptState.handshakeHash)
    }

    @Test("SymmetricState split produces two independent cipher states")
    func testSymmetricStateSplit() throws {
        var state = NoiseSymmetricState(protocolName: noiseProtocolName)
        state.mixKey(Data(repeating: 0x42, count: 32))

        let (c1, c2) = state.split()

        #expect(c1.hasKey())
        #expect(c2.hasKey())

        // Encrypt with c1, should not be decryptable with c1 at same nonce
        var c1Encrypt = c1
        var c2Decrypt = c2

        let plaintext = Data("test".utf8)
        let ciphertext = try c1Encrypt.encryptWithAD(Data(), plaintext: plaintext)

        // c2 has different key, so decryption should fail
        #expect(throws: (any Error).self) {
            _ = try c2Decrypt.decryptWithAD(Data(), ciphertext: ciphertext)
        }
    }

    // MARK: - Key Agreement Tests

    @Test("noiseKeyAgreement produces consistent shared secret")
    func testKeyAgreementConsistent() throws {
        let privateKeyA = Curve25519.KeyAgreement.PrivateKey()
        let privateKeyB = Curve25519.KeyAgreement.PrivateKey()

        let sharedAB = try noiseKeyAgreement(privateKey: privateKeyA, publicKey: privateKeyB.publicKey)
        let sharedBA = try noiseKeyAgreement(privateKey: privateKeyB, publicKey: privateKeyA.publicKey)

        #expect(sharedAB == sharedBA)
        #expect(sharedAB.count == 32)
    }

    @Test("noiseKeyAgreement produces different secrets for different keys")
    func testKeyAgreementDifferent() throws {
        let privateKeyA = Curve25519.KeyAgreement.PrivateKey()
        let privateKeyB = Curve25519.KeyAgreement.PrivateKey()
        let privateKeyC = Curve25519.KeyAgreement.PrivateKey()

        let sharedAB = try noiseKeyAgreement(privateKey: privateKeyA, publicKey: privateKeyB.publicKey)
        let sharedAC = try noiseKeyAgreement(privateKey: privateKeyA, publicKey: privateKeyC.publicKey)

        #expect(sharedAB != sharedAC)
    }

    // MARK: - Small-Order Point Validation Tests

    @Test("validateX25519PublicKey rejects zero point")
    func testValidateRejectsZeroPoint() {
        let zeroPoint = Data(repeating: 0, count: 32)
        #expect(!validateX25519PublicKey(zeroPoint))
    }

    @Test("validateX25519PublicKey rejects one point")
    func testValidateRejectsOnePoint() {
        var onePoint = Data(repeating: 0, count: 32)
        onePoint[0] = 1
        #expect(!validateX25519PublicKey(onePoint))
    }

    @Test("validateX25519PublicKey rejects order 8 point (ec...7f)")
    func testValidateRejectsOrder8Point1() {
        let point = Data(hexString: "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f")!
        #expect(!validateX25519PublicKey(point))
    }

    @Test("validateX25519PublicKey rejects order 8 point (e0...00)")
    func testValidateRejectsOrder8Point2() {
        let point = Data(hexString: "e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b800")!
        #expect(!validateX25519PublicKey(point))
    }

    @Test("validateX25519PublicKey rejects order 8 point (5f...57)")
    func testValidateRejectsOrder8Point3() {
        let point = Data(hexString: "5f9c95bca3508c24b1d0b1559c83ef5b04445cc4581c8e86d8224eddd09f1157")!
        #expect(!validateX25519PublicKey(point))
    }

    @Test("validateX25519PublicKey rejects order 2 point (ed...7f)")
    func testValidateRejectsOrder2Point() {
        let point = Data(hexString: "edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f")!
        #expect(!validateX25519PublicKey(point))
    }

    @Test("Non-canonical high-bit twist encodings (da/db...ff) are safe under X25519")
    func testNonCanonicalTwistEncodingsAreSafe() throws {
        // These two values were previously in the static blocklist but are NOT
        // genuine small-order points: with the high bit set and unreduced, X25519
        // clamping/reduction maps them to ordinary points that yield a NON-ZERO
        // shared secret. They are not a security threat, so rejecting them would
        // be incorrect. This documents that the canonical-7 alignment (Finding 4)
        // does not weaken any real guarantee — the all-zero guard rejects every
        // point that actually produces a zero secret.
        let nonCanonical = [
            "daffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
            "dbffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
        ]
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        for hex in nonCanonical {
            let raw = Data(hexString: hex)!
            let publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw)
            let secret = try noiseKeyAgreement(privateKey: privateKey, publicKey: publicKey)
            #expect(!secret.allSatisfy { $0 == 0 }, "Non-canonical encoding \(hex) should yield a non-zero secret")
        }
    }

    @Test("validateX25519PublicKey accepts valid public key")
    func testValidateAcceptsValidKey() {
        // Generate a valid X25519 key pair
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let publicKey = Data(privateKey.publicKey.rawRepresentation)
        #expect(validateX25519PublicKey(publicKey))
    }

    @Test("validateX25519PublicKey accepts multiple valid keys")
    func testValidateAcceptsMultipleValidKeys() {
        for _ in 0..<10 {
            let privateKey = Curve25519.KeyAgreement.PrivateKey()
            let publicKey = Data(privateKey.publicKey.rawRepresentation)
            #expect(validateX25519PublicKey(publicKey))
        }
    }

    @Test("Canonical small-order points are rejected by the static fast-check")
    func testCanonicalSmallOrderPointsRejectedByStaticCheck() {
        // The canonical libsodium 7-element blocklist. These are caught by the
        // static defense-in-depth fast-check validateX25519PublicKey.
        let canonicalHex = [
            "0000000000000000000000000000000000000000000000000000000000000000", // 0, order 1
            "0100000000000000000000000000000000000000000000000000000000000000", // 1, order 1
            "e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b800", // order 8
            "5f9c95bca3508c24b1d0b1559c83ef5b04445cc4581c8e86d8224eddd09f1157", // order 8
            "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f", // p-1, order 2
            "edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f", // p, order 4
            "eeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f", // p+1, order 1
        ]

        for hex in canonicalHex {
            let point = Data(hexString: hex)!
            #expect(!validateX25519PublicKey(point), "Canonical small-order point \(hex) should be rejected by the static check")
        }
    }

    @Test("All canonical small-order points are rejected by the authoritative key-agreement guard")
    func testAllSmallOrderPointsRejected() {
        // The genuine X25519 small-order points (canonical libsodium 7-element
        // set). Each yields an all-zero shared secret or is rejected outright by
        // CryptoKit; the authoritative guard in noiseKeyAgreement rejects ALL of
        // them with the typed NoiseError.invalidKey — never a silent fallback.
        let smallOrderPointsHex = [
            "0000000000000000000000000000000000000000000000000000000000000000", // 0, order 1
            "0100000000000000000000000000000000000000000000000000000000000000", // 1, order 1
            "e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b800", // order 8
            "5f9c95bca3508c24b1d0b1559c83ef5b04445cc4581c8e86d8224eddd09f1157", // order 8
            "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f", // p-1, order 2
            "edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f", // p, order 4
            "eeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f", // p+1, order 1
        ]

        for hex in smallOrderPointsHex {
            let point = Data(hexString: hex)!
            expectKeyAgreementRejects(point, label: hex)
        }
    }

    // MARK: - Small-Order Test Helpers

    /// Asserts that agreeing a freshly generated private key against `rawPublicKey`
    /// is rejected by the authoritative all-zero shared-secret guard in
    /// noiseKeyAgreement (NoiseError.invalidKey).
    private func expectKeyAgreementRejects(_ rawPublicKey: Data, label: String = "") {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let publicKey: Curve25519.KeyAgreement.PublicKey
        do {
            publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: rawPublicKey)
        } catch {
            // CryptoKit rejected the encoding outright — that is also a valid
            // rejection of the malicious point.
            return
        }
        do {
            _ = try noiseKeyAgreement(privateKey: privateKey, publicKey: publicKey)
            Issue.record("Expected NoiseError.invalidKey for small-order point \(label)")
        } catch let error as NoiseError {
            guard case .invalidKey = error else {
                Issue.record("Expected NoiseError.invalidKey, got \(error) for \(label)")
                return
            }
        } catch {
            Issue.record("Expected NoiseError.invalidKey, got \(error) for \(label)")
        }
    }
}

// MARK: - Test Helpers

private extension Data {
    init?(hexString: String) {
        let hex = hexString.lowercased()
        var data = Data()
        var index = hex.startIndex

        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard nextIndex <= hex.endIndex else { return nil }
            let byteString = hex[index..<nextIndex]
            guard let byte = UInt8(byteString, radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }

        self = data
    }
}
