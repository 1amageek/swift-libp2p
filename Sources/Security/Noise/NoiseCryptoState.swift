/// NoiseCryptoState - Cryptographic state management for Noise protocol
import Foundation
import Crypto
import P2PCore

// MARK: - CipherState

/// Manages encryption/decryption state for Noise protocol.
///
/// The CipherState holds a symmetric key and a nonce counter.
/// The nonce is incremented after each encryption or decryption operation.
struct NoiseCipherState: Sendable {
    /// The symmetric key (32 bytes), nil until initialized via MixKey.
    private var key: SymmetricKey?

    /// The nonce counter, incremented after each operation.
    private var nonce: UInt64 = 0

    /// Creates an empty CipherState with no key.
    init() {
        self.key = nil
    }

    /// Creates a CipherState with the given key.
    init(key: SymmetricKey) {
        self.key = key
    }

    /// Returns true if a key has been set.
    func hasKey() -> Bool {
        key != nil
    }

    /// Encrypts plaintext with associated data.
    ///
    /// - Parameters:
    ///   - ad: Associated data (authenticated but not encrypted)
    ///   - plaintext: Data to encrypt
    /// - Returns: Ciphertext with auth tag appended
    mutating func encryptWithAD(_ ad: Data, plaintext: Data) throws -> Data {
        guard let key = key else {
            // No key set, return plaintext as-is (per Noise spec)
            return plaintext
        }

        guard nonce < UInt64.max else {
            throw NoiseError.nonceOverflow
        }

        let nonceBytes = makeNonce(nonce)
        let chachaNonce = try ChaChaPoly.Nonce(data: nonceBytes)

        let sealedBox = try ChaChaPoly.seal(
            plaintext,
            using: key,
            nonce: chachaNonce,
            authenticating: ad
        )

        nonce += 1

        // Write ciphertext + tag into a single pre-allocated buffer (avoids concatenation copy)
        var result = Data(capacity: sealedBox.ciphertext.count + noiseAuthTagSize)
        result.append(contentsOf: sealedBox.ciphertext)
        result.append(contentsOf: sealedBox.tag)
        return result
    }

    /// Decrypts ciphertext with associated data.
    ///
    /// - Parameters:
    ///   - ad: Associated data
    ///   - ciphertext: Data to decrypt (ciphertext + auth tag)
    /// - Returns: Decrypted plaintext
    mutating func decryptWithAD(_ ad: Data, ciphertext: Data) throws -> Data {
        guard let key = key else {
            // No key set, return ciphertext as-is (per Noise spec)
            return ciphertext
        }

        guard ciphertext.count >= noiseAuthTagSize else {
            throw NoiseError.decryptionFailed
        }

        guard nonce < UInt64.max else {
            throw NoiseError.nonceOverflow
        }

        let nonceBytes = makeNonce(nonce)
        let chachaNonce = try ChaChaPoly.Nonce(data: nonceBytes)

        let ciphertextOnly = ciphertext.dropLast(noiseAuthTagSize)
        let tag = ciphertext.suffix(noiseAuthTagSize)

        let sealedBox = try ChaChaPoly.SealedBox(
            nonce: chachaNonce,
            ciphertext: ciphertextOnly,
            tag: tag
        )

        let plaintext = try ChaChaPoly.open(sealedBox, using: key, authenticating: ad)
        nonce += 1

        return plaintext
    }

    /// Creates a 12-byte nonce from a counter.
    /// Format: 4 bytes zero + 8 bytes little-endian counter
    private func makeNonce(_ n: UInt64) -> Data {
        // Build 12-byte nonce on stack using fixed-size tuple (avoids heap allocation)
        var buf: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
            (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        withUnsafeMutableBytes(of: &buf) { ptr in
            // First 4 bytes are zero (already initialized)
            // Bytes 4..11 = little-endian counter
            var le = n.littleEndian
            withUnsafeBytes(of: &le) { src in
                ptr.baseAddress!.advanced(by: 4).copyMemory(from: src.baseAddress!, byteCount: 8)
            }
        }
        return withUnsafeBytes(of: &buf) { Data($0) }
    }
}

// MARK: - SymmetricState

/// Manages the symmetric cryptographic state during Noise handshake.
///
/// The SymmetricState holds:
/// - `ck`: Chaining key for key derivation
/// - `h`: Handshake hash for transcript binding
/// - `cipherState`: For encryption during handshake
struct NoiseSymmetricState: Sendable {
    /// Chaining key (32 bytes).
    private(set) var chainingKey: Data

    /// Handshake hash (32 bytes).
    private(set) var handshakeHash: Data

    /// Cipher state for encryption/decryption.
    private(set) var cipherState: NoiseCipherState

    /// Initializes the SymmetricState with a protocol name.
    ///
    /// Per Noise spec:
    /// - If protocol name <= 32 bytes, h = name padded with zeros
    /// - If protocol name > 32 bytes, h = SHA256(name)
    /// - ck = h
    init(protocolName: String) {
        let nameData = Data(protocolName.utf8)

        if nameData.count <= 32 {
            var h = nameData
            h.append(contentsOf: repeatElement(0 as UInt8, count: 32 - nameData.count))
            self.handshakeHash = h
        } else {
            self.handshakeHash = Data(SHA256.hash(data: nameData))
        }

        self.chainingKey = handshakeHash
        self.cipherState = NoiseCipherState()
    }

    /// Mixes data into the handshake hash.
    /// h = SHA256(h || data)
    mutating func mixHash(_ data: Data) {
        var hasher = SHA256()
        hasher.update(data: handshakeHash)
        hasher.update(data: data)
        handshakeHash = Data(hasher.finalize())
    }

    /// Mixes key material into the chaining key and cipher key.
    ///
    /// Uses HKDF to derive:
    /// - New chaining key (ck)
    /// - New cipher key (k)
    mutating func mixKey(_ inputKeyMaterial: Data) {
        let ikm = SymmetricKey(data: inputKeyMaterial)
        let salt = chainingKey

        // HKDF-SHA256 with empty info, output 64 bytes
        let output = hkdfExpand(
            ikm: ikm,
            salt: salt,
            info: Data(),
            outputLength: 64
        )

        // First 32 bytes -> new chaining key
        chainingKey = Data(output.prefix(32))

        // Last 32 bytes -> new cipher key
        let cipherKey = SymmetricKey(data: output.suffix(32))
        cipherState = NoiseCipherState(key: cipherKey)
    }

    /// Encrypts plaintext and mixes the ciphertext into the hash.
    ///
    /// - Parameter plaintext: Data to encrypt
    /// - Returns: Ciphertext (may be same as plaintext if no key)
    mutating func encryptAndHash(_ plaintext: Data) throws -> Data {
        let ciphertext = try cipherState.encryptWithAD(handshakeHash, plaintext: plaintext)
        mixHash(ciphertext)
        return ciphertext
    }

    /// Decrypts ciphertext and mixes it into the hash.
    ///
    /// - Parameter ciphertext: Data to decrypt
    /// - Returns: Decrypted plaintext
    mutating func decryptAndHash(_ ciphertext: Data) throws -> Data {
        let plaintext = try cipherState.decryptWithAD(handshakeHash, ciphertext: ciphertext)
        mixHash(ciphertext)
        return plaintext
    }

    /// Splits the symmetric state into two cipher states for transport.
    ///
    /// Returns (initiator's send, initiator's receive) cipher states.
    /// The responder should swap these.
    func split() -> (c1: NoiseCipherState, c2: NoiseCipherState) {
        let ikm = SymmetricKey(data: Data(repeating: 0, count: 0))
        let salt = chainingKey

        let output = hkdfExpand(
            ikm: ikm,
            salt: salt,
            info: Data(),
            outputLength: 64
        )

        let k1 = SymmetricKey(data: output.prefix(32))
        let k2 = SymmetricKey(data: output.suffix(32))

        return (NoiseCipherState(key: k1), NoiseCipherState(key: k2))
    }

    /// HKDF key derivation using SHA-256.
    private func hkdfExpand(
        ikm: SymmetricKey,
        salt: Data,
        info: Data,
        outputLength: Int
    ) -> Data {
        let saltKey = SymmetricKey(data: salt)
        let prk = HMAC<SHA256>.authenticationCode(
            for: ikm.withUnsafeBytes { Data($0) },
            using: saltKey
        )

        let prkKey = SymmetricKey(data: Data(prk))

        var output = Data(capacity: outputLength)
        var t = Data()
        var counter: UInt8 = 1

        while output.count < outputLength {
            var input = Data(capacity: t.count + info.count + 1)
            input.append(t)
            input.append(info)
            input.append(counter)

            let block = HMAC<SHA256>.authenticationCode(
                for: input,
                using: prkKey
            )
            t = Data(block)
            output.append(t)
            counter += 1
        }

        return Data(output.prefix(outputLength))
    }
}

// MARK: - Key Agreement Helper

/// Performs X25519 Diffie-Hellman key agreement.
///
/// - Parameters:
///   - privateKey: Local private key
///   - publicKey: Remote public key
/// - Returns: Shared secret (32 bytes)
/// - Throws: `NoiseError.invalidKey` if the public key is a small-order point
///   resulting in a zero shared secret.
func noiseKeyAgreement(
    privateKey: Curve25519.KeyAgreement.PrivateKey,
    publicKey: Curve25519.KeyAgreement.PublicKey
) throws -> Data {
    let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
    let secretData = sharedSecret.withUnsafeBytes { Data($0) }

    // Reject small-order points that result in all-zero shared secret.
    // This prevents attacks using crafted public keys.
    guard !secretData.allSatisfy({ $0 == 0 }) else {
        throw NoiseError.invalidKey
    }

    return secretData
}

// MARK: - Small-Order Point Validation

/// Known small-order points for X25519 (little-endian, 32 bytes).
/// These points result in a shared secret of all zeros and must be rejected.
/// Reference: https://cr.yp.to/ecdh.html#validate
private let x25519SmallOrderPoints: Set<Data> = {
    // The 8 small-order points in X25519 that yield all-zero shared secrets.
    // We check for these explicitly in addition to the zero-check in noiseKeyAgreement.
    var points = Set<Data>()

    // Point 1: 0 (order 1 - neutral element)
    points.insert(Data(repeating: 0, count: 32))

    // Point 2: 1 (order 4)
    var one = Data(repeating: 0, count: 32)
    one[0] = 1
    points.insert(one)

    // Point 3: order 8 point (little-endian hex)
    // ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f
    guard let p3 = Data(hexString: "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f") else {
        preconditionFailure("Invalid hex constant for X25519 small-order point 3")
    }
    points.insert(p3)

    // Point 4: order 8 point
    // e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b800
    guard let p4 = Data(hexString: "e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b800") else {
        preconditionFailure("Invalid hex constant for X25519 small-order point 4")
    }
    points.insert(p4)

    // Point 5: order 8 point
    // 5f9c95bca3508c24b1d0b1559c83ef5b04445cc4581c8e86d8224eddd09f1157
    guard let p5 = Data(hexString: "5f9c95bca3508c24b1d0b1559c83ef5b04445cc4581c8e86d8224eddd09f1157") else {
        preconditionFailure("Invalid hex constant for X25519 small-order point 5")
    }
    points.insert(p5)

    // Point 6: order 2 point (p-1 clamped)
    // edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f
    guard let p6 = Data(hexString: "edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f") else {
        preconditionFailure("Invalid hex constant for X25519 small-order point 6")
    }
    points.insert(p6)

    // Point 7: order 8 point on twist
    // daffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
    guard let p7 = Data(hexString: "daffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff") else {
        preconditionFailure("Invalid hex constant for X25519 small-order point 7")
    }
    points.insert(p7)

    // Point 8: order 8 point on twist
    // dbffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
    guard let p8 = Data(hexString: "dbffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff") else {
        preconditionFailure("Invalid hex constant for X25519 small-order point 8")
    }
    points.insert(p8)

    return points
}()

/// Validates that an X25519 public key is not a small-order point.
///
/// - Parameter publicKey: The raw public key bytes (32 bytes)
/// - Returns: True if the key is valid (not a small-order point)
func validateX25519PublicKey(_ publicKey: Data) -> Bool {
    // Check against known small-order points
    guard !x25519SmallOrderPoints.contains(publicKey) else {
        return false
    }
    return true
}

// Data(hexString:) is provided by P2PCore/Utilities/HexEncoding.swift
