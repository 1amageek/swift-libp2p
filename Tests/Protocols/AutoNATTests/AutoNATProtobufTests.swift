/// Tests for AutoNAT protobuf encoding/decoding.

import Testing
import Foundation
@testable import P2PAutoNAT
@testable import P2PCore

@Suite("AutoNAT Protobuf Tests")
struct AutoNATProtobufTests {

    @Test("Encode and decode DIAL message with addresses")
    func encodeDecodeDialWithAddresses() throws {
        let addresses = [
            try Multiaddr("/ip4/127.0.0.1/tcp/4001"),
            try Multiaddr("/ip4/192.168.1.1/tcp/4001"),
        ]

        let message = AutoNATMessage.dial(addresses: addresses)
        let encoded = AutoNATProtobuf.encode(message)
        let decoded = try AutoNATProtobuf.decode(encoded)

        #expect(decoded.type == .dial)
        #expect(decoded.dial != nil)
        #expect(decoded.dial?.peer.addresses.count == 2)
    }

    @Test("Encode and decode DIAL message with peer ID")
    func encodeDecodeDialWithPeerID() throws {
        let keyPair = KeyPair.generateEd25519()
        let peerID = keyPair.peerID
        let addresses = [try Multiaddr("/ip4/127.0.0.1/tcp/4001")]

        let peerInfo = AutoNATPeerInfo(id: peerID, addresses: addresses)
        let message = AutoNATMessage.dial(peer: peerInfo)
        let encoded = AutoNATProtobuf.encode(message)
        let decoded = try AutoNATProtobuf.decode(encoded)

        #expect(decoded.type == .dial)
        #expect(decoded.dial?.peer.id == peerID)
        #expect(decoded.dial?.peer.addresses.count == 1)
    }

    @Test("Encode and decode DIAL_RESPONSE with OK status")
    func encodeDecodeDialResponseOK() throws {
        let address = try Multiaddr("/ip4/203.0.113.1/tcp/4001")
        let response = AutoNATDialResponse.ok(address: address)
        let message = AutoNATMessage.dialResponse(response)

        let encoded = AutoNATProtobuf.encode(message)
        let decoded = try AutoNATProtobuf.decode(encoded)

        #expect(decoded.type == .dialResponse)
        #expect(decoded.dialResponse?.status == .ok)
        #expect(decoded.dialResponse?.address == address)
    }

    @Test("Encode and decode DIAL_RESPONSE with error status")
    func encodeDecodeDialResponseError() throws {
        let response = AutoNATDialResponse.error(.dialError, text: "Connection refused")
        let message = AutoNATMessage.dialResponse(response)

        let encoded = AutoNATProtobuf.encode(message)
        let decoded = try AutoNATProtobuf.decode(encoded)

        #expect(decoded.type == .dialResponse)
        #expect(decoded.dialResponse?.status == .dialError)
        #expect(decoded.dialResponse?.statusText == "Connection refused")
        #expect(decoded.dialResponse?.address == nil)
    }

    @Test("Response status values match spec")
    func responseStatusValues() {
        #expect(AutoNATResponseStatus.ok.rawValue == 0)
        #expect(AutoNATResponseStatus.dialError.rawValue == 100)
        #expect(AutoNATResponseStatus.dialRefused.rawValue == 101)
        #expect(AutoNATResponseStatus.badRequest.rawValue == 200)
        #expect(AutoNATResponseStatus.internalError.rawValue == 300)
    }

    @Test("Message type values match spec")
    func messageTypeValues() {
        #expect(AutoNATMessageType.dial.rawValue == 0)
        #expect(AutoNATMessageType.dialResponse.rawValue == 1)
    }

    // MARK: - Malformed Message Tests

    @Test("Decode empty data throws error")
    func decodeEmptyDataThrows() {
        // Empty data cannot be decoded to a valid message (missing required dial/dialResponse)
        #expect(throws: (any Error).self) {
            _ = try AutoNATProtobuf.decode(Data())
        }
    }

    @Test("Valid message with addresses roundtrips correctly")
    func validMessageRoundtrip() throws {
        // Verify the encoder produces valid data that the decoder can handle
        let addresses = [
            try Multiaddr("/ip4/127.0.0.1/tcp/4001"),
            try Multiaddr("/ip4/192.168.1.1/tcp/4001"),
        ]
        let message = AutoNATMessage.dial(addresses: addresses)
        let encoded = AutoNATProtobuf.encode(message)
        let decoded = try AutoNATProtobuf.decode(encoded)

        // All addresses should be present
        #expect(decoded.dial?.peer.addresses.count == 2)
    }

    @Test("Decode message with unknown field numbers at top level skips them")
    func decodeUnknownFieldsSkipped() throws {
        let addresses = [try Multiaddr("/ip4/127.0.0.1/tcp/4001")]
        let message = AutoNATMessage.dial(addresses: addresses)
        var encoded = AutoNATProtobuf.encode(message)

        // Append unknown field (field 99, wire type 0 = varint)
        // Field tag: (99 << 3) | 0 = 792
        // Varint encoding of 792: 0xB8 0x06
        encoded.append(contentsOf: [0xB8, 0x06])  // tag for field 99
        encoded.append(42)  // varint value

        let decoded = try AutoNATProtobuf.decode(encoded)

        // Message should decode successfully, unknown field ignored
        #expect(decoded.type == .dial)
        #expect(decoded.dial?.peer.addresses.count == 1)
    }

    @Test("Decode truncated message throws error")
    func decodeTruncatedMessage() {
        // Create a truncated length-delimited field
        // Tag for field 2 (dial), wire type 2: (2 << 3) | 2 = 18
        // Then a length that extends beyond the data
        let truncatedData = Data([18, 100])  // Length says 100 bytes but only 0 follow

        #expect(throws: (any Error).self) {
            _ = try AutoNATProtobuf.decode(truncatedData)
        }
    }

    @Test("Decode message with valid addresses preserves all")
    func decodeMixedAddresses() throws {
        // Create a DIAL message with valid addresses
        let validAddresses = [
            try Multiaddr("/ip4/127.0.0.1/tcp/4001"),
            try Multiaddr("/ip4/192.168.1.1/tcp/4001"),
        ]
        let message = AutoNATMessage.dial(addresses: validAddresses)
        let encoded = AutoNATProtobuf.encode(message)

        let decoded = try AutoNATProtobuf.decode(encoded)

        // All valid addresses should be present
        #expect(decoded.dial?.peer.addresses.count == 2)
    }

    @Test("Encode and decode message with zero addresses")
    func encodeDecodeZeroAddresses() throws {
        let message = AutoNATMessage.dial(addresses: [])
        let encoded = AutoNATProtobuf.encode(message)
        let decoded = try AutoNATProtobuf.decode(encoded)

        #expect(decoded.type == .dial)
        #expect(decoded.dial?.peer.addresses.isEmpty == true)
    }

    @Test("Decode dial response message missing response data throws")
    func decodeDialResponseMissingData() {
        // Create message with type=dialResponse but no actual dialResponse data
        // Field 1 (type), wire type 0: 0x08, value 1 (dialResponse)
        let data = Data([0x08, 0x01])

        #expect(throws: (any Error).self) {
            _ = try AutoNATProtobuf.decode(data)
        }
    }

    @Test("Valid dial response roundtrips correctly")
    func validDialResponseRoundtrip() throws {
        let address = try Multiaddr("/ip4/203.0.113.1/tcp/4001")
        let response = AutoNATDialResponse.ok(address: address)
        let message = AutoNATMessage.dialResponse(response)

        let encoded = AutoNATProtobuf.encode(message)
        let decoded = try AutoNATProtobuf.decode(encoded)

        #expect(decoded.type == .dialResponse)
        #expect(decoded.dialResponse?.status == .ok)
        #expect(decoded.dialResponse?.address == address)
    }

    @Test("Dial response with error status roundtrips correctly")
    func dialResponseErrorRoundtrip() throws {
        let response = AutoNATDialResponse.error(.dialError, text: "Connection refused")
        let message = AutoNATMessage.dialResponse(response)

        let encoded = AutoNATProtobuf.encode(message)
        let decoded = try AutoNATProtobuf.decode(encoded)

        #expect(decoded.type == .dialResponse)
        #expect(decoded.dialResponse?.status == .dialError)
        #expect(decoded.dialResponse?.statusText == "Connection refused")
    }
}
