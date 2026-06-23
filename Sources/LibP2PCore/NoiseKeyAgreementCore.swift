/// Embedded-clean X25519 key agreement + small-order validation for Noise.
///
/// Embedded-clean: no Foundation, no Crypto, no `any`, typed throws. Routes DH
/// through `C.X25519` and preserves the two-layer small-order defense the adapter
/// shipped (byte-identical behaviour, fail-closed):
///
/// 1. The provider's `sharedSecret` rejects keys the backend refuses
///    (`CryptoError.keyAgreementFailure` → ``NoiseCryptoError/invalidKey``).
/// 2. The all-zero shared-secret check catches contributory points the backend
///    nevertheless accepts.
///
/// A static fast-reject blocklist of the canonical small-order points is also
/// provided as defense-in-depth; the authoritative guard is the zero-check.

import P2PCoreBytes
import P2PCoreCrypto

/// X25519 Diffie-Hellman + small-order point validation over `C`.
public enum NoiseKeyAgreementCore<C: CryptoProvider> {

    /// Performs X25519 DH between `privateKey` and the peer public key bytes.
    ///
    /// - Throws: ``NoiseCryptoError/invalidKey`` if the peer key is rejected by the
    ///   backend or yields an all-zero shared secret (a small-order point).
    public static func sharedSecret(
        privateKey: C.X25519.PrivateKey,
        peerPublicKey: [UInt8]
    ) throws(NoiseCryptoError) -> [UInt8] {
        let peer: C.X25519.PublicKey
        do {
            peer = try C.X25519.publicKey(rawRepresentation: peerPublicKey.span)
        } catch {
            throw .invalidKey
        }
        let secret: [UInt8]
        do {
            secret = try C.X25519.sharedSecret(privateKey: privateKey, peerPublicKey: peer)
        } catch {
            // Backend rejected the peer key (e.g. a small-order point). This is a
            // rejection, NOT a fallback — agreement does not proceed.
            throw .invalidKey
        }
        // Authoritative guard: reject points that produce an all-zero secret.
        var allZero = true
        for byte in secret where byte != 0 {
            allZero = false
            break
        }
        guard !allZero else {
            throw .invalidKey
        }
        return secret
    }

    /// Fast static check that a public key is not a canonical small-order point.
    ///
    /// This is a defense-in-depth pre-check, NOT the authoritative guard. A `true`
    /// result does NOT prove the key is safe — the all-zero shared-secret rejection
    /// in ``sharedSecret(privateKey:peerPublicKey:)`` is the authoritative
    /// guarantee and catches small-order points (canonical or not) this set omits.
    public static func isAcceptablePublicKey(_ publicKey: [UInt8]) -> Bool {
        for candidate in noiseX25519SmallOrderPoints where bytesEqual(publicKey, candidate) {
            return false
        }
        return true
    }

    private static func bytesEqual(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for index in 0..<lhs.count where lhs[index] != rhs[index] {
            return false
        }
        return true
    }
}

/// Canonical X25519 small-order points (little-endian, 32 bytes), the 7-element
/// libsodium `has_small_order` blocklist. Reference: libsodium `ed25519_ref10.c`;
/// https://cr.yp.to/ecdh.html#validate
///
/// Declared at file scope (not as a static member of the generic
/// ``NoiseKeyAgreementCore``) because Swift does not allow static stored
/// properties on generic types.
let noiseX25519SmallOrderPoints: [[UInt8]] = [
    // 0, order 1
    [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
     0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    // 1, order 1
    [1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
     0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    // order 8
    [0xe0, 0xeb, 0x7a, 0x7c, 0x3b, 0x41, 0xb8, 0xae, 0x16, 0x56, 0xe3, 0xfa, 0xf1, 0x9f, 0xc4, 0x6a,
     0xda, 0x09, 0x8d, 0xeb, 0x9c, 0x32, 0xb1, 0xfd, 0x86, 0x62, 0x05, 0x16, 0x5f, 0x49, 0xb8, 0x00],
    // order 8
    [0x5f, 0x9c, 0x95, 0xbc, 0xa3, 0x50, 0x8c, 0x24, 0xb1, 0xd0, 0xb1, 0x55, 0x9c, 0x83, 0xef, 0x5b,
     0x04, 0x44, 0x5c, 0xc4, 0x58, 0x1c, 0x8e, 0x86, 0xd8, 0x22, 0x4e, 0xdd, 0xd0, 0x9f, 0x11, 0x57],
    // p-1, order 2
    [0xec, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
     0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x7f],
    // p, order 4
    [0xed, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
     0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x7f],
    // p+1, order 1
    [0xee, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
     0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x7f],
]
