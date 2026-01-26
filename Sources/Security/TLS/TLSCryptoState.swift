/// TLSCryptoState - Cryptographic state management for TLS
import Foundation
import Crypto

// MARK: - TLSCipherState

/// Manages AES-GCM encryption/decryption state for TLS.
///
/// Each cipher state maintains a symmetric key and a nonce counter.
/// The nonce is incremented after each encrypt/decrypt operation.
struct TLSCipherState: Sendable {
    /// The AES-256-GCM symmetric key (32 bytes).
    private let key: SymmetricKey

    /// The nonce counter, incremented after each operation.
    private var nonce: UInt64 = 0

    /// Creates a TLSCipherState with the given key.
    ///
    /// - Parameter key: The symmetric key (should be 32 bytes for AES-256)
    init(key: SymmetricKey) {
        self.key = key
    }

    /// Encrypts plaintext using AES-256-GCM.
    ///
    /// - Parameter plaintext: Data to encrypt
    /// - Returns: Ciphertext with 16-byte auth tag appended
    /// - Throws: `TLSError.nonceOverflow` if nonce counter exhausted,
    ///           `TLSError.encryptionFailed` if encryption fails
    mutating func encrypt(_ plaintext: Data) throws -> Data {
        guard nonce < UInt64.max else {
            throw TLSError.nonceOverflow
        }

        let gcmNonce = try makeNonce(nonce)

        do {
            let sealedBox = try AES.GCM.seal(
                plaintext,
                using: key,
                nonce: gcmNonce
            )

            nonce += 1

            // Return ciphertext + tag (combined)
            return sealedBox.ciphertext + sealedBox.tag
        } catch {
            throw TLSError.encryptionFailed
        }
    }

    /// Decrypts ciphertext using AES-256-GCM.
    ///
    /// - Parameter ciphertext: Data to decrypt (ciphertext + 16-byte auth tag)
    /// - Returns: Decrypted plaintext
    /// - Throws: `TLSError.nonceOverflow` if nonce counter exhausted,
    ///           `TLSError.decryptionFailed` if decryption or authentication fails
    mutating func decrypt(_ ciphertext: Data) throws -> Data {
        guard ciphertext.count >= tlsAuthTagSize else {
            throw TLSError.decryptionFailed
        }

        guard nonce < UInt64.max else {
            throw TLSError.nonceOverflow
        }

        let gcmNonce = try makeNonce(nonce)

        let ciphertextOnly = ciphertext.dropLast(tlsAuthTagSize)
        let tag = ciphertext.suffix(tlsAuthTagSize)

        do {
            let sealedBox = try AES.GCM.SealedBox(
                nonce: gcmNonce,
                ciphertext: ciphertextOnly,
                tag: tag
            )

            let plaintext = try AES.GCM.open(sealedBox, using: key)
            nonce += 1

            return plaintext
        } catch {
            throw TLSError.decryptionFailed
        }
    }

    /// Creates a 12-byte AES-GCM nonce from a counter.
    ///
    /// Format: 4 bytes zero padding + 8 bytes big-endian counter
    /// This matches TLS 1.3 nonce construction.
    private func makeNonce(_ n: UInt64) throws -> AES.GCM.Nonce {
        var data = Data(repeating: 0, count: 4)
        var counter = n.bigEndian
        data.append(contentsOf: withUnsafeBytes(of: &counter) { Array($0) })
        return try AES.GCM.Nonce(data: data)
    }
}
