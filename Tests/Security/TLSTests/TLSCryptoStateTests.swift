/// TLSCryptoStateTests - Tests for TLS cryptographic state
import Testing
import Foundation
import Crypto
@testable import P2PSecurityTLS

@Suite("TLSCryptoState Tests")
struct TLSCryptoStateTests {

    // MARK: - Encryption/Decryption Tests

    @Test("Encrypt and decrypt roundtrip")
    func encryptDecryptRoundtrip() throws {
        let key = SymmetricKey(size: .bits256)
        var encryptState = TLSCipherState(key: key)
        var decryptState = TLSCipherState(key: key)

        let plaintext = Data("Hello, TLS!".utf8)

        let ciphertext = try encryptState.encrypt(plaintext)
        let decrypted = try decryptState.decrypt(ciphertext)

        #expect(decrypted == plaintext)
    }

    @Test("Encrypt produces different output for same input")
    func encryptProducesDifferentOutput() throws {
        let key = SymmetricKey(size: .bits256)
        var state = TLSCipherState(key: key)

        let plaintext = Data("Same message".utf8)

        let ciphertext1 = try state.encrypt(plaintext)
        let ciphertext2 = try state.encrypt(plaintext)

        // Due to nonce increment, same plaintext produces different ciphertext
        #expect(ciphertext1 != ciphertext2)
    }

    @Test("Decrypt with mismatched nonce fails")
    func decryptMismatchedNonceFails() throws {
        let key = SymmetricKey(size: .bits256)
        var encryptState = TLSCipherState(key: key)
        var decryptState = TLSCipherState(key: key)

        let plaintext = Data("Test message".utf8)

        // Encrypt twice to advance nonce
        _ = try encryptState.encrypt(plaintext)
        let ciphertext2 = try encryptState.encrypt(plaintext)

        // Decrypt state still has nonce 0, but ciphertext was made with nonce 1
        #expect(throws: TLSError.self) {
            _ = try decryptState.decrypt(ciphertext2)
        }
    }

    @Test("Empty plaintext encryption")
    func emptyPlaintextEncryption() throws {
        let key = SymmetricKey(size: .bits256)
        var encryptState = TLSCipherState(key: key)
        var decryptState = TLSCipherState(key: key)

        let plaintext = Data()

        let ciphertext = try encryptState.encrypt(plaintext)
        let decrypted = try decryptState.decrypt(ciphertext)

        #expect(decrypted == plaintext)
        // Ciphertext should contain at least the auth tag
        #expect(ciphertext.count == tlsAuthTagSize)
    }

    @Test("Large data encryption")
    func largeDataEncryption() throws {
        let key = SymmetricKey(size: .bits256)
        var encryptState = TLSCipherState(key: key)
        var decryptState = TLSCipherState(key: key)

        // Create 1MB of random data
        let plaintext = Data((0..<1024*1024).map { _ in UInt8.random(in: 0...255) })

        let ciphertext = try encryptState.encrypt(plaintext)
        let decrypted = try decryptState.decrypt(ciphertext)

        #expect(decrypted == plaintext)
    }

    @Test("Ciphertext tampering detection")
    func ciphertextTamperingDetection() throws {
        let key = SymmetricKey(size: .bits256)
        var encryptState = TLSCipherState(key: key)
        var decryptState = TLSCipherState(key: key)

        let plaintext = Data("Sensitive data".utf8)
        var ciphertext = try encryptState.encrypt(plaintext)

        // Tamper with ciphertext
        if ciphertext.count > 5 {
            ciphertext[5] ^= 0xFF
        }

        #expect(throws: TLSError.self) {
            _ = try decryptState.decrypt(ciphertext)
        }
    }

    @Test("Ciphertext too short fails")
    func ciphertextTooShortFails() throws {
        let key = SymmetricKey(size: .bits256)
        var state = TLSCipherState(key: key)

        // Less than auth tag size
        let shortData = Data(repeating: 0, count: tlsAuthTagSize - 1)

        #expect(throws: TLSError.self) {
            _ = try state.decrypt(shortData)
        }
    }

    // MARK: - Constants Tests

    @Test("TLS constants have expected values")
    func tlsConstants() {
        #expect(tlsAuthTagSize == 16)
        #expect(tlsNonceSize == 12)
        #expect(tlsMaxMessageSize == 16640)
        #expect(tlsMaxPlaintextSize == tlsMaxMessageSize - tlsAuthTagSize)
    }
}

@Suite("TLSUtils Tests")
struct TLSUtilsTests {

    // MARK: - Frame Encoding Tests

    @Test("Encode and decode TLS message roundtrip")
    func encodeDecodeRoundtrip() throws {
        let message = Data("Test message".utf8)

        let encoded = try encodeTLSMessage(message)
        let (decoded, consumed) = try #require(try readTLSMessage(from: encoded))

        #expect(decoded == message)
        #expect(consumed == encoded.count)
    }

    @Test("Encode empty message")
    func encodeEmptyMessage() throws {
        let message = Data()

        let encoded = try encodeTLSMessage(message)

        #expect(encoded.count == 2)  // Just length prefix
        #expect(encoded[0] == 0)
        #expect(encoded[1] == 0)
    }

    @Test("Decode partial frame returns nil")
    func decodePartialFrameReturnsNil() throws {
        // Only 1 byte, need at least 2 for length
        let partial = Data([0x00])

        let result = try readTLSMessage(from: partial)

        #expect(result == nil)
    }

    @Test("Decode incomplete message returns nil")
    func decodeIncompleteMessageReturnsNil() throws {
        // Length says 10 bytes, but only 5 available
        let incomplete = Data([0x00, 0x0A, 0x01, 0x02, 0x03, 0x04, 0x05])

        let result = try readTLSMessage(from: incomplete)

        #expect(result == nil)
    }

    @Test("Encode oversized message throws")
    func encodeOversizedMessageThrows() {
        let oversized = Data(repeating: 0xFF, count: tlsMaxMessageSize + 1)

        #expect(throws: TLSError.self) {
            _ = try encodeTLSMessage(oversized)
        }
    }

    @Test("Decode oversized frame throws")
    func decodeOversizedFrameThrows() {
        // Encode a length greater than max
        let length = tlsMaxMessageSize + 1
        let frame = Data([UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF)])

        #expect(throws: TLSError.self) {
            _ = try readTLSMessage(from: frame)
        }
    }

    // MARK: - ASN.1 Parsing Tests

    @Test("Parse short form ASN.1 length")
    func parseShortFormLength() {
        let bytes: [UInt8] = [0x30, 0x10, 0x00]  // SEQUENCE, length 16

        let result = parseASN1Length(from: bytes, at: 1)

        #expect(result?.length == 16)
        #expect(result?.size == 1)
    }

    @Test("Parse long form ASN.1 length (1 byte)")
    func parseLongForm1ByteLength() {
        let bytes: [UInt8] = [0x30, 0x81, 0x80, 0x00]  // SEQUENCE, length 128

        let result = parseASN1Length(from: bytes, at: 1)

        #expect(result?.length == 128)
        #expect(result?.size == 2)
    }

    @Test("Parse long form ASN.1 length (2 bytes)")
    func parseLongForm2ByteLength() {
        let bytes: [UInt8] = [0x30, 0x82, 0x01, 0x00, 0x00]  // SEQUENCE, length 256

        let result = parseASN1Length(from: bytes, at: 1)

        #expect(result?.length == 256)
        #expect(result?.size == 3)
    }

    @Test("Parse ASN.1 length from Data")
    func parseASN1LengthFromData() {
        let data = Data([0x30, 0x10, 0x00])

        let result = parseASN1Length(from: data, at: 1)

        #expect(result?.length == 16)
        #expect(result?.size == 1)
    }

    @Test("Parse ASN.1 length at invalid offset returns nil")
    func parseASN1LengthInvalidOffset() {
        let bytes: [UInt8] = [0x30, 0x10]

        let result = parseASN1Length(from: bytes, at: 10)

        #expect(result == nil)
    }

    @Test("Parse ASN.1 length with insufficient bytes returns nil")
    func parseASN1LengthInsufficientBytes() {
        let bytes: [UInt8] = [0x30, 0x82, 0x01]  // Says 2 length bytes, only 1 available

        let result = parseASN1Length(from: bytes, at: 1)

        #expect(result == nil)
    }
}
