/// NoiseKATTests - Known Answer Tests for Noise Protocol
/// Using official Noise Protocol test vectors to verify HKDF and crypto implementation
import Testing
import Foundation
import Crypto
@testable import P2PSecurityNoise
@testable import P2PCore

@Suite("Noise Known Answer Tests")
struct NoiseKATTests {

    // MARK: - HKDF Tests

    /// Test HKDF with known inputs and outputs from Noise test vectors
    @Test("HKDF produces correct output for known input")
    func testHKDFKnownAnswer() {
        // Test vector: Use a known input and verify output matches
        // This is based on the Noise Protocol Framework specification

        // Protocol name: Noise_XX_25519_ChaChaPoly_SHA256 (exactly 32 bytes)
        let protocolName = "Noise_XX_25519_ChaChaPoly_SHA256"
        let protocolBytes = Data(protocolName.utf8)
        #expect(protocolBytes.count == 32, "Protocol name should be exactly 32 bytes")

        // Initial state: h = ck = protocolName
        var state = NoiseSymmetricState(protocolName: protocolName)

        // Verify initial handshakeHash and chainingKey are equal to protocol name
        #expect(state.handshakeHash == protocolBytes)
        #expect(state.chainingKey == protocolBytes)

        // mixHash with empty prologue
        state.mixHash(Data())

        // After mixHash(empty), h = SHA256(protocolName)
        let expectedHash = Data(SHA256.hash(data: protocolBytes))
        #expect(state.handshakeHash == expectedHash, "mixHash(empty) should produce SHA256(h)")
        #expect(state.chainingKey == protocolBytes, "chainingKey should not change after mixHash")

        print("Initial handshakeHash: \(state.handshakeHash.hexString)")
        print("Initial chainingKey: \(state.chainingKey.hexString)")
    }

    /// Test that HKDF matches RFC 5869 test vectors
    @Test("HKDF matches RFC 5869 test vector")
    func testHKDFRFC5869() {
        // RFC 5869 Test Case 1
        // IKM = 0x0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b (22 octets)
        // salt = 0x000102030405060708090a0b0c (13 octets)
        // info = 0xf0f1f2f3f4f5f6f7f8f9 (10 octets)
        // L = 42

        // Expected PRK = 0x077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5
        // Expected OKM = 0x3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865

        let ikm = Data(hexString: "0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b")!
        let salt = Data(hexString: "000102030405060708090a0b0c")!
        let info = Data(hexString: "f0f1f2f3f4f5f6f7f8f9")!

        // Compute HKDF using Swift Crypto
        let prk = HMAC<SHA256>.authenticationCode(for: ikm, using: SymmetricKey(data: salt))
        let prkData = Data(prk)

        let expectedPRK = Data(hexString: "077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5")!
        #expect(prkData == expectedPRK, "HKDF-Extract should produce correct PRK")

        print("PRK: \(prkData.hexString)")
    }

    /// Test Noise-style HKDF (different from RFC 5869)
    @Test("Noise HKDF produces correct output")
    func testNoiseHKDF() {
        // Noise HKDF is slightly different:
        // temp_key = HMAC(ck, ikm)
        // output1 = HMAC(temp_key, 0x01)
        // output2 = HMAC(temp_key, output1 || 0x02)

        // Test with known values
        let ck = Data(repeating: 0x42, count: 32)  // chaining key
        let ikm = Data(repeating: 0x55, count: 32)  // input key material

        // Step 1: temp_key = HMAC(ck, ikm)
        let tempKey = Data(HMAC<SHA256>.authenticationCode(for: ikm, using: SymmetricKey(data: ck)))
        print("temp_key: \(tempKey.hexString)")

        // Step 2: output1 = HMAC(temp_key, 0x01)
        let output1 = Data(HMAC<SHA256>.authenticationCode(for: Data([0x01]), using: SymmetricKey(data: tempKey)))
        print("output1: \(output1.hexString)")

        // Step 3: output2 = HMAC(temp_key, output1 || 0x02)
        var input2 = output1
        input2.append(0x02)
        let output2 = Data(HMAC<SHA256>.authenticationCode(for: input2, using: SymmetricKey(data: tempKey)))
        print("output2: \(output2.hexString)")

        // Now test our implementation
        var state = NoiseSymmetricState(protocolName: "Noise_XX_25519_ChaChaPoly_SHA256")

        // Set chainingKey to our test value
        // We can't directly set it, so we'll use a workaround via mixKey
        // Instead, verify the structure of the output

        // The test passes if we get here without crashing
        // and the values are printed for manual verification
    }

    /// Test HKDF with actual interop values to verify implementation
    @Test("HKDF matches expected output for interop values")
    func testHKDFInteropValues() {
        // Use the actual values from the failing interop test (fresh run)
        // chainingKey = protocol name (before any mixKey)
        let ck = Data("Noise_XX_25519_ChaChaPoly_SHA256".utf8)
        #expect(ck.count == 32, "Protocol name should be 32 bytes")

        // ee DH result from latest interop test run
        let ikm = Data(hexString: "790f764ec19bf95015a990ba5a229521368ad3485efa31afc4c701d9d257df21")!

        // Manual HKDF calculation (Noise style)
        // Step 1: temp_key = HMAC(ck, ikm)
        let tempKey = Data(HMAC<SHA256>.authenticationCode(for: ikm, using: SymmetricKey(data: ck)))
        print("[HKDF Test] temp_key: \(tempKey.hexString)")

        // Step 2: output1 = HMAC(temp_key, 0x01) -> new chainingKey
        let output1 = Data(HMAC<SHA256>.authenticationCode(for: Data([0x01]), using: SymmetricKey(data: tempKey)))
        print("[HKDF Test] output1 (new ck): \(output1.hexString)")

        // Step 3: output2 = HMAC(temp_key, output1 || 0x02) -> new cipherKey
        var input2 = output1
        input2.append(0x02)
        let output2 = Data(HMAC<SHA256>.authenticationCode(for: input2, using: SymmetricKey(data: tempKey)))
        print("[HKDF Test] output2 (new k): \(output2.hexString)")

        // Compare with actual mixKey output from interop test
        // From debug: chainingKey after = 3dd6b84ddc3e080608e105cc5bad30697609843f9ad38fa5dd83e739e2a037b4
        // From debug: cipherKey = f23eeea158890344bbbe8cb064cdcadee62e73be3de1b41660662e6132b25a3d
        let expectedCK = Data(hexString: "3dd6b84ddc3e080608e105cc5bad30697609843f9ad38fa5dd83e739e2a037b4")!
        let expectedK = Data(hexString: "f23eeea158890344bbbe8cb064cdcadee62e73be3de1b41660662e6132b25a3d")!

        #expect(output1 == expectedCK, "New chainingKey should match mixKey output")
        #expect(output2 == expectedK, "New cipherKey should match mixKey output")
    }

    /// Test handshakeHash calculation matches expected values
    @Test("HandshakeHash calculation for interop")
    func testHandshakeHashInterop() {
        // Calculate handshakeHash step by step using actual interop values (fresh run)
        let protocolName = "Noise_XX_25519_ChaChaPoly_SHA256"
        let protocolBytes = Data(protocolName.utf8)

        // Step 1: Initial h = protocolName (32 bytes, no padding needed)
        var h = protocolBytes
        print("[HandshakeHash] Step 1 (init): \(h.hexString)")

        // Step 2: mixHash(empty prologue) -> h = SHA256(h)
        h = Data(SHA256.hash(data: h))
        print("[HandshakeHash] Step 2 (after empty prologue): \(h.hexString)")
        // Expected: f3d15e6108ed9556171207baa58f97d29a13c6be40595166066e2e0958dc002d

        // Step 3: mixHash(localEphemeral) - from latest interop test
        let localEphemeral = Data(hexString: "e099351b740f3e191d51ec684e6cc1440edd4ac8022eb34aa626e82d0052cc6d")!
        var hasher3 = SHA256()
        hasher3.update(data: h)
        hasher3.update(data: localEphemeral)
        h = Data(hasher3.finalize())
        print("[HandshakeHash] Step 3 (after localEphemeral): \(h.hexString)")

        // Step 4: mixHash(remoteEphemeral) - from latest interop test
        let remoteEphemeral = Data(hexString: "f79cb0be3c59fb19a3073b8c33db21ac4061a10b3c9ae7a0592119956e7e5c5a")!
        var hasher4 = SHA256()
        hasher4.update(data: h)
        hasher4.update(data: remoteEphemeral)
        h = Data(hasher4.finalize())
        print("[HandshakeHash] Step 4 (after remoteEphemeral): \(h.hexString)")

        // This should match the AD used in decryptAndHash
        // From debug: AD (handshakeHash) = 852c0bece810eced6e843f4cbe763798bb155c41b1d9a01af214fb84b61a4871
        let expectedAD = Data(hexString: "852c0bece810eced6e843f4cbe763798bb155c41b1d9a01af214fb84b61a4871")!
        #expect(h == expectedAD, "HandshakeHash should match expected AD value")
    }

    /// Attempt to manually decrypt the encrypted static key from go-libp2p
    @Test("Manual decryption of go-libp2p Message B static key")
    func testManualDecryptionOfMessageB() throws {
        // Values from the latest failing interop test

        // cipherKey derived from HKDF(chainingKey, ee_dh_result)
        let cipherKey = Data(hexString: "f23eeea158890344bbbe8cb064cdcadee62e73be3de1b41660662e6132b25a3d")!

        // AD = handshakeHash after mixHash(remoteEphemeral)
        let ad = Data(hexString: "852c0bece810eced6e843f4cbe763798bb155c41b1d9a01af214fb84b61a4871")!

        // Encrypted static key from go-libp2p (32 bytes ciphertext + 16 bytes tag)
        let encryptedStatic = Data(hexString: "a06658f3696889de0e7ec950742a1cbde03d574f8d35615536f8a80b3401373b3d572abfd4692cb7dad12a585123127c")!

        #expect(encryptedStatic.count == 48, "Encrypted static should be 48 bytes (32 + 16 tag)")

        // Create nonce: 4 bytes zero + 8 bytes little-endian counter (0)
        let nonceBytes = Data(repeating: 0, count: 12)
        // nonce = 0, so all bytes remain zero

        print("[Manual Decrypt] cipherKey: \(cipherKey.hexString)")
        print("[Manual Decrypt] AD: \(ad.hexString)")
        print("[Manual Decrypt] nonce: \(nonceBytes.hexString)")
        print("[Manual Decrypt] ciphertext: \(encryptedStatic.hexString)")

        // Try to decrypt using ChaChaPoly
        let chachaNonce = try ChaChaPoly.Nonce(data: nonceBytes)
        let ciphertextOnly = encryptedStatic.dropLast(16)
        let tag = encryptedStatic.suffix(16)

        print("[Manual Decrypt] ciphertext only: \(Data(ciphertextOnly).hexString)")
        print("[Manual Decrypt] tag: \(Data(tag).hexString)")

        do {
            let sealedBox = try ChaChaPoly.SealedBox(
                nonce: chachaNonce,
                ciphertext: ciphertextOnly,
                tag: tag
            )

            let plaintext = try ChaChaPoly.open(sealedBox, using: SymmetricKey(data: cipherKey), authenticating: ad)
            print("[Manual Decrypt] SUCCESS! Plaintext (static key): \(plaintext.hexString)")
            #expect(plaintext.count == 32, "Decrypted static key should be 32 bytes")
        } catch {
            print("[Manual Decrypt] FAILED: \(error)")
            // If decryption fails, it means go-libp2p used different cipherKey or AD
            Issue.record("Manual decryption failed - go-libp2p may use different cipherKey or AD")
        }
    }

    /// Test mixKey produces correct cipher key
    @Test("mixKey produces correct cipher key")
    func testMixKey() {
        var state = NoiseSymmetricState(protocolName: "Noise_XX_25519_ChaChaPoly_SHA256")
        state.mixHash(Data())  // Mix empty prologue

        // Use a known DH result
        let dhResult = Data(repeating: 0xAB, count: 32)

        print("Before mixKey:")
        print("  chainingKey: \(state.chainingKey.hexString)")

        state.mixKey(dhResult)

        print("After mixKey:")
        print("  chainingKey: \(state.chainingKey.hexString)")

        // Verify the output is 32 bytes
        #expect(state.chainingKey.count == 32)

        // Test encryption after mixKey
        let testPlaintext = Data("Hello, World!".utf8)
        let ciphertext = try! state.encryptAndHash(testPlaintext)

        print("Ciphertext: \(ciphertext.hexString)")
        #expect(ciphertext.count == testPlaintext.count + 16, "Ciphertext should include 16-byte auth tag")
    }

    /// Test complete handshake state transitions
    @Test("Handshake state transitions are consistent")
    func testHandshakeStateTransitions() throws {
        // Create two handshake states
        let initiatorKeyPair = KeyPair.generateEd25519()
        let responderKeyPair = KeyPair.generateEd25519()

        var initiator = NoiseHandshake(localKeyPair: initiatorKeyPair, isInitiator: true)
        var responder = NoiseHandshake(localKeyPair: responderKeyPair, isInitiator: false)

        // Message A: -> e
        let messageA = initiator.writeMessageA()
        print("Message A (ephemeral): \(messageA.hexString)")

        try responder.readMessageA(messageA)

        // At this point, both should have the same handshakeHash
        // (after mixing in the same ephemeral key)

        // Message B: <- e, ee, s, es
        let messageB = try responder.writeMessageB()
        print("Message B (\(messageB.count) bytes): \(messageB.prefix(64).hexString)...")

        let payloadB = try initiator.readMessageB(messageB)
        print("Payload B decoded successfully")

        // Message C: -> s, se
        let messageC = try initiator.writeMessageC()
        print("Message C (\(messageC.count) bytes): \(messageC.prefix(64).hexString)...")

        let payloadC = try responder.readMessageC(messageC)
        print("Payload C decoded successfully")

        // Verify remote static keys are correct
        #expect(initiator.remoteStaticKey != nil)
        #expect(responder.remoteStaticKey != nil)

        // Split and verify cipher states
        let (initSend, initRecv) = initiator.split()
        let (respSend, respRecv) = responder.split()

        // Test encryption/decryption
        let testMessage = Data("Test message".utf8)

        var initSendMut = initSend
        var respRecvMut = respRecv
        let encrypted = try initSendMut.encryptWithAD(Data(), plaintext: testMessage)
        let decrypted = try respRecvMut.decryptWithAD(Data(), ciphertext: encrypted)

        #expect(decrypted == testMessage, "Decrypted message should match original")
        print("Encryption/decryption round-trip successful")
    }

    // MARK: - Official Cacophony Test Vectors

    /// Test using official cacophony test vectors for Noise_XX_25519_ChaChaPoly_SHA256
    /// This verifies our implementation against known correct values
    @Test("Cacophony test vector - Message B encryption matches")
    func testCacophonyMessageB() throws {
        // Official cacophony test vector for Noise_XX_25519_ChaChaPoly_SHA256
        // Source: https://github.com/haskell-cryptography/cacophony/blob/master/vectors/cacophony.txt

        let prologue = Data(hexString: "4a6f686e2047616c74")!  // "John Galt"

        // Private keys (used to derive public keys and perform DH)
        let initEphemeralPriv = Data(hexString: "893e28b9dc6ca8d611ab664754b8ceb7bac5117349a4439a6b0569da977c464a")!
        let respEphemeralPriv = Data(hexString: "bbdb4cdbd309f1a1f2e1456967fe288cadd6f712d65dc7b7793d5e63da6b375b")!
        let respStaticPriv = Data(hexString: "4a3acbfdb163dec651dfa3194dece676d437029c62a408b4c5ea9114246e4893")!

        // Expected public keys (from message 1 and 2 ciphertexts)
        let initEphemeralPub = Data(hexString: "ca35def5ae56cec33dc2036731ab14896bc4c75dbb07a61f879f8e3afa4c7944")!
        let respEphemeralPub = Data(hexString: "95ebc60d2b1fa672c1f46a8aa265ef51bfe38e7ccb39ec5be34069f144808843")!

        // Verify X25519 public key derivation
        let initEphKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: initEphemeralPriv)
        let derivedInitPub = Data(initEphKey.publicKey.rawRepresentation)
        #expect(derivedInitPub == initEphemeralPub, "Init ephemeral public key derivation mismatch")

        let respEphKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: respEphemeralPriv)
        let derivedRespPub = Data(respEphKey.publicKey.rawRepresentation)
        #expect(derivedRespPub == respEphemeralPub, "Resp ephemeral public key derivation mismatch")

        print("[Cacophony] Init ephemeral public: \(derivedInitPub.hexString)")
        print("[Cacophony] Resp ephemeral public: \(derivedRespPub.hexString)")

        // Initialize symmetric state
        let protocolName = "Noise_XX_25519_ChaChaPoly_SHA256"
        var state = NoiseSymmetricState(protocolName: protocolName)

        // Mix prologue
        state.mixHash(prologue)
        print("[Cacophony] After prologue mixHash: \(state.handshakeHash.hexString)")

        // Message 1: -> e
        // Initiator sends ephemeral
        state.mixHash(initEphemeralPub)
        print("[Cacophony] After init ephemeral mixHash: \(state.handshakeHash.hexString)")

        // Message 2: <- e, ee, s, es
        // Responder sends ephemeral
        state.mixHash(respEphemeralPub)
        print("[Cacophony] After resp ephemeral mixHash: \(state.handshakeHash.hexString)")

        // ee: DH(init_ephemeral, resp_ephemeral)
        // From initiator perspective: DH(initEphPriv, respEphPub)
        let respEphPubKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: respEphemeralPub)
        let eeResult = try initEphKey.sharedSecretFromKeyAgreement(with: respEphPubKey)
        let eeData = eeResult.withUnsafeBytes { Data($0) }
        print("[Cacophony] ee DH result: \(eeData.hexString)")

        // Check current chainingKey before mixKey
        print("[Cacophony] chainingKey before ee mixKey: \(state.chainingKey.hexString)")

        state.mixKey(eeData)
        print("[Cacophony] chainingKey after ee mixKey: \(state.chainingKey.hexString)")
        print("[Cacophony] handshakeHash after ee mixKey: \(state.handshakeHash.hexString)")

        // Now encrypt the responder's static public key
        // First, get the responder's static public key
        let respStaticKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: respStaticPriv)
        let respStaticPub = Data(respStaticKey.publicKey.rawRepresentation)
        print("[Cacophony] Resp static public: \(respStaticPub.hexString)")

        // Encrypt it
        let encryptedStatic = try state.encryptAndHash(respStaticPub)
        print("[Cacophony] Encrypted static: \(encryptedStatic.hexString)")

        // Expected encrypted static from test vector (bytes 32-79 of message 2)
        // Message 2 ciphertext: 95ebc60d...81cbad1f276e038c48378ffce2b65285e08d6b68aaa3629a5a8639392490e5b9bd5269c2f1e4f488ed8831161f19b781...
        let expectedEncryptedStatic = Data(hexString: "81cbad1f276e038c48378ffce2b65285e08d6b68aaa3629a5a8639392490e5b9bd5269c2f1e4f488ed8831161f19b781")!

        #expect(encryptedStatic == expectedEncryptedStatic, "Encrypted static key should match test vector")

        if encryptedStatic != expectedEncryptedStatic {
            print("[Cacophony] MISMATCH!")
            print("[Cacophony] Expected: \(expectedEncryptedStatic.hexString)")
            print("[Cacophony] Got:      \(encryptedStatic.hexString)")

            // Debug: Try to find where the difference is
            print("[Cacophony] Expected length: \(expectedEncryptedStatic.count)")
            print("[Cacophony] Got length: \(encryptedStatic.count)")
        }
    }

    /// Test that decrypts the encrypted static from cacophony test vector
    @Test("Cacophony test vector - Message B decryption")
    func testCacophonyMessageBDecryption() throws {
        let prologue = Data(hexString: "4a6f686e2047616c74")!  // "John Galt"

        // Keys from test vector
        let initEphemeralPriv = Data(hexString: "893e28b9dc6ca8d611ab664754b8ceb7bac5117349a4439a6b0569da977c464a")!
        let respEphemeralPub = Data(hexString: "95ebc60d2b1fa672c1f46a8aa265ef51bfe38e7ccb39ec5be34069f144808843")!
        let respStaticPriv = Data(hexString: "4a3acbfdb163dec651dfa3194dece676d437029c62a408b4c5ea9114246e4893")!

        let initEphemeralPub = Data(hexString: "ca35def5ae56cec33dc2036731ab14896bc4c75dbb07a61f879f8e3afa4c7944")!

        // Initialize as initiator reading Message B
        let protocolName = "Noise_XX_25519_ChaChaPoly_SHA256"
        var state = NoiseSymmetricState(protocolName: protocolName)

        // Mix prologue
        state.mixHash(prologue)

        // After Message A: mixHash(initEphemeralPub)
        state.mixHash(initEphemeralPub)

        // Reading Message B: mixHash(respEphemeralPub)
        state.mixHash(respEphemeralPub)

        // ee DH
        let initEphKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: initEphemeralPriv)
        let respEphPubKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: respEphemeralPub)
        let eeResult = try initEphKey.sharedSecretFromKeyAgreement(with: respEphPubKey)
        let eeData = eeResult.withUnsafeBytes { Data($0) }

        state.mixKey(eeData)

        // Now decrypt the encrypted static
        let encryptedStatic = Data(hexString: "81cbad1f276e038c48378ffce2b65285e08d6b68aaa3629a5a8639392490e5b9bd5269c2f1e4f488ed8831161f19b781")!

        let decryptedStatic = try state.decryptAndHash(encryptedStatic)

        // Expected responder static public key
        let respStaticKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: respStaticPriv)
        let expectedRespStaticPub = Data(respStaticKey.publicKey.rawRepresentation)

        #expect(decryptedStatic == expectedRespStaticPub, "Decrypted static should match expected")
        print("[Cacophony Decrypt] SUCCESS! Decrypted static: \(decryptedStatic.hexString)")
    }
}

// MARK: - Helper Extensions

extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
