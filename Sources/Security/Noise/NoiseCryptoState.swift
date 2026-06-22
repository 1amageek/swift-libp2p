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
    mutating func encryptWithAD<AD: DataProtocol, Plaintext: DataProtocol>(
        _ ad: AD,
        plaintext: Plaintext
    ) throws -> Data {
        guard let key = key else {
            // No key set, return plaintext as-is (per Noise spec)
            return Data(plaintext)
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
    mutating func decryptWithAD<AD: DataProtocol, Ciphertext: RandomAccessCollection & DataProtocol>(
        _ ad: AD,
        ciphertext: Ciphertext
    ) throws -> Data where Ciphertext.Element == UInt8, Ciphertext.SubSequence: DataProtocol {
        guard let key = key else {
            // No key set, return ciphertext as-is (per Noise spec)
            return Data(ciphertext)
        }

        guard ciphertext.count >= noiseAuthTagSize else {
            throw NoiseError.decryptionFailed
        }

        guard nonce < UInt64.max else {
            throw NoiseError.nonceOverflow
        }

        let nonceBytes = makeNonce(nonce)
        let chachaNonce = try ChaChaPoly.Nonce(data: nonceBytes)

        let splitIndex = ciphertext.index(ciphertext.endIndex, offsetBy: -noiseAuthTagSize)
        let ciphertextOnly = ciphertext[..<splitIndex]
        let tag = ciphertext[splitIndex...]

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
                for i in 0..<8 {
                    ptr[4 + i] = src[i]
                }
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
    mutating func mixHash<DataBytes: DataProtocol>(_ data: DataBytes) {
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
    mutating func encryptAndHash<Plaintext: DataProtocol>(_ plaintext: Plaintext) throws -> Data {
        let ciphertext = try cipherState.encryptWithAD(handshakeHash, plaintext: plaintext)
        mixHash(ciphertext)
        return ciphertext
    }

    /// Decrypts ciphertext and mixes it into the hash.
    ///
    /// - Parameter ciphertext: Data to decrypt
    /// - Returns: Decrypted plaintext
    mutating func decryptAndHash<Ciphertext: RandomAccessCollection & DataProtocol>(
        _ ciphertext: Ciphertext
    ) throws -> Data where Ciphertext.Element == UInt8, Ciphertext.SubSequence: DataProtocol {
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

        // Extract: PRK = HMAC-Hash(salt, IKM)
        // Use withUnsafeBytes to avoid intermediate Data allocation for IKM
        let prk: HashedAuthenticationCode<SHA256> = ikm.withUnsafeBytes { ikmBuffer in
            HMAC<SHA256>.authenticationCode(
                for: ikmBuffer,
                using: saltKey
            )
        }

        // Create PRK key once, reuse for all expand iterations
        let prkKey: SymmetricKey = prk.withUnsafeBytes { prkBuffer in
            SymmetricKey(data: prkBuffer)
        }

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
            block.withUnsafeBytes { blockBuffer in
                t = Data(blockBuffer)
                output.append(contentsOf: blockBuffer)
            }
            counter += 1
        }

        return Data(output.prefix(outputLength))
    }
}

// MARK: - Key Agreement Helper

/// Performs X25519 Diffie-Hellman key agreement.
///
/// This is the AUTHORITATIVE guard against small-order / invalid public keys.
/// Two independent layers both reject a malicious point, and both surface the
/// SAME typed error (`NoiseError.invalidKey`) — never a silent fallback:
///
/// 1. CryptoKit's `sharedSecretFromKeyAgreement` itself rejects several
///    small-order encodings (throwing `CryptoKitError`); we translate that into
///    `NoiseError.invalidKey` since it means the peer presented an invalid key.
/// 2. The all-zero shared-secret check below catches any contributory point that
///    CryptoKit nevertheless accepts, yielding an all-zero secret.
///
/// - Parameters:
///   - privateKey: Local private key
///   - publicKey: Remote public key
/// - Returns: Shared secret (32 bytes)
/// - Throws: `NoiseError.invalidKey` if the public key is rejected by CryptoKit
///   or is a small-order point resulting in a zero shared secret.
func noiseKeyAgreement(
    privateKey: Curve25519.KeyAgreement.PrivateKey,
    publicKey: Curve25519.KeyAgreement.PublicKey
) throws -> Data {
    let sharedSecret: SharedSecret
    do {
        sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
    } catch {
        // CryptoKit rejected the public key (e.g. a small-order point). Surface
        // the libp2p-typed error rather than leaking CryptoKitError. This is a
        // rejection, NOT a fallback — agreement does not proceed.
        throw NoiseError.invalidKey
    }
    let secretData = sharedSecret.withUnsafeBytes { Data($0) }

    // Authoritative guard: reject small-order points that result in an all-zero
    // shared secret. This catches crafted public keys CryptoKit accepts.
    guard !secretData.allSatisfy({ $0 == 0 }) else {
        throw NoiseError.invalidKey
    }

    return secretData
}

// MARK: - Small-Order Point Validation

/// Canonical X25519 small-order points (little-endian, 32 bytes).
///
/// This is the 7-element blocklist used by libsodium's `has_small_order`
/// (`crypto_scalarmult_curve25519`). These are the canonical (reduced)
/// representatives of points whose order divides 8; agreeing against any of
/// them yields an all-zero shared secret.
///
/// IMPORTANT: This static blocklist is a defense-in-depth fast-reject only.
/// The *authoritative* guard against small-order / contributory-behaviour
/// attacks is the all-zero shared-secret rejection in `noiseKeyAgreement`,
/// which catches every malicious point — including non-canonical encodings
/// (e.g. unreduced twist representatives) that are NOT listed here. We
/// deliberately do not enumerate non-standard high-bit/unreduced variants in
/// this set; the runtime zero-check covers them.
///
/// Reference: libsodium `ed25519_ref10.c` blacklist; https://cr.yp.to/ecdh.html#validate
private let x25519SmallOrderPoints: Set<Data> = {
    let canonicalHex = [
        "0000000000000000000000000000000000000000000000000000000000000000", // 0, order 1
        "0100000000000000000000000000000000000000000000000000000000000000", // 1, order 1
        "e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b800", // order 8
        "5f9c95bca3508c24b1d0b1559c83ef5b04445cc4581c8e86d8224eddd09f1157", // order 8
        "ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f", // p-1, order 2
        "edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f", // p, order 4
        "eeffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f", // p+1, order 1
    ]
    var points = Set<Data>()
    for hex in canonicalHex {
        guard let point = Data(hexString: hex) else {
            preconditionFailure("Invalid hex constant for X25519 small-order point: \(hex)")
        }
        points.insert(point)
    }
    return points
}()

/// Performs a fast static check that an X25519 public key is not one of the
/// canonical small-order points.
///
/// This is a defense-in-depth pre-check, NOT the authoritative guard. A `true`
/// result does NOT prove the key is safe for key agreement — the all-zero
/// shared-secret rejection in `noiseKeyAgreement` is the authoritative guarantee
/// and catches small-order points (canonical or not) that this static set omits.
///
/// - Parameter publicKey: The raw public key bytes (32 bytes)
/// - Returns: False if the key is a known canonical small-order point.
func validateX25519PublicKey<PublicKeyBytes: DataProtocol>(_ publicKey: PublicKeyBytes) -> Bool {
    // Check against the canonical small-order points
    guard !x25519SmallOrderPoints.contains(Data(publicKey)) else {
        return false
    }
    return true
}

// Data(hexString:) is provided by P2PCore/Utilities/HexEncoding.swift
