/// Noise `CipherState` over the crypto seam (Embedded-clean, generic `<C>`).
///
/// Embedded-clean: no Foundation, no Crypto, no `any`, typed throws. The AEAD is
/// `C.ChaChaPoly` (built per derived key via `C.makeChaChaPoly`); the nonce is the
/// 96-bit Noise nonce (4 zero bytes + 8-byte little-endian counter). The `Data` /
/// `SymmetricKey` surface stays in the `P2PSecurityNoise` adapter, which bridges
/// `Data` ↔ `[UInt8]` and specialises at `C = NoiseFoundationProvider`.
///
/// Security invariants preserved byte-identically:
/// - The per-message nonce counter never repeats (incremented after each op).
/// - A tag mismatch surfaces as ``NoiseCryptoError/decryptionFailed`` — never a
///   silent empty/garbage return (no silent fallback).
/// - With no key set, `encrypt`/`decrypt` return the input unchanged (Noise spec).

import P2PCoreBytes
import P2PCoreCrypto

/// Manages encryption/decryption state for the Noise protocol over `C`.
///
/// The `CipherState` holds a symmetric key (32 bytes) and a 64-bit nonce counter.
/// The nonce is incremented after each encryption or decryption operation.
public struct NoiseCipherStateCore<C: CryptoProvider>: Sendable {

    /// The symmetric key (32 bytes), empty until initialized via `mixKey`.
    private let key: [UInt8]?

    /// The nonce counter, incremented after each operation.
    private var nonce: UInt64

    /// Creates an empty `CipherState` with no key.
    public init() {
        self.key = nil
        self.nonce = 0
    }

    /// Creates a `CipherState` with the given 32-byte key.
    public init(key: [UInt8]) {
        self.key = key
        self.nonce = 0
    }

    /// Returns true if a key has been set.
    public func hasKey() -> Bool {
        key != nil
    }

    /// Encrypts `plaintext` authenticating `ad`, returning `ciphertext || tag`.
    ///
    /// With no key set the plaintext is returned unchanged (Noise spec).
    ///
    /// - Throws: ``NoiseCryptoError/nonceOverflow`` if the counter is exhausted,
    ///   ``NoiseCryptoError/cryptoFailure`` if the AEAD backend fails.
    public mutating func encryptWithAD(
        _ ad: [UInt8],
        plaintext: [UInt8]
    ) throws(NoiseCryptoError) -> [UInt8] {
        guard let key else {
            return plaintext
        }
        guard nonce < UInt64.max else {
            throw .nonceOverflow
        }
        let nonceBytes = Self.makeNonce(nonce)
        let aead: C.ChaChaPoly
        do {
            aead = try C.makeChaChaPoly(key: key.span)
        } catch {
            throw .cryptoFailure
        }
        let sealed: [UInt8]
        do {
            sealed = try aead.seal(plaintext.span, nonce: nonceBytes.span, aad: ad.span)
        } catch {
            throw .cryptoFailure
        }
        nonce &+= 1
        return sealed
    }

    /// Decrypts `ciphertext` (`ciphertext || tag`) authenticating `ad`.
    ///
    /// With no key set the ciphertext is returned unchanged (Noise spec).
    ///
    /// - Throws: ``NoiseCryptoError/decryptionFailed`` on a tag mismatch or a
    ///   too-short input (fail-closed), ``NoiseCryptoError/nonceOverflow`` if the
    ///   counter is exhausted, ``NoiseCryptoError/cryptoFailure`` on backend error.
    public mutating func decryptWithAD(
        _ ad: [UInt8],
        ciphertext: [UInt8]
    ) throws(NoiseCryptoError) -> [UInt8] {
        guard let key else {
            return ciphertext
        }
        guard ciphertext.count >= C.ChaChaPoly.tagLength else {
            throw .decryptionFailed
        }
        guard nonce < UInt64.max else {
            throw .nonceOverflow
        }
        let nonceBytes = Self.makeNonce(nonce)
        let aead: C.ChaChaPoly
        do {
            aead = try C.makeChaChaPoly(key: key.span)
        } catch {
            throw .cryptoFailure
        }
        let plaintext: [UInt8]
        do {
            plaintext = try aead.open(ciphertext.span, nonce: nonceBytes.span, aad: ad.span)
        } catch let error {
            switch error {
            case .authenticationFailure, .invalidLength:
                throw .decryptionFailed
            default:
                throw .cryptoFailure
            }
        }
        nonce &+= 1
        return plaintext
    }

    /// Builds a 12-byte Noise nonce from a counter: 4 zero bytes + 8-byte
    /// little-endian counter.
    static func makeNonce(_ counter: UInt64) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 12)
        var value = counter
        var index = 4
        while index < 12 {
            out[index] = UInt8(truncatingIfNeeded: value)
            value >>= 8
            index += 1
        }
        return out
    }
}
