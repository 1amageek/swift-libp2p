/// PnetProtector - Pre-Shared Key protector for private networks
///
/// Implements the go-libp2p compatible pnet (private network) protocol.
/// All connections are wrapped with XSalsa20 encryption using a shared PSK,
/// ensuring only nodes with the same key can communicate.
///
/// Protocol:
/// 1. Both sides generate a 24-byte random nonce
/// 2. Both sides send their nonce to the other side
/// 3. Reader cipher: XSalsa20(psk, remote_nonce)
/// 4. Writer cipher: XSalsa20(psk, local_nonce)
/// 5. All subsequent data is encrypted/decrypted
import Foundation
import NIOCore
import P2PCore
import Crypto

// MARK: - PnetFingerprint

/// A fingerprint derived from a Pre-Shared Key for comparison.
///
/// The fingerprint is the SHA-256 hash of the PSK, used to identify
/// which private network a node belongs to without revealing the key.
public struct PnetFingerprint: Sendable, Hashable, CustomStringConvertible {
    /// The 32-byte SHA-256 hash of the PSK.
    public let bytes: [UInt8]

    /// Creates a fingerprint from a PSK.
    ///
    /// - Parameter psk: The 32-byte Pre-Shared Key.
    init(psk: [UInt8]) {
        var hasher = SHA256()
        hasher.update(data: psk)
        self.bytes = Array(hasher.finalize())
    }

    /// Creates a fingerprint from raw bytes (for testing or comparison).
    ///
    /// - Parameter bytes: The 32-byte fingerprint hash.
    init(bytes: [UInt8]) {
        precondition(bytes.count == 32, "Fingerprint must be 32 bytes")
        self.bytes = bytes
    }

    public var description: String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - PnetProtector.Configuration

/// Pre-Shared Key configuration for private networks.
public struct PnetConfiguration: Sendable {
    /// The 32-byte Pre-Shared Key.
    public let psk: [UInt8]

    /// Parse from go-libp2p compatible PSK file format.
    ///
    /// Expected format:
    /// ```
    /// /key/swarm/psk/1.0.0/
    /// /base16/
    /// <64 hex characters = 32 bytes PSK>
    /// ```
    ///
    /// - Parameter data: Raw file data containing the PSK.
    /// - Throws: `PnetError.invalidFileFormat` if the format is wrong.
    /// - Returns: A validated configuration.
    public static func fromFile(_ data: Data) throws -> PnetConfiguration {
        guard let content = String(data: data, encoding: .utf8) else {
            throw PnetError.invalidFileFormat("File is not valid UTF-8")
        }

        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard lines.count >= 3 else {
            throw PnetError.invalidFileFormat(
                "Expected at least 3 lines (header, encoding, key), got \(lines.count)"
            )
        }

        guard lines[0] == "/key/swarm/psk/1.0.0/" else {
            throw PnetError.invalidFileFormat(
                "Invalid header: expected '/key/swarm/psk/1.0.0/', got '\(lines[0])'"
            )
        }

        guard lines[1] == "/base16/" else {
            throw PnetError.invalidFileFormat(
                "Invalid encoding: expected '/base16/', got '\(lines[1])'"
            )
        }

        let hexString = lines[2]
        guard hexString.count == 64 else {
            throw PnetError.invalidFileFormat(
                "Invalid key length: expected 64 hex characters, got \(hexString.count)"
            )
        }

        let keyBytes = try hexToBytes(hexString)
        return try PnetConfiguration(psk: keyBytes)
    }

    /// Create from raw key bytes.
    ///
    /// - Parameter psk: The 32-byte Pre-Shared Key.
    /// - Throws: `PnetError.invalidKeyLength` if the key is not 32 bytes.
    public init(psk: [UInt8]) throws {
        guard psk.count == 32 else {
            throw PnetError.invalidKeyLength(expected: 32, got: psk.count)
        }
        self.psk = psk
    }

    /// Parse a hex string into bytes.
    ///
    /// - Parameter hex: Hex string (must have even length, only 0-9a-fA-F).
    /// - Throws: `PnetError.invalidFileFormat` if the string contains invalid characters.
    /// - Returns: The decoded byte array.
    private static func hexToBytes(_ hex: String) throws -> [UInt8] {
        let chars = Array(hex)
        guard chars.count % 2 == 0 else {
            throw PnetError.invalidFileFormat("Hex string has odd length")
        }

        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)

        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let high = hexValue(chars[i]),
                  let low = hexValue(chars[i + 1])
            else {
                throw PnetError.invalidFileFormat(
                    "Invalid hex character at position \(i)"
                )
            }
            bytes.append((high << 4) | low)
        }

        return bytes
    }

    /// Convert a single hex character to its numeric value.
    private static func hexValue(_ char: Character) -> UInt8? {
        switch char {
        case "0"..."9":
            return UInt8(char.asciiValue! - Character("0").asciiValue!)
        case "a"..."f":
            return UInt8(char.asciiValue! - Character("a").asciiValue! + 10)
        case "A"..."F":
            return UInt8(char.asciiValue! - Character("A").asciiValue! + 10)
        default:
            return nil
        }
    }
}

// MARK: - Nonce Size

/// The size of the nonce used in XSalsa20 (24 bytes).
private let pnetNonceSize = 24

// MARK: - PnetProtector

/// Pre-Shared Key protector for creating private libp2p networks.
///
/// Wraps raw connections with XSalsa20 stream encryption using a Pre-Shared Key.
/// Both peers must have the same PSK to communicate. The protector exchanges
/// random nonces during connection setup and derives separate cipher states
/// for reading and writing.
///
/// This is compatible with go-libp2p's pnet implementation.
public final class PnetProtector: Sendable {
    /// The PSK fingerprint for comparison with other nodes.
    public let fingerprint: PnetFingerprint

    /// The raw PSK bytes.
    private let psk: [UInt8]

    /// Creates a new PnetProtector with the given configuration.
    ///
    /// - Parameter configuration: The PSK configuration.
    public init(configuration: PnetConfiguration) {
        self.psk = configuration.psk
        self.fingerprint = PnetFingerprint(psk: configuration.psk)
    }

    /// Protect a raw connection with PSK encryption.
    ///
    /// Performs the pnet handshake:
    /// 1. Generate a random 24-byte nonce
    /// 2. Send the nonce to the remote peer
    /// 3. Read the remote peer's nonce
    /// 4. Create XSalsa20 ciphers: write with local nonce, read with remote nonce
    /// 5. Return a wrapped connection that encrypts/decrypts all data
    ///
    /// - Parameter connection: The raw connection to protect.
    /// - Returns: A new RawConnection that encrypts all traffic.
    /// - Throws: `PnetError` if the handshake fails.
    public func protect(_ connection: any RawConnection) async throws -> any RawConnection {
        // Step 1: Generate a random 24-byte nonce.
        // Drawn from a CSPRNG: SystemRandomNumberGenerator is documented to be
        // cryptographically secure on the platforms we target, so we fill all 24
        // bytes from 64-bit draws in a few calls rather than per-byte.
        let localNonce = Self.generateNonce()

        // Step 2: Send our nonce
        var localNonceBuffer = ByteBuffer()
        localNonceBuffer.writeBytes(localNonce)
        try await connection.write(localNonceBuffer)

        // Step 3: Read remote nonce.
        // TCP does not preserve message boundaries: a single read() may deliver
        // fewer than 24 bytes (split) or more (coalesced with subsequent
        // application data). Loop until exactly the nonce is accumulated, then
        // retain any surplus bytes for decrypted delivery to PnetConnection.
        var accumulated = ByteBuffer()
        while accumulated.readableBytes < pnetNonceSize {
            let chunk = try await connection.read()
            guard chunk.readableBytes > 0 else {
                throw PnetError.invalidNonceLength(
                    expected: pnetNonceSize,
                    got: accumulated.readableBytes
                )
            }
            var mutableChunk = chunk
            accumulated.writeBuffer(&mutableChunk)
        }

        guard let remoteNonce = accumulated.readBytes(length: pnetNonceSize) else {
            // Unreachable: the loop above guarantees at least pnetNonceSize bytes.
            throw PnetError.invalidNonceLength(
                expected: pnetNonceSize,
                got: accumulated.readableBytes
            )
        }

        // Step 4: Create cipher states
        // Writer cipher: XSalsa20(psk, local_nonce)
        // Reader cipher: XSalsa20(psk, remote_nonce)
        let sendCipher = try XSalsa20(key: psk, nonce: localNonce)
        var recvCipher = try XSalsa20(key: psk, nonce: remoteNonce)

        // Step 5: Surplus bytes after the nonce are the first application bytes.
        // Decrypt them now with recvCipher (the stream cipher must advance its
        // keystream in wire order) and hand the plaintext to PnetConnection as
        // an initial buffer so it is delivered before any further network read.
        var initialPlaintext = ByteBuffer()
        if accumulated.readableBytes > 0 {
            var surplus = accumulated
            recvCipher.process(&surplus)
            initialPlaintext = surplus
        }

        // Step 6: Return wrapped connection
        return PnetConnection(
            inner: connection,
            sendCipher: sendCipher,
            recvCipher: recvCipher,
            initialPlaintext: initialPlaintext
        )
    }

    /// Generates a 24-byte XSalsa20 nonce from a CSPRNG.
    ///
    /// Uses `SystemRandomNumberGenerator`, which is cryptographically secure on
    /// Apple platforms and Linux, drawing 64-bit words to fill the buffer in a
    /// few calls instead of one per byte.
    private static func generateNonce() -> [UInt8] {
        var rng = SystemRandomNumberGenerator()
        var nonce = [UInt8]()
        nonce.reserveCapacity(pnetNonceSize)
        while nonce.count < pnetNonceSize {
            let word = rng.next()  // UInt64 from a CSPRNG
            withUnsafeBytes(of: word) { raw in
                for byte in raw where nonce.count < pnetNonceSize {
                    nonce.append(byte)
                }
            }
        }
        return nonce
    }
}
