/// ProtobufLiteTests - Unit tests for lightweight protobuf encode/decode
import Testing
import Foundation
@testable import P2PCore

@Suite("ProtobufLite Tests")
struct ProtobufLiteTests {

    // MARK: - Round-trip Tests

    @Test("Single field encode-decode round-trip")
    func testSingleFieldRoundTrip() throws {
        let data = Data("hello".utf8)
        let encoded = encodeProtobufField(fieldNumber: 1, data: data)
        let fields = try decodeProtobufFields(from: encoded)

        #expect(fields.count == 1)
        #expect(fields[0].fieldNumber == 1)
        #expect(fields[0].data == data)
    }

    @Test("Multiple fields encode-decode round-trip")
    func testMultipleFieldsRoundTrip() throws {
        let data1 = Data("field one".utf8)
        let data2 = Data("field two".utf8)
        let data3 = Data("field three".utf8)

        var encoded = Data()
        encoded.append(encodeProtobufField(fieldNumber: 1, data: data1))
        encoded.append(encodeProtobufField(fieldNumber: 2, data: data2))
        encoded.append(encodeProtobufField(fieldNumber: 5, data: data3))

        let fields = try decodeProtobufFields(from: encoded)

        #expect(fields.count == 3)
        #expect(fields[0].fieldNumber == 1)
        #expect(fields[0].data == data1)
        #expect(fields[1].fieldNumber == 2)
        #expect(fields[1].data == data2)
        #expect(fields[2].fieldNumber == 5)
        #expect(fields[2].data == data3)
    }

    @Test("Empty data decodes to zero fields")
    func testEmptyDataDecodesToZeroFields() throws {
        let fields = try decodeProtobufFields(from: Data())
        #expect(fields.isEmpty)
    }

    @Test("Empty field data round-trips correctly")
    func testEmptyFieldData() throws {
        let encoded = encodeProtobufField(fieldNumber: 1, data: Data())
        let fields = try decodeProtobufFields(from: encoded)

        #expect(fields.count == 1)
        #expect(fields[0].fieldNumber == 1)
        #expect(fields[0].data == Data())
    }

    // MARK: - Error Tests

    @Test("Wire type other than 2 throws unexpectedWireType")
    func testUnexpectedWireType() throws {
        // Wire type 0 (varint): field 1, tag = (1 << 3) | 0 = 0x08
        var data = Data()
        data.append(0x08) // tag: field 1, wire type 0
        data.append(0x42) // varint value

        #expect(throws: ProtobufLiteError.self) {
            _ = try decodeProtobufFields(from: data)
        }
    }

    @Test("Truncated field throws truncatedField")
    func testTruncatedField() throws {
        // Field 1, wire type 2, length 10, but only 3 bytes of data
        var data = Data()
        data.append(0x0A) // tag: field 1, wire type 2
        data.append(0x0A) // length: 10
        data.append(contentsOf: [0x01, 0x02, 0x03]) // only 3 bytes

        #expect(throws: ProtobufLiteError.self) {
            _ = try decodeProtobufFields(from: data)
        }
    }

    @Test("Field exceeding maxFieldSize throws fieldTooLarge")
    func testFieldTooLarge() throws {
        let smallData = Data("small".utf8)
        let encoded = encodeProtobufField(fieldNumber: 1, data: smallData)

        // Decode with a very small maxFieldSize
        #expect(throws: ProtobufLiteError.self) {
            _ = try decodeProtobufFields(from: encoded, maxFieldSize: 2)
        }
    }

    // MARK: - Unknown Field Tests

    @Test("Unknown fields are preserved in decoded output")
    func testUnknownFieldsPreserved() throws {
        let known = Data("known".utf8)
        let unknown = Data("unknown".utf8)

        var encoded = Data()
        encoded.append(encodeProtobufField(fieldNumber: 1, data: known))
        encoded.append(encodeProtobufField(fieldNumber: 99, data: unknown))

        let fields = try decodeProtobufFields(from: encoded)

        #expect(fields.count == 2)
        #expect(fields[0].fieldNumber == 1)
        #expect(fields[0].data == known)
        #expect(fields[1].fieldNumber == 99)
        #expect(fields[1].data == unknown)
    }

    // MARK: - Large Field Number Tests

    @Test("Large field numbers encode and decode correctly")
    func testLargeFieldNumber() throws {
        let data = Data("test".utf8)
        let encoded = encodeProtobufField(fieldNumber: 1000, data: data)
        let fields = try decodeProtobufFields(from: encoded)

        #expect(fields.count == 1)
        #expect(fields[0].fieldNumber == 1000)
        #expect(fields[0].data == data)
    }

    // MARK: - Binary Data Tests

    @Test("Binary data round-trips correctly")
    func testBinaryDataRoundTrip() throws {
        let binaryData = Data((0..<256).map { UInt8($0) })
        let encoded = encodeProtobufField(fieldNumber: 1, data: binaryData)
        let fields = try decodeProtobufFields(from: encoded)

        #expect(fields.count == 1)
        #expect(fields[0].data == binaryData)
    }
}
