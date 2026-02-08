/// IPNSValidatorTests - Tests for IPNS record creation, encoding, validation, and selection.

import Testing
import Foundation
@testable import P2PKademlia
@testable import P2PCore

@Suite("IPNS Validator Tests")
struct IPNSValidatorTests {

    // MARK: - Helpers

    /// Creates a test key pair and PeerID for use across tests.
    private func makeTestIdentity() -> (keyPair: KeyPair, peerID: PeerID) {
        let keyPair = KeyPair.generateEd25519()
        let peerID = PeerID(publicKey: keyPair.publicKey)
        return (keyPair, peerID)
    }

    /// Builds a DHT key in the format /ipns/<peerID>.
    private func makeIPNSKey(for peerID: PeerID) -> [UInt8] {
        let keyString = IPNSValidator.namespace + peerID.description
        return Array(keyString.utf8)
    }

    // MARK: - IPNSRecord: Create and Encode/Decode Roundtrip

    @Test("IPNSRecord create and encode/decode roundtrip")
    func recordRoundtrip() throws {
        let (keyPair, _) = makeTestIdentity()
        let value = Array("/ipfs/QmTestHash1234567890".utf8)
        let validity = Date().addingTimeInterval(3600) // 1 hour from now
        let sequence: UInt64 = 42

        let record = try IPNSRecord.create(
            value: value,
            sequence: sequence,
            validity: validity,
            keyPair: keyPair
        )

        // Encode
        let encoded = record.encode()
        #expect(!encoded.isEmpty)

        // Decode
        let decoded = try IPNSRecord.decode(from: encoded)

        #expect(decoded.value == value)
        #expect(decoded.sequence == sequence)
        #expect(decoded.validityType == .eol)
        #expect(!decoded.signature.isEmpty)
        #expect(decoded.publicKey != nil)

        // Validity should be approximately equal (within 1 second tolerance due to formatting)
        let timeDiff = abs(decoded.validity.timeIntervalSince(validity))
        #expect(timeDiff < 1.0)
    }

    // MARK: - IPNSRecord: Create with Signature

    @Test("IPNSRecord create with valid signature")
    func recordCreateWithSignature() throws {
        let (keyPair, _) = makeTestIdentity()
        let value = Array("/ipfs/QmSomeContent".utf8)
        let validity = Date().addingTimeInterval(7200)

        let record = try IPNSRecord.create(
            value: value,
            sequence: 1,
            validity: validity,
            keyPair: keyPair
        )

        // Signature should be non-empty
        #expect(!record.signature.isEmpty)

        // Public key should be the protobuf-encoded key
        let expectedPK = Array(keyPair.publicKey.protobufEncoded)
        #expect(record.publicKey == expectedPK)

        // Verify signature manually
        let signable = IPNSRecord.dataForSigning(
            value: value,
            validityType: .eol,
            validity: validity
        )
        let isValid = try keyPair.publicKey.verify(
            signature: Data(record.signature),
            for: signable
        )
        #expect(isValid)
    }

    // MARK: - IPNSRecord: Decode Invalid Data

    @Test("IPNSRecord decode invalid data throws")
    func decodeInvalidData() throws {
        // Empty data
        #expect(throws: (any Error).self) {
            _ = try IPNSRecord.decode(from: [])
        }

        // Random garbage
        #expect(throws: (any Error).self) {
            _ = try IPNSRecord.decode(from: [0xFF, 0xFE, 0xFD, 0xFC])
        }

        // Valid protobuf structure but missing required fields
        // Only field 1 (value), missing validityType, validity, sequence, signature
        let partialData: [UInt8] = [
            0x0A, 0x04, 0x74, 0x65, 0x73, 0x74  // field 1, "test"
        ]
        #expect(throws: IPNSRecordError.self) {
            _ = try IPNSRecord.decode(from: partialData)
        }
    }

    // MARK: - IPNSValidator: Handles /ipns/ Prefix

    @Test("IPNSValidator handles /ipns/ prefix")
    func validatorHandlesIPNSPrefix() {
        let validator = IPNSValidator()

        let (_, peerID) = makeTestIdentity()
        let key = makeIPNSKey(for: peerID)

        #expect(validator.handles(key: key))
    }

    // MARK: - IPNSValidator: Does NOT Handle Other Prefixes

    @Test("IPNSValidator does NOT handle other prefixes")
    func validatorDoesNotHandleOtherPrefixes() {
        let validator = IPNSValidator()

        // /pk/ prefix
        let pkKey = Array("/pk/QmSomePeerID".utf8)
        #expect(!validator.handles(key: pkKey))

        // No prefix
        let rawKey = Array("rawkey12345".utf8)
        #expect(!validator.handles(key: rawKey))

        // Similar but not exact
        let ipnsLike = Array("/ipn/something".utf8)
        #expect(!validator.handles(key: ipnsLike))

        // Empty
        #expect(!validator.handles(key: []))

        // Non-UTF8
        #expect(!validator.handles(key: [0xFF, 0xFE]))
    }

    // MARK: - IPNSValidator: Validate Valid Record

    @Test("IPNSValidator validate valid record")
    func validateValidRecord() throws {
        let validator = IPNSValidator()
        let (keyPair, peerID) = makeTestIdentity()
        let key = makeIPNSKey(for: peerID)
        let value = Array("/ipfs/QmValid".utf8)
        let validity = Date().addingTimeInterval(3600)

        let record = try IPNSRecord.create(
            value: value,
            sequence: 1,
            validity: validity,
            keyPair: keyPair
        )
        let encoded = record.encode()

        let isValid = try validator.validate(key: key, value: encoded)
        #expect(isValid)
    }

    // MARK: - IPNSValidator: Reject Expired Record

    @Test("IPNSValidator reject expired record")
    func rejectExpiredRecord() throws {
        let validator = IPNSValidator()
        let (keyPair, peerID) = makeTestIdentity()
        let key = makeIPNSKey(for: peerID)
        let value = Array("/ipfs/QmExpired".utf8)
        // Already expired
        let validity = Date().addingTimeInterval(-3600)

        let record = try IPNSRecord.create(
            value: value,
            sequence: 1,
            validity: validity,
            keyPair: keyPair
        )
        let encoded = record.encode()

        #expect(throws: IPNSRecordError.expired) {
            _ = try validator.validate(key: key, value: encoded)
        }
    }

    // MARK: - IPNSValidator: Reject Invalid Signature

    @Test("IPNSValidator reject invalid signature")
    func rejectInvalidSignature() throws {
        let validator = IPNSValidator()
        let (keyPair, peerID) = makeTestIdentity()
        let key = makeIPNSKey(for: peerID)
        let value = Array("/ipfs/QmTampered".utf8)
        let validity = Date().addingTimeInterval(3600)

        // Create a valid record
        let record = try IPNSRecord.create(
            value: value,
            sequence: 1,
            validity: validity,
            keyPair: keyPair
        )

        // Tamper with the signature
        var tamperedSignature = record.signature
        if !tamperedSignature.isEmpty {
            tamperedSignature[0] ^= 0xFF
        }

        let tamperedRecord = IPNSRecord(
            value: record.value,
            sequence: record.sequence,
            validity: record.validity,
            validityType: record.validityType,
            signature: tamperedSignature,
            publicKey: record.publicKey
        )
        let encoded = tamperedRecord.encode()

        #expect(throws: IPNSRecordError.invalidSignature) {
            _ = try validator.validate(key: key, value: encoded)
        }
    }

    // MARK: - IPNSValidator: Select by Sequence Number

    @Test("IPNSValidator select by sequence number (higher wins)")
    func selectBySequenceNumber() throws {
        let validator = IPNSValidator()
        let (keyPair, peerID) = makeTestIdentity()
        let key = makeIPNSKey(for: peerID)
        let validity = Date().addingTimeInterval(3600)

        let record1 = try IPNSRecord.create(
            value: Array("/ipfs/QmOld".utf8),
            sequence: 1,
            validity: validity,
            keyPair: keyPair
        )
        let record2 = try IPNSRecord.create(
            value: Array("/ipfs/QmNew".utf8),
            sequence: 5,
            validity: validity,
            keyPair: keyPair
        )
        let record3 = try IPNSRecord.create(
            value: Array("/ipfs/QmMiddle".utf8),
            sequence: 3,
            validity: validity,
            keyPair: keyPair
        )

        let records = [record1.encode(), record2.encode(), record3.encode()]
        let bestIndex = try validator.select(key: key, records: records)

        // Record at index 1 has sequence 5 (highest)
        #expect(bestIndex == 1)
    }

    // MARK: - IPNSValidator: Select by Validity Date

    @Test("IPNSValidator select by validity date (later wins when seq equal)")
    func selectByValidityDate() throws {
        let validator = IPNSValidator()
        let (keyPair, peerID) = makeTestIdentity()
        let key = makeIPNSKey(for: peerID)

        let record1 = try IPNSRecord.create(
            value: Array("/ipfs/QmEarly".utf8),
            sequence: 10,
            validity: Date().addingTimeInterval(1800),
            keyPair: keyPair
        )
        let record2 = try IPNSRecord.create(
            value: Array("/ipfs/QmLate".utf8),
            sequence: 10,
            validity: Date().addingTimeInterval(7200),
            keyPair: keyPair
        )
        let record3 = try IPNSRecord.create(
            value: Array("/ipfs/QmMid".utf8),
            sequence: 10,
            validity: Date().addingTimeInterval(3600),
            keyPair: keyPair
        )

        let records = [record1.encode(), record2.encode(), record3.encode()]
        let bestIndex = try validator.select(key: key, records: records)

        // Record at index 1 has the latest validity (7200s from now)
        #expect(bestIndex == 1)
    }

    // MARK: - IPNSRecord Encoding Format

    @Test("IPNSRecord encoding format contains expected fields")
    func encodingFormatFields() throws {
        let (keyPair, _) = makeTestIdentity()
        let value = Array("/ipfs/QmFormat".utf8)
        let validity = Date().addingTimeInterval(3600)

        let record = try IPNSRecord.create(
            value: value,
            sequence: 7,
            validity: validity,
            keyPair: keyPair
        )

        let encoded = record.encode()

        // The encoded data should be non-trivial length
        #expect(encoded.count > 50)

        // Decode it back and verify all fields survive
        let decoded = try IPNSRecord.decode(from: encoded)
        #expect(decoded.value == value)
        #expect(decoded.sequence == 7)
        #expect(decoded.validityType == .eol)
        #expect(decoded.signature == record.signature)
        #expect(decoded.publicKey == record.publicKey)
    }

    // MARK: - Concurrent Safety

    @Test("IPNSValidator is safe for concurrent use", .timeLimit(.minutes(1)))
    func concurrentSafety() async throws {
        let validator = IPNSValidator()
        let (keyPair, peerID) = makeTestIdentity()
        let key = makeIPNSKey(for: peerID)
        let validity = Date().addingTimeInterval(3600)

        let record = try IPNSRecord.create(
            value: Array("/ipfs/QmConcurrent".utf8),
            sequence: 1,
            validity: validity,
            keyPair: keyPair
        )
        let encoded = record.encode()

        // Run many concurrent validations
        try await withThrowingTaskGroup(of: Bool.self) { group in
            for _ in 0 ..< 100 {
                group.addTask {
                    try validator.validate(key: key, value: encoded)
                }
            }
            for try await result in group {
                #expect(result)
            }
        }
    }

    // MARK: - RecordValidator Protocol Conformance

    @Test("IPNSValidator works through RecordValidator protocol")
    func recordValidatorConformance() async throws {
        let validator = IPNSValidator()
        let (keyPair, peerID) = makeTestIdentity()
        let key = makeIPNSKey(for: peerID)
        let validity = Date().addingTimeInterval(3600)

        let ipnsRecord = try IPNSRecord.create(
            value: Array("/ipfs/QmProto".utf8),
            sequence: 1,
            validity: validity,
            keyPair: keyPair
        )
        let encoded = ipnsRecord.encode()

        // Use through RecordValidator interface
        let kRecord = KademliaRecord(key: Data(key), value: Data(encoded))
        let isValid = try await validator.validate(record: kRecord, from: peerID)
        #expect(isValid)
    }

    @Test("IPNSValidator rejects records with wrong PeerID in key")
    func rejectWrongPeerIDInKey() throws {
        let validator = IPNSValidator()
        let (keyPair1, _) = makeTestIdentity()
        let (_, peerID2) = makeTestIdentity()

        // Create record signed by keyPair1 but keyed to peerID2
        let key = makeIPNSKey(for: peerID2)
        let validity = Date().addingTimeInterval(3600)

        let record = try IPNSRecord.create(
            value: Array("/ipfs/QmWrong".utf8),
            sequence: 1,
            validity: validity,
            keyPair: keyPair1
        )
        let encoded = record.encode()

        #expect(throws: IPNSRecordError.keyMismatch) {
            _ = try validator.validate(key: key, value: encoded)
        }
    }

    @Test("IPNSValidator select with empty records throws")
    func selectEmptyRecordsThrows() throws {
        let validator = IPNSValidator()
        let key = Array("/ipns/QmSomeKey".utf8)

        #expect(throws: RecordSelectionError.noRecords) {
            _ = try validator.select(key: key, records: [])
        }
    }

    @Test("IPNSValidator select with all invalid records throws")
    func selectAllInvalidRecordsThrows() throws {
        let validator = IPNSValidator()
        let key = Array("/ipns/QmSomeKey".utf8)
        let records: [[UInt8]] = [
            [0xFF, 0xFE],
            [0x00, 0x01, 0x02],
        ]

        #expect(throws: RecordSelectionError.allRecordsInvalid) {
            _ = try validator.select(key: key, records: records)
        }
    }

    // MARK: - Forward Compatibility: Unknown Wire Types

    @Test("IPNSRecord decode skips unknown field with wire type 1 (fixed64)")
    func decodeSkipsUnknownFixed64Field() throws {
        let (keyPair, _) = makeTestIdentity()
        let value = Array("/ipfs/QmForwardCompat64".utf8)
        let validity = Date().addingTimeInterval(3600)

        let record = try IPNSRecord.create(
            value: value,
            sequence: 10,
            validity: validity,
            keyPair: keyPair
        )

        // Encode the valid record and append an unknown field with wire type 1 (fixed64)
        var encoded = Data(record.encode())
        // Field number 100, wire type 1 = (100 << 3) | 1 = 801
        encoded.append(contentsOf: Varint.encode(UInt64(801)))
        // 8 bytes of fixed64 data
        encoded.append(contentsOf: [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])

        let decoded = try IPNSRecord.decode(from: Array(encoded))
        #expect(decoded.value == value)
        #expect(decoded.sequence == 10)
        #expect(decoded.validityType == .eol)
        #expect(!decoded.signature.isEmpty)
    }

    @Test("IPNSRecord decode skips unknown field with wire type 5 (fixed32)")
    func decodeSkipsUnknownFixed32Field() throws {
        let (keyPair, _) = makeTestIdentity()
        let value = Array("/ipfs/QmForwardCompat32".utf8)
        let validity = Date().addingTimeInterval(3600)

        let record = try IPNSRecord.create(
            value: value,
            sequence: 20,
            validity: validity,
            keyPair: keyPair
        )

        // Encode the valid record and append an unknown field with wire type 5 (fixed32)
        var encoded = Data(record.encode())
        // Field number 101, wire type 5 = (101 << 3) | 5 = 813
        encoded.append(contentsOf: Varint.encode(UInt64(813)))
        // 4 bytes of fixed32 data
        encoded.append(contentsOf: [0xAA, 0xBB, 0xCC, 0xDD])

        let decoded = try IPNSRecord.decode(from: Array(encoded))
        #expect(decoded.value == value)
        #expect(decoded.sequence == 20)
        #expect(decoded.validityType == .eol)
        #expect(!decoded.signature.isEmpty)
    }

    @Test("IPNSRecord decode skips multiple unknown wire types")
    func decodeSkipsMultipleUnknownWireTypes() throws {
        let (keyPair, _) = makeTestIdentity()
        let value = Array("/ipfs/QmMultiWireType".utf8)
        let validity = Date().addingTimeInterval(3600)

        let record = try IPNSRecord.create(
            value: value,
            sequence: 30,
            validity: validity,
            keyPair: keyPair
        )

        // Append unknown fields with wire types 0, 1, 2, and 5
        var encoded = Data(record.encode())

        // Unknown varint field (wire type 0): field 90
        encoded.append(contentsOf: Varint.encode(UInt64((90 << 3) | 0)))
        encoded.append(contentsOf: Varint.encode(UInt64(12345)))

        // Unknown fixed64 field (wire type 1): field 91
        encoded.append(contentsOf: Varint.encode(UInt64((91 << 3) | 1)))
        encoded.append(contentsOf: [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])

        // Unknown length-delimited field (wire type 2): field 92
        encoded.append(contentsOf: Varint.encode(UInt64((92 << 3) | 2)))
        encoded.append(contentsOf: Varint.encode(UInt64(3)))
        encoded.append(contentsOf: [0xAA, 0xBB, 0xCC])

        // Unknown fixed32 field (wire type 5): field 93
        encoded.append(contentsOf: Varint.encode(UInt64((93 << 3) | 5)))
        encoded.append(contentsOf: [0xDD, 0xEE, 0xFF, 0x00])

        let decoded = try IPNSRecord.decode(from: Array(encoded))
        #expect(decoded.value == value)
        #expect(decoded.sequence == 30)
    }

    @Test("IPNSRecord decode rejects truncated fixed64 field")
    func decodeRejectsTruncatedFixed64() throws {
        let (keyPair, _) = makeTestIdentity()
        let value = Array("/ipfs/QmTruncated64".utf8)
        let validity = Date().addingTimeInterval(3600)

        let record = try IPNSRecord.create(
            value: value,
            sequence: 1,
            validity: validity,
            keyPair: keyPair
        )

        // Append a fixed64 field tag but only 4 bytes of data (needs 8)
        var encoded = Data(record.encode())
        encoded.append(contentsOf: Varint.encode(UInt64((100 << 3) | 1)))
        encoded.append(contentsOf: [0x01, 0x02, 0x03, 0x04]) // only 4 bytes, need 8

        #expect(throws: IPNSRecordError.invalidFormat) {
            _ = try IPNSRecord.decode(from: Array(encoded))
        }
    }

    @Test("IPNSRecord decode rejects truncated fixed32 field")
    func decodeRejectsTruncatedFixed32() throws {
        let (keyPair, _) = makeTestIdentity()
        let value = Array("/ipfs/QmTruncated32".utf8)
        let validity = Date().addingTimeInterval(3600)

        let record = try IPNSRecord.create(
            value: value,
            sequence: 1,
            validity: validity,
            keyPair: keyPair
        )

        // Append a fixed32 field tag but only 2 bytes of data (needs 4)
        var encoded = Data(record.encode())
        encoded.append(contentsOf: Varint.encode(UInt64((101 << 3) | 5)))
        encoded.append(contentsOf: [0x01, 0x02]) // only 2 bytes, need 4

        #expect(throws: IPNSRecordError.invalidFormat) {
            _ = try IPNSRecord.decode(from: Array(encoded))
        }
    }
}
