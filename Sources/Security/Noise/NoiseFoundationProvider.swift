/// Host (non-Embedded) `CryptoProvider` conformance for the Noise adapter.
///
/// `LibP2PCore`'s Noise crypto state machine (`NoiseCipherStateCore`,
/// `NoiseSymmetricStateCore`, `NoiseHandshakeCore`) is generic over
/// `C: CryptoProvider`; this adapter specialises it at `C = NoiseFoundationProvider`,
/// a swift-crypto / CryptoKit backend that is byte-identical to the crypto behavior
/// `P2PSecurityNoise` shipped before the seam refactor.
///
/// This provider is `P2PSecurityNoise`-internal (it lives in the adapter, never in
/// the Embedded core), backed by libp2p's own swift-crypto (NOT swift-p2p-crypto,
/// whose `.macOS(.v26)` floor is governed elsewhere), mirroring the TLS/QUIC
/// FoundationProviders. Only the Noise XX primitives are exercised
/// (ChaCha20-Poly1305 AEAD, SHA-256, HMAC-SHA256, X25519); the remaining
/// `CryptoProvider` associatedtypes are implemented faithfully so the provider is a
/// complete, well-typed conformance.
///
/// **No silent fallback**: an AEAD tag mismatch maps to
/// ``P2PCoreCrypto/CryptoError/authenticationFailure``; key-agreement failure to
/// ``P2PCoreCrypto/CryptoError/keyAgreementFailure``.

import Foundation
import Crypto
import P2PCoreBytes
import P2PCoreCrypto

#if canImport(CommonCrypto)
import CommonCrypto
#endif

// MARK: - Provider

/// Aggregates swift-crypto–backed primitives behind `P2PCoreCrypto.CryptoProvider`
/// for the Noise adapter.
public enum NoiseFoundationProvider: CryptoProvider {
    public typealias AESGCM128  = NoiseFoundationAEAD
    public typealias AESGCM256  = NoiseFoundationAEAD
    public typealias ChaChaPoly = NoiseFoundationAEAD

    public typealias SHA256 = NoiseFoundationSHA256
    public typealias SHA384 = NoiseFoundationSHA384

    public typealias HKDFSHA256 = NoiseFoundationHKDFSHA256
    public typealias HKDFSHA384 = NoiseFoundationHKDFSHA384

    public typealias HMACSHA1   = NoiseFoundationHMACSHA1
    public typealias HMACSHA256 = NoiseFoundationHMACSHA256
    public typealias HMACSHA384 = NoiseFoundationHMACSHA384

    public typealias X25519        = NoiseFoundationX25519
    public typealias P256Agreement = NoiseFoundationP256Agreement
    public typealias P384Agreement = NoiseFoundationP384Agreement

    public typealias Ed25519       = NoiseFoundationEd25519
    public typealias P256Signature = NoiseFoundationP256Signature
    public typealias P384Signature = NoiseFoundationP384Signature

    public typealias Random           = NoiseFoundationRandom
    public typealias Clock            = NoiseFoundationClock
    public typealias HeaderProtection = NoiseFoundationHeaderProtection

    public static func makeAESGCM128(key: Span<UInt8>) throws(P2PCoreCrypto.CryptoError) -> NoiseFoundationAEAD {
        try NoiseFoundationAEAD(algorithm: .aes128gcm, key: key)
    }
    public static func makeAESGCM256(key: Span<UInt8>) throws(P2PCoreCrypto.CryptoError) -> NoiseFoundationAEAD {
        try NoiseFoundationAEAD(algorithm: .aes256gcm, key: key)
    }
    public static func makeChaChaPoly(key: Span<UInt8>) throws(P2PCoreCrypto.CryptoError) -> NoiseFoundationAEAD {
        try NoiseFoundationAEAD(algorithm: .chacha20poly1305, key: key)
    }

    public static let random = NoiseFoundationRandom()
    public static let clock  = NoiseFoundationClock()
}

// MARK: - Span <-> bytes helpers (host-only)

extension Span where Element == UInt8 {
    @inline(__always)
    func providerArray() -> [UInt8] {
        var array = [UInt8]()
        array.reserveCapacity(count)
        for index in 0..<count { array.append(self[index]) }
        return array
    }

    @inline(__always)
    func providerData() -> Data { Data(providerArray()) }
}

// MARK: - AEAD

/// One keyed AEAD over swift-crypto. `seal` returns `ciphertext || tag`; `open`
/// rethrows `CryptoKitError.authenticationFailure` as `.authenticationFailure`
/// (no silent fallback).
public struct NoiseFoundationAEAD: P2PCoreCrypto.AEAD {
    public static let nonceLength = 12
    public static let tagLength   = 16

    public enum Algorithm: Sendable {
        case aes128gcm, aes256gcm, chacha20poly1305
        var keyLength: Int {
            switch self {
            case .aes128gcm:        return 16
            case .aes256gcm:        return 32
            case .chacha20poly1305: return 32
            }
        }
    }

    private let algorithm: Algorithm
    private let key: SymmetricKey

    public init(algorithm: Algorithm, key: Span<UInt8>) throws(P2PCoreCrypto.CryptoError) {
        guard key.count == algorithm.keyLength else {
            throw .invalidLength(expected: algorithm.keyLength, actual: key.count)
        }
        self.algorithm = algorithm
        self.key = SymmetricKey(data: key.providerData())
    }

    public func seal(
        _ plaintext: Span<UInt8>, nonce: Span<UInt8>, aad: Span<UInt8>
    ) throws(P2PCoreCrypto.CryptoError) -> [UInt8] {
        guard nonce.count == Self.nonceLength else {
            throw .invalidLength(expected: Self.nonceLength, actual: nonce.count)
        }
        let pt = plaintext.providerData()
        let nonceData = nonce.providerData()
        let aadData = aad.providerData()
        switch algorithm {
        case .aes128gcm, .aes256gcm:
            do {
                let n = try AES.GCM.Nonce(data: nonceData)
                let box = try AES.GCM.seal(pt, using: key, nonce: n, authenticating: aadData)
                return [UInt8](box.ciphertext) + [UInt8](box.tag)
            } catch { throw .providerFailure }
        case .chacha20poly1305:
            do {
                let n = try Crypto.ChaChaPoly.Nonce(data: nonceData)
                let box = try Crypto.ChaChaPoly.seal(pt, using: key, nonce: n, authenticating: aadData)
                return [UInt8](box.ciphertext) + [UInt8](box.tag)
            } catch { throw .providerFailure }
        }
    }

    public func open(
        _ ciphertext: Span<UInt8>, nonce: Span<UInt8>, aad: Span<UInt8>
    ) throws(P2PCoreCrypto.CryptoError) -> [UInt8] {
        guard nonce.count == Self.nonceLength else {
            throw .invalidLength(expected: Self.nonceLength, actual: nonce.count)
        }
        guard ciphertext.count >= Self.tagLength else {
            throw .invalidLength(expected: Self.tagLength, actual: ciphertext.count)
        }
        let combined = ciphertext.providerArray()
        let splitIndex = combined.count - Self.tagLength
        let ctData = Data(combined[0..<splitIndex])
        let tagData = Data(combined[splitIndex..<combined.count])
        let nonceData = nonce.providerData()
        let aadData = aad.providerData()
        switch algorithm {
        case .aes128gcm, .aes256gcm:
            do {
                let n = try AES.GCM.Nonce(data: nonceData)
                let box = try AES.GCM.SealedBox(nonce: n, ciphertext: ctData, tag: tagData)
                return [UInt8](try AES.GCM.open(box, using: key, authenticating: aadData))
            } catch let error as CryptoKitError {
                throw Self.mapOpenError(error)
            } catch { throw .providerFailure }
        case .chacha20poly1305:
            do {
                let n = try Crypto.ChaChaPoly.Nonce(data: nonceData)
                let box = try Crypto.ChaChaPoly.SealedBox(nonce: n, ciphertext: ctData, tag: tagData)
                return [UInt8](try Crypto.ChaChaPoly.open(box, using: key, authenticating: aadData))
            } catch let error as CryptoKitError {
                throw Self.mapOpenError(error)
            } catch { throw .providerFailure }
        }
    }

    private static func mapOpenError(_ error: CryptoKitError) -> P2PCoreCrypto.CryptoError {
        switch error {
        case .authenticationFailure: return .authenticationFailure
        default:                     return .providerFailure
        }
    }
}

// MARK: - Hashes

public struct NoiseFoundationSHA256: P2PCoreCrypto.HashFunction {
    public static let digestLength = 32
    public static let blockLength  = 64
    private var hasher = Crypto.SHA256()
    public init() {}
    public mutating func update(_ data: Span<UInt8>) { hasher.update(data: data.providerData()) }
    public consuming func finalize() -> [UInt8] { [UInt8](hasher.finalize()) }
}

public struct NoiseFoundationSHA384: P2PCoreCrypto.HashFunction {
    public static let digestLength = 48
    public static let blockLength  = 128
    private var hasher = Crypto.SHA384()
    public init() {}
    public mutating func update(_ data: Span<UInt8>) { hasher.update(data: data.providerData()) }
    public consuming func finalize() -> [UInt8] { [UInt8](hasher.finalize()) }
}

// MARK: - HKDF

public struct NoiseFoundationHKDFSHA256: P2PCoreCrypto.KeyDerivation {
    public typealias Hash = NoiseFoundationSHA256
    public init() {}
    public func extract(salt: Span<UInt8>, ikm: Span<UInt8>) -> [UInt8] {
        let prk = Crypto.HKDF<Crypto.SHA256>.extract(
            inputKeyMaterial: SymmetricKey(data: ikm.providerData()), salt: salt.providerData())
        return prk.withUnsafeBytes { [UInt8]($0) }
    }
    public func expand(prk: Span<UInt8>, info: Span<UInt8>, length: Int) throws(P2PCoreCrypto.CryptoError) -> [UInt8] {
        guard length <= 255 * Hash.digestLength else {
            throw .invalidLength(expected: 255 * Hash.digestLength, actual: length)
        }
        let okm = Crypto.HKDF<Crypto.SHA256>.expand(
            pseudoRandomKey: SymmetricKey(data: prk.providerData()),
            info: info.providerData(), outputByteCount: length)
        return okm.withUnsafeBytes { [UInt8]($0) }
    }
}

public struct NoiseFoundationHKDFSHA384: P2PCoreCrypto.KeyDerivation {
    public typealias Hash = NoiseFoundationSHA384
    public init() {}
    public func extract(salt: Span<UInt8>, ikm: Span<UInt8>) -> [UInt8] {
        let prk = Crypto.HKDF<Crypto.SHA384>.extract(
            inputKeyMaterial: SymmetricKey(data: ikm.providerData()), salt: salt.providerData())
        return prk.withUnsafeBytes { [UInt8]($0) }
    }
    public func expand(prk: Span<UInt8>, info: Span<UInt8>, length: Int) throws(P2PCoreCrypto.CryptoError) -> [UInt8] {
        guard length <= 255 * Hash.digestLength else {
            throw .invalidLength(expected: 255 * Hash.digestLength, actual: length)
        }
        let okm = Crypto.HKDF<Crypto.SHA384>.expand(
            pseudoRandomKey: SymmetricKey(data: prk.providerData()),
            info: info.providerData(), outputByteCount: length)
        return okm.withUnsafeBytes { [UInt8]($0) }
    }
}

// MARK: - HMAC

public struct NoiseFoundationHMACSHA256: P2PCoreCrypto.MessageAuthenticationCode {
    public static let macLength = 32
    private var mac: Crypto.HMAC<Crypto.SHA256>
    public init(key: Span<UInt8>) { mac = Crypto.HMAC<Crypto.SHA256>(key: SymmetricKey(data: key.providerData())) }
    public mutating func update(_ data: Span<UInt8>) { mac.update(data: data.providerData()) }
    public consuming func finalize() -> [UInt8] { [UInt8](mac.finalize()) }
    public static func authenticationCode(for message: Span<UInt8>, key: Span<UInt8>) -> [UInt8] {
        [UInt8](Crypto.HMAC<Crypto.SHA256>.authenticationCode(
            for: message.providerData(), using: SymmetricKey(data: key.providerData())))
    }
    public static func isValid(_ mac: Span<UInt8>, for message: Span<UInt8>, key: Span<UInt8>) -> Bool {
        Crypto.HMAC<Crypto.SHA256>.isValidAuthenticationCode(
            mac.providerData(), authenticating: message.providerData(),
            using: SymmetricKey(data: key.providerData()))
    }
}

public struct NoiseFoundationHMACSHA384: P2PCoreCrypto.MessageAuthenticationCode {
    public static let macLength = 48
    private var mac: Crypto.HMAC<Crypto.SHA384>
    public init(key: Span<UInt8>) { mac = Crypto.HMAC<Crypto.SHA384>(key: SymmetricKey(data: key.providerData())) }
    public mutating func update(_ data: Span<UInt8>) { mac.update(data: data.providerData()) }
    public consuming func finalize() -> [UInt8] { [UInt8](mac.finalize()) }
    public static func authenticationCode(for message: Span<UInt8>, key: Span<UInt8>) -> [UInt8] {
        [UInt8](Crypto.HMAC<Crypto.SHA384>.authenticationCode(
            for: message.providerData(), using: SymmetricKey(data: key.providerData())))
    }
    public static func isValid(_ mac: Span<UInt8>, for message: Span<UInt8>, key: Span<UInt8>) -> Bool {
        Crypto.HMAC<Crypto.SHA384>.isValidAuthenticationCode(
            mac.providerData(), authenticating: message.providerData(),
            using: SymmetricKey(data: key.providerData()))
    }
}

public struct NoiseFoundationHMACSHA1: P2PCoreCrypto.MessageAuthenticationCode {
    public static let macLength = 20
    private var mac: Crypto.HMAC<Crypto.Insecure.SHA1>
    public init(key: Span<UInt8>) { mac = Crypto.HMAC<Crypto.Insecure.SHA1>(key: SymmetricKey(data: key.providerData())) }
    public mutating func update(_ data: Span<UInt8>) { mac.update(data: data.providerData()) }
    public consuming func finalize() -> [UInt8] { [UInt8](mac.finalize()) }
    public static func authenticationCode(for message: Span<UInt8>, key: Span<UInt8>) -> [UInt8] {
        [UInt8](Crypto.HMAC<Crypto.Insecure.SHA1>.authenticationCode(
            for: message.providerData(), using: SymmetricKey(data: key.providerData())))
    }
    public static func isValid(_ mac: Span<UInt8>, for message: Span<UInt8>, key: Span<UInt8>) -> Bool {
        Crypto.HMAC<Crypto.Insecure.SHA1>.isValidAuthenticationCode(
            mac.providerData(), authenticating: message.providerData(),
            using: SymmetricKey(data: key.providerData()))
    }
}

// MARK: - Random / Clock

public struct NoiseFoundationRandom: P2PCoreCrypto.RandomSource {
    public init() {}
    public func randomBytes(_ count: Int) -> [UInt8] {
        var rng = SystemRandomNumberGenerator()
        var out = [UInt8](repeating: 0, count: count)
        for i in 0..<count { out[i] = UInt8.random(in: .min ... .max, using: &rng) }
        return out
    }
    public func fill(_ buffer: inout [UInt8]) {
        var rng = SystemRandomNumberGenerator()
        for i in 0..<buffer.count { buffer[i] = UInt8.random(in: .min ... .max, using: &rng) }
    }
}

public struct NoiseFoundationClock: P2PCoreCrypto.MonotonicClock {
    public init() {}
    public func monotonicMillis() -> UInt64 { monotonicNanos() / 1_000_000 }
    public func monotonicNanos() -> UInt64 { UInt64(DispatchTime.now().uptimeNanoseconds) }
}

// MARK: - Header protection (unused by Noise; faithful AES-ECB / ChaCha20 mask)

public enum NoiseFoundationHeaderProtection: P2PCoreCrypto.HeaderProtectionProvider {
    public static func aesECBBlockMask(key: Span<UInt8>, sample: Span<UInt8>) throws(P2PCoreCrypto.CryptoError) -> [UInt8] {
        guard key.count == 16 || key.count == 32 else {
            throw .invalidLength(expected: 16, actual: key.count)
        }
        guard sample.count >= 16 else {
            throw .invalidLength(expected: 16, actual: sample.count)
        }
        #if canImport(CommonCrypto)
        let keyBytes = key.providerArray()
        let sampleBytes = Array(sample.providerArray()[0..<16])
        var out = [UInt8](repeating: 0, count: 16)
        var moved = 0
        let status = keyBytes.withUnsafeBytes { kp in
            sampleBytes.withUnsafeBytes { ip in
                out.withUnsafeMutableBytes { op in
                    CCCrypt(
                        CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode),
                        kp.baseAddress, keyBytes.count, nil,
                        ip.baseAddress, 16, op.baseAddress, 16, &moved)
                }
            }
        }
        guard status == kCCSuccess, moved == 16 else { throw .providerFailure }
        return Array(out[0..<5])
        #else
        throw .unsupportedParameter
        #endif
    }

    public static func chaCha20BlockMask(key: Span<UInt8>, sample: Span<UInt8>) throws(P2PCoreCrypto.CryptoError) -> [UInt8] {
        // Not used by Noise; QUIC owns header protection. Surface unsupported
        // rather than risk an unverified keystream path here.
        throw .unsupportedParameter
    }
}
