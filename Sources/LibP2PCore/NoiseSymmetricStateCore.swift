/// Noise `SymmetricState` over the crypto seam (Embedded-clean, generic `<C>`).
///
/// Embedded-clean: no Foundation, no Crypto, no `any`, typed throws. Holds the
/// chaining key `ck`, the handshake hash `h`, and a ``NoiseCipherStateCore``.
/// `mixHash` uses `C.SHA256`; `mixKey`/`split` use the Noise two-output HKDF built
/// directly on `C.HMACSHA256` (RFC 5869 extract-and-expand, byte-identical to the
/// swift-crypto path the adapter shipped before the seam refactor).
///
/// The `Data` surface stays in the `P2PSecurityNoise` adapter, which bridges
/// `Data` ↔ `[UInt8]` and specialises at `C = NoiseFoundationProvider`.

import P2PCoreBytes
import P2PCoreCrypto

/// Manages the symmetric cryptographic state during a Noise handshake over `C`.
public struct NoiseSymmetricStateCore<C: CryptoProvider>: Sendable {

    /// Chaining key (32 bytes).
    public private(set) var chainingKey: [UInt8]

    /// Handshake hash (32 bytes).
    public private(set) var handshakeHash: [UInt8]

    /// Cipher state for encryption/decryption during the handshake.
    public private(set) var cipherState: NoiseCipherStateCore<C>

    /// Initializes the `SymmetricState` from a protocol name.
    ///
    /// Per the Noise spec: if the name fits in `digestLength` bytes, `h` is the
    /// name padded with zeros; otherwise `h = SHA256(name)`. `ck = h`.
    public init(protocolName: [UInt8]) {
        let digestLength = C.SHA256.digestLength
        if protocolName.count <= digestLength {
            var h = protocolName
            h.append(contentsOf: repeatElement(0 as UInt8, count: digestLength - protocolName.count))
            self.handshakeHash = h
        } else {
            self.handshakeHash = C.SHA256.hash(protocolName.span)
        }
        self.chainingKey = handshakeHash
        self.cipherState = NoiseCipherStateCore<C>()
    }

    /// Mixes `data` into the handshake hash: `h = SHA256(h || data)`.
    public mutating func mixHash(_ data: [UInt8]) {
        var hasher = C.SHA256()
        hasher.update(handshakeHash.span)
        hasher.update(data.span)
        handshakeHash = hasher.finalize()
    }

    /// Mixes input key material into `ck` and derives a new cipher key.
    ///
    /// HKDF(ck, ikm) → (ck', k); the cipher state is reset to a fresh key `k`.
    public mutating func mixKey(_ inputKeyMaterial: [UInt8]) {
        let output = Self.hkdf(chainingKey: chainingKey, inputKeyMaterial: inputKeyMaterial)
        chainingKey = Array(output[0..<32])
        cipherState = NoiseCipherStateCore<C>(key: Array(output[32..<64]))
    }

    /// Encrypts `plaintext` (AD = `h`) and mixes the ciphertext into `h`.
    public mutating func encryptAndHash(
        _ plaintext: [UInt8]
    ) throws(NoiseCryptoError) -> [UInt8] {
        let ciphertext = try cipherState.encryptWithAD(handshakeHash, plaintext: plaintext)
        mixHash(ciphertext)
        return ciphertext
    }

    /// Decrypts `ciphertext` (AD = `h`) and mixes the ciphertext into `h`.
    public mutating func decryptAndHash(
        _ ciphertext: [UInt8]
    ) throws(NoiseCryptoError) -> [UInt8] {
        let plaintext = try cipherState.decryptWithAD(handshakeHash, ciphertext: ciphertext)
        mixHash(ciphertext)
        return plaintext
    }

    /// Splits the symmetric state into two transport cipher states.
    ///
    /// Returns `(c1, c2)` derived as HKDF(ck, empty); the initiator uses `c1` to
    /// send and `c2` to receive, the responder swaps them.
    public func split() -> (c1: NoiseCipherStateCore<C>, c2: NoiseCipherStateCore<C>) {
        let output = Self.hkdf(chainingKey: chainingKey, inputKeyMaterial: [])
        let k1 = Array(output[0..<32])
        let k2 = Array(output[32..<64])
        return (NoiseCipherStateCore<C>(key: k1), NoiseCipherStateCore<C>(key: k2))
    }

    // MARK: - Noise HKDF (RFC 5869 extract-and-expand, two 32-byte outputs)

    /// HKDF-SHA256 producing 64 bytes of output keying material.
    ///
    /// `prk = HMAC(salt = ck, ikm)`; `out1 = HMAC(prk, 0x01)`;
    /// `out2 = HMAC(prk, out1 || 0x02)`. Returns `out1 || out2` (64 bytes). This
    /// is the Noise two-output HKDF and equals RFC 5869 Expand for `L = 64`.
    static func hkdf(chainingKey: [UInt8], inputKeyMaterial: [UInt8]) -> [UInt8] {
        let prk = C.HMACSHA256.authenticationCode(for: inputKeyMaterial.span, key: chainingKey.span)

        let out1 = C.HMACSHA256.authenticationCode(for: [0x01].span, key: prk.span)

        var input2 = out1
        input2.append(0x02)
        let out2 = C.HMACSHA256.authenticationCode(for: input2.span, key: prk.span)

        var result = out1
        result.append(contentsOf: out2)
        return result
    }
}
