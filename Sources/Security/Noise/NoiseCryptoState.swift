/// NoiseCryptoState - Cryptographic state management for the Noise protocol.
///
/// The Noise crypto state machine now lives in the Embedded-clean ``LibP2PCore``
/// (`NoiseCipherStateCore<C>` / `NoiseSymmetricStateCore<C>` /
/// `NoiseKeyAgreementCore<C>`), generic over the `CryptoProvider` seam. These
/// adapter types are thin `Data`/`SymmetricKey` bridges that specialise the core at
/// `C = NoiseFoundationProvider` and map ``LibP2PCore/NoiseCryptoError`` onto the
/// public ``NoiseError`` cases, so existing callers and tests are unchanged.
import Foundation
import Crypto
import P2PCore
import LibP2PCore
import P2PCoreBytes
import P2PCoreCrypto

typealias Provider = NoiseFoundationProvider
typealias CipherCore = NoiseCipherStateCore<Provider>
typealias SymmetricCore = NoiseSymmetricStateCore<Provider>
typealias KeyAgreementCore = NoiseKeyAgreementCore<Provider>

// MARK: - Core error mapping

/// Maps the Embedded-clean core error onto the adapter's public ``NoiseError``.
///
/// Fail-closed: a tag mismatch becomes ``NoiseError/decryptionFailed`` and an
/// invalid X25519 key becomes ``NoiseError/invalidKey`` — never a silent accept.
private func mapNoiseCryptoError(_ error: NoiseCryptoError) -> NoiseError {
    switch error {
    case .decryptionFailed:   return .decryptionFailed
    case .invalidPayload:     return .invalidPayload
    case .invalidSignature:   return .invalidSignature
    case .invalidKey:         return .invalidKey
    case .messageOutOfOrder:  return .messageOutOfOrder
    case .messageTooShort:    return .handshakeFailed("Noise message too short")
    case .nonceOverflow:      return .nonceOverflow
    case .cryptoFailure:      return .decryptionFailed
    }
}

// MARK: - CipherState

/// Manages encryption/decryption state for the Noise protocol.
///
/// Bridges `Data`/`SymmetricKey` onto ``LibP2PCore/NoiseCipherStateCore``. The
/// per-message nonce counter (never reused) lives in the core; this wrapper holds
/// no key bytes beyond what it forwards.
struct NoiseCipherState: Sendable {
    private var core: CipherCore

    /// Creates an empty CipherState with no key.
    init() {
        self.core = CipherCore()
    }

    /// Creates a CipherState with the given key.
    init(key: SymmetricKey) {
        self.core = CipherCore(key: key.withUnsafeBytes { [UInt8]($0) })
    }

    /// Returns true if a key has been set.
    func hasKey() -> Bool {
        core.hasKey()
    }

    /// Encrypts plaintext with associated data, returning `ciphertext || tag`.
    mutating func encryptWithAD<AD: DataProtocol, Plaintext: DataProtocol>(
        _ ad: AD,
        plaintext: Plaintext
    ) throws -> Data {
        do {
            return Data(try core.encryptWithAD([UInt8](ad), plaintext: [UInt8](plaintext)))
        } catch {
            throw mapNoiseCryptoError(error)
        }
    }

    /// Decrypts ciphertext (ciphertext + auth tag) with associated data.
    mutating func decryptWithAD<AD: DataProtocol, Ciphertext: RandomAccessCollection & DataProtocol>(
        _ ad: AD,
        ciphertext: Ciphertext
    ) throws -> Data where Ciphertext.Element == UInt8, Ciphertext.SubSequence: DataProtocol {
        do {
            return Data(try core.decryptWithAD([UInt8](ad), ciphertext: [UInt8](ciphertext)))
        } catch {
            throw mapNoiseCryptoError(error)
        }
    }
}

// MARK: - SymmetricState

/// Manages the symmetric cryptographic state during a Noise handshake.
///
/// Bridges `Data` onto ``LibP2PCore/NoiseSymmetricStateCore`` (chaining key `ck`,
/// handshake hash `h`, and the handshake cipher state). The handshake-hash binding
/// and the HKDF/`mixKey` chain are byte-identical to the pre-seam behaviour.
struct NoiseSymmetricState: Sendable {
    private var core: SymmetricCore

    /// Chaining key (32 bytes).
    var chainingKey: Data { Data(core.chainingKey) }

    /// Handshake hash (32 bytes).
    var handshakeHash: Data { Data(core.handshakeHash) }

    /// Cipher state for encryption/decryption.
    var cipherState: NoiseCipherState {
        NoiseCipherState(core: core.cipherState)
    }

    /// Initializes the SymmetricState with a protocol name.
    init(protocolName: String) {
        self.core = SymmetricCore(protocolName: [UInt8](protocolName.utf8))
    }

    /// Mixes data into the handshake hash: `h = SHA256(h || data)`.
    mutating func mixHash<DataBytes: DataProtocol>(_ data: DataBytes) {
        core.mixHash([UInt8](data))
    }

    /// Mixes key material into the chaining key and cipher key.
    mutating func mixKey(_ inputKeyMaterial: Data) {
        core.mixKey([UInt8](inputKeyMaterial))
    }

    /// Encrypts plaintext (AD = `h`) and mixes the ciphertext into `h`.
    mutating func encryptAndHash<Plaintext: DataProtocol>(_ plaintext: Plaintext) throws -> Data {
        do {
            return Data(try core.encryptAndHash([UInt8](plaintext)))
        } catch {
            throw mapNoiseCryptoError(error)
        }
    }

    /// Decrypts ciphertext (AD = `h`) and mixes the ciphertext into `h`.
    mutating func decryptAndHash<Ciphertext: RandomAccessCollection & DataProtocol>(
        _ ciphertext: Ciphertext
    ) throws -> Data where Ciphertext.Element == UInt8, Ciphertext.SubSequence: DataProtocol {
        do {
            return Data(try core.decryptAndHash([UInt8](ciphertext)))
        } catch {
            throw mapNoiseCryptoError(error)
        }
    }

    /// Splits the symmetric state into two transport cipher states `(c1, c2)`.
    func split() -> (c1: NoiseCipherState, c2: NoiseCipherState) {
        let (c1, c2) = core.split()
        return (NoiseCipherState(core: c1), NoiseCipherState(core: c2))
    }
}

// MARK: - Core bridging inits

extension NoiseCipherState {
    /// Wraps an existing core cipher state (used by `split()` and the handshake).
    init(core: CipherCore) {
        self.core = core
    }
}

// MARK: - Key Agreement Helper

/// Performs X25519 Diffie-Hellman key agreement via the crypto seam.
///
/// Delegates to ``LibP2PCore/NoiseKeyAgreementCore`` (specialised at
/// `C = NoiseFoundationProvider`), which preserves the two-layer small-order
/// defense byte-identically and surfaces ``NoiseError/invalidKey`` on a rejected
/// or zero-yielding peer key — never a silent fallback.
func noiseKeyAgreement(
    privateKey: Curve25519.KeyAgreement.PrivateKey,
    publicKey: Curve25519.KeyAgreement.PublicKey
) throws -> Data {
    let privRaw = [UInt8](privateKey.rawRepresentation)
    let pubRaw = [UInt8](publicKey.rawRepresentation)
    let priv: NoiseFoundationX25519.PrivateKey
    do {
        priv = try NoiseFoundationX25519.privateKey(rawRepresentation: privRaw.span)
    } catch {
        throw NoiseError.invalidKey
    }
    do {
        return Data(try KeyAgreementCore.sharedSecret(privateKey: priv, peerPublicKey: pubRaw))
    } catch {
        throw mapNoiseCryptoError(error)
    }
}

// MARK: - Small-Order Point Validation

/// Performs a fast static check that an X25519 public key is not one of the
/// canonical small-order points.
///
/// Defense-in-depth pre-check delegating to
/// ``LibP2PCore/NoiseKeyAgreementCore/isAcceptablePublicKey(_:)``. The
/// authoritative guard is the all-zero shared-secret rejection in
/// ``noiseKeyAgreement(privateKey:publicKey:)``.
func validateX25519PublicKey<PublicKeyBytes: DataProtocol>(_ publicKey: PublicKeyBytes) -> Bool {
    KeyAgreementCore.isAcceptablePublicKey([UInt8](publicKey))
}
