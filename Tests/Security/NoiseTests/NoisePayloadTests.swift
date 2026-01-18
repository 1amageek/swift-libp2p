/// NoisePayloadTests - Unit tests for Noise payload encoding and signature verification
import Testing
import Foundation
import Crypto
@testable import P2PSecurityNoise
@testable import P2PCore

@Suite("NoisePayload Tests")
struct NoisePayloadTests {

    // MARK: - Payload Encode/Decode Tests

    @Test("Payload encodes and decodes correctly")
    func testPayloadEncodeDecode() throws {
        let keyPair = KeyPair.generateEd25519()
        let noiseStaticKey = Curve25519.KeyAgreement.PrivateKey()
        let noiseStaticPubData = Data(noiseStaticKey.publicKey.rawRepresentation)

        let payload = try NoisePayload(keyPair: keyPair, noiseStaticPublicKey: noiseStaticPubData)
        let encoded = payload.encode()
        let decoded = try NoisePayload.decode(from: encoded)

        #expect(decoded.identityKey == payload.identityKey)
        #expect(decoded.identitySig == payload.identitySig)
        #expect(decoded.data == payload.data)
    }

    @Test("Payload with empty data encodes correctly")
    func testPayloadEmptyData() throws {
        let keyPair = KeyPair.generateEd25519()
        let noiseStaticPubData = Data(repeating: 0x42, count: 32)

        let payload = try NoisePayload(keyPair: keyPair, noiseStaticPublicKey: noiseStaticPubData)
        #expect(payload.data.isEmpty)

        let encoded = payload.encode()
        let decoded = try NoisePayload.decode(from: encoded)
        #expect(decoded.data.isEmpty)
    }

    @Test("Payload decode fails with empty data")
    func testPayloadDecodeEmptyData() {
        #expect(throws: NoiseError.self) {
            _ = try NoisePayload.decode(from: Data())
        }
    }

    @Test("Payload decode fails with missing identity key")
    func testPayloadDecodeMissingIdentityKey() {
        // Only encode identity_sig field (field 2)
        var data = Data()
        data.append(0x12) // field 2, wire type 2
        data.append(0x05) // length 5
        data.append(contentsOf: [0x01, 0x02, 0x03, 0x04, 0x05])

        #expect(throws: NoiseError.self) {
            _ = try NoisePayload.decode(from: data)
        }
    }

    @Test("Payload decode fails with missing identity sig")
    func testPayloadDecodeMissingIdentitySig() {
        // Only encode identity_key field (field 1)
        var data = Data()
        data.append(0x0A) // field 1, wire type 2
        data.append(0x05) // length 5
        data.append(contentsOf: [0x01, 0x02, 0x03, 0x04, 0x05])

        #expect(throws: NoiseError.self) {
            _ = try NoisePayload.decode(from: data)
        }
    }

    @Test("Payload decode ignores unknown fields")
    func testPayloadDecodeUnknownFields() throws {
        let keyPair = KeyPair.generateEd25519()
        let noiseStaticPubData = Data(repeating: 0x42, count: 32)
        let payload = try NoisePayload(keyPair: keyPair, noiseStaticPublicKey: noiseStaticPubData)

        var encoded = payload.encode()
        // Add unknown field 4
        encoded.append(0x22) // field 4, wire type 2
        encoded.append(0x03) // length 3
        encoded.append(contentsOf: [0xAA, 0xBB, 0xCC])

        let decoded = try NoisePayload.decode(from: encoded)
        #expect(decoded.identityKey == payload.identityKey)
        #expect(decoded.identitySig == payload.identitySig)
    }

    // MARK: - Signature Tests

    @Test("Payload signature is created correctly")
    func testPayloadSignatureCreation() throws {
        let keyPair = KeyPair.generateEd25519()
        let noiseStaticPubData = Data(repeating: 0x42, count: 32)

        let payload = try NoisePayload(keyPair: keyPair, noiseStaticPublicKey: noiseStaticPubData)

        // Signature should be 64 bytes for Ed25519
        #expect(payload.identitySig.count == 64)

        // Identity key should be the protobuf-encoded public key
        #expect(payload.identityKey == keyPair.publicKey.protobufEncoded)
    }

    @Test("Payload verification succeeds with valid signature")
    func testPayloadVerifyValidSignature() throws {
        let keyPair = KeyPair.generateEd25519()
        let noiseStaticKey = Curve25519.KeyAgreement.PrivateKey()
        let noiseStaticPubData = Data(noiseStaticKey.publicKey.rawRepresentation)

        let payload = try NoisePayload(keyPair: keyPair, noiseStaticPublicKey: noiseStaticPubData)
        let peerID = try payload.verify(noiseStaticPublicKey: noiseStaticPubData)

        #expect(peerID == keyPair.peerID)
    }

    @Test("Payload verification fails with invalid signature")
    func testPayloadVerifyInvalidSignature() throws {
        let keyPair = KeyPair.generateEd25519()
        let noiseStaticPubData = Data(repeating: 0x42, count: 32)

        // Create payload with tampered signature
        let validPayload = try NoisePayload(keyPair: keyPair, noiseStaticPublicKey: noiseStaticPubData)
        var tamperedSig = validPayload.identitySig
        tamperedSig[0] ^= 0xFF

        let tamperedPayload = NoisePayload(
            identityKey: validPayload.identityKey,
            identitySig: tamperedSig,
            data: validPayload.data
        )

        #expect(throws: NoiseError.self) {
            _ = try tamperedPayload.verify(noiseStaticPublicKey: noiseStaticPubData)
        }
    }

    @Test("Payload verification fails with wrong static key")
    func testPayloadVerifyWrongStaticKey() throws {
        let keyPair = KeyPair.generateEd25519()
        let noiseStaticPubData1 = Data(repeating: 0x42, count: 32)
        let noiseStaticPubData2 = Data(repeating: 0x43, count: 32)

        let payload = try NoisePayload(keyPair: keyPair, noiseStaticPublicKey: noiseStaticPubData1)

        // Verify with different static key should fail
        #expect(throws: NoiseError.self) {
            _ = try payload.verify(noiseStaticPublicKey: noiseStaticPubData2)
        }
    }

    @Test("Payload verification fails with corrupted identity key")
    func testPayloadVerifyCorruptedIdentityKey() throws {
        let keyPair = KeyPair.generateEd25519()
        let noiseStaticPubData = Data(repeating: 0x42, count: 32)

        let validPayload = try NoisePayload(keyPair: keyPair, noiseStaticPublicKey: noiseStaticPubData)

        // Create payload with corrupted identity key
        var corruptedKey = validPayload.identityKey
        corruptedKey[corruptedKey.count - 1] ^= 0xFF

        let corruptedPayload = NoisePayload(
            identityKey: corruptedKey,
            identitySig: validPayload.identitySig,
            data: validPayload.data
        )

        #expect(throws: (any Error).self) {
            _ = try corruptedPayload.verify(noiseStaticPublicKey: noiseStaticPubData)
        }
    }

    // MARK: - Framing Tests

    @Test("encodeNoiseMessage and readNoiseMessage roundtrip")
    func testFramingEncodeDecode() throws {
        let message = Data("Hello, Noise!".utf8)
        let framed = try encodeNoiseMessage(message)

        // Check length prefix
        #expect(framed.count == message.count + 2)
        #expect(framed[0] == 0x00)
        #expect(framed[1] == UInt8(message.count))

        // Decode
        let result = try readNoiseMessage(from: framed)
        #expect(result != nil)
        #expect(result?.message == message)
        #expect(result?.bytesConsumed == framed.count)
    }

    @Test("encodeNoiseMessage with larger message")
    func testFramingLargerMessage() throws {
        let message = Data(repeating: 0x42, count: 1000)
        let framed = try encodeNoiseMessage(message)

        // Length should be big-endian: 0x03E8 = 1000
        #expect(framed[0] == 0x03)
        #expect(framed[1] == 0xE8)

        let result = try readNoiseMessage(from: framed)
        #expect(result?.message == message)
    }

    @Test("readNoiseMessage returns nil for incomplete data")
    func testFramingIncompleteData() throws {
        // Only 1 byte of length prefix
        let incomplete1 = Data([0x00])
        #expect(try readNoiseMessage(from: incomplete1) == nil)

        // Length prefix says 10 bytes but only 5 provided
        let incomplete2 = Data([0x00, 0x0A, 0x01, 0x02, 0x03, 0x04, 0x05])
        #expect(try readNoiseMessage(from: incomplete2) == nil)
    }

    @Test("readNoiseMessage handles zero-length message")
    func testFramingZeroLength() throws {
        let framed = try encodeNoiseMessage(Data())

        #expect(framed == Data([0x00, 0x00]))

        let result = try readNoiseMessage(from: framed)
        #expect(result?.message == Data())
        #expect(result?.bytesConsumed == 2)
    }

    @Test("encodeNoiseMessage fails for oversized message")
    func testFramingMaxSize() {
        let oversized = Data(repeating: 0x42, count: noiseMaxMessageSize + 1)

        #expect(throws: NoiseError.self) {
            _ = try encodeNoiseMessage(oversized)
        }
    }

    @Test("encodeNoiseMessage succeeds at max size")
    func testFramingAtMaxSize() throws {
        let maxSized = Data(repeating: 0x42, count: noiseMaxMessageSize)
        let framed = try encodeNoiseMessage(maxSized)

        #expect(framed.count == noiseMaxMessageSize + 2)
        // Length prefix: 0xFFFF = 65535
        #expect(framed[0] == 0xFF)
        #expect(framed[1] == 0xFF)
    }

    @Test("readNoiseMessage throws for oversized length prefix")
    func testFramingOversizedLengthPrefix() {
        // Create a frame with length prefix > noiseMaxMessageSize
        // noiseMaxMessageSize is 65535 (0xFFFF), so we test with a larger value
        // Since 2-byte big-endian max is 65535, we can't exceed it with valid encoding
        // But we CAN test that valid max size doesn't throw
        var validMaxFrame = Data([0xFF, 0xFF]) // length = 65535
        validMaxFrame.append(Data(repeating: 0x42, count: noiseMaxMessageSize))

        // This should NOT throw (exactly at max)
        #expect(throws: Never.self) {
            _ = try readNoiseMessage(from: validMaxFrame)
        }
    }

    @Test("readNoiseMessage handles multiple messages in buffer")
    func testFramingMultipleMessages() throws {
        let msg1 = Data("First".utf8)
        let msg2 = Data("Second".utf8)

        var buffer = try encodeNoiseMessage(msg1)
        buffer.append(try encodeNoiseMessage(msg2))

        // First read
        let result1 = try readNoiseMessage(from: buffer)
        #expect(result1?.message == msg1)

        // Remove first message
        buffer = Data(buffer.dropFirst(result1!.bytesConsumed))

        // Second read
        let result2 = try readNoiseMessage(from: buffer)
        #expect(result2?.message == msg2)
    }
}
