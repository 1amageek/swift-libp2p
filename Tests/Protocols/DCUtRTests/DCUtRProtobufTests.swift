/// Tests for DCUtR protobuf encoding/decoding.

import Testing
import Foundation
@testable import P2PDCUtR
@testable import P2PCore

@Suite("DCUtR Protobuf Tests")
struct DCUtRProtobufTests {

    @Test("Encode and decode CONNECT message with addresses")
    func encodeDecodeConnectWithAddresses() throws {
        let addresses = [
            try Multiaddr("/ip4/127.0.0.1/tcp/4001"),
            try Multiaddr("/ip4/192.168.1.1/tcp/4001"),
        ]

        let message = DCUtRMessage.connect(addresses: addresses)
        let encoded = DCUtRProtobuf.encode(message)
        let decoded = try DCUtRProtobuf.decode(encoded)

        #expect(decoded.type == DCUtRMessageType.connect)
        #expect(decoded.observedAddresses.count == 2)
    }

    @Test("Encode and decode CONNECT message without addresses")
    func encodeDecodeConnectEmpty() throws {
        let message = DCUtRMessage.connect(addresses: [])
        let encoded = DCUtRProtobuf.encode(message)
        let decoded = try DCUtRProtobuf.decode(encoded)

        #expect(decoded.type == .connect)
        #expect(decoded.observedAddresses.isEmpty)
    }

    @Test("Encode and decode SYNC message")
    func encodeDecodeSync() throws {
        let message = DCUtRMessage.sync()
        let encoded = DCUtRProtobuf.encode(message)
        let decoded = try DCUtRProtobuf.decode(encoded)

        #expect(decoded.type == .sync)
        #expect(decoded.observedAddresses.isEmpty)
    }

    @Test("Message type values match spec")
    func messageTypeValues() {
        #expect(DCUtRMessageType.connect.rawValue == 100)
        #expect(DCUtRMessageType.sync.rawValue == 300)
    }

    // MARK: - Malformed Message Tests

    @Test("Decode empty data throws (missing required type field)")
    func decodeEmptyData() {
        // A message with no type field must be rejected, not silently defaulted.
        #expect(throws: DCUtRError.self) {
            _ = try DCUtRProtobuf.decode(Data())
        }
    }

    @Test("Decode with invalid Multiaddr bytes is rejected (no silent skip)")
    func decodeInvalidMultiaddrRejected() throws {
        // Create a valid CONNECT message
        let addresses = [
            try Multiaddr("/ip4/127.0.0.1/tcp/4001"),
        ]
        let message = DCUtRMessage.connect(addresses: addresses)
        var encoded = DCUtRProtobuf.encode(message)

        // Manually append an invalid address field (field 2, wire type 2 = length-delimited)
        // Field tag: (2 << 3) | 2 = 18
        encoded.append(18)  // tag
        encoded.append(5)   // length
        encoded.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF, 0xFF])  // invalid multiaddr bytes

        // A malformed address indicates a hostile/corrupt message and must surface.
        #expect(throws: DCUtRError.self) {
            _ = try DCUtRProtobuf.decode(encoded)
        }
    }

    @Test("Decode message with unknown field numbers skips them")
    func decodeUnknownFieldsSkipped() throws {
        let addresses = [try Multiaddr("/ip4/127.0.0.1/tcp/4001")]
        let message = DCUtRMessage.connect(addresses: addresses)
        var encoded = DCUtRProtobuf.encode(message)

        // Append unknown field (field 99, wire type 0 = varint)
        // Field tag: (99 << 3) | 0 = 792
        // Varint encoding of 792: 0xB8 0x06
        encoded.append(contentsOf: [0xB8, 0x06])  // tag for field 99
        encoded.append(42)  // varint value

        let decoded = try DCUtRProtobuf.decode(encoded)

        // Message should decode successfully, unknown field ignored
        #expect(decoded.type == .connect)
        #expect(decoded.observedAddresses.count == 1)
    }

    @Test("Decode truncated message throws error")
    func decodeTruncatedMessage() {
        // Create a truncated length-delimited field
        // Tag for field 2 (ObsAddrs), wire type 2: (2 << 3) | 2 = 18
        // Then a length that extends beyond the data
        let truncatedData = Data([18, 100])  // Length says 100 bytes but only 0 follow

        #expect(throws: (any Error).self) {
            _ = try DCUtRProtobuf.decode(truncatedData)
        }
    }

    @Test("Decode message with unknown type is rejected (no silent default)")
    func decodeUnknownMessageType() {
        // Create raw protobuf with unknown type value (999)
        var data = Data()
        data.append(0x08)  // Field 1, wire type 0
        // Varint encode 999: 0xE7 0x07
        data.append(contentsOf: [0xE7, 0x07])

        // An unknown type must throw rather than default to CONNECT.
        #expect(throws: DCUtRError.self) {
            _ = try DCUtRProtobuf.decode(data)
        }
    }

    @Test("Decode message with mixed valid and invalid addresses")
    func decodeMixedAddresses() throws {
        // Create a CONNECT message with valid addresses
        let validAddresses = [
            try Multiaddr("/ip4/127.0.0.1/tcp/4001"),
            try Multiaddr("/ip4/192.168.1.1/tcp/4001"),
        ]
        let message = DCUtRMessage.connect(addresses: validAddresses)
        let encoded = DCUtRProtobuf.encode(message)

        let decoded = try DCUtRProtobuf.decode(encoded)

        // All valid addresses should be present
        #expect(decoded.observedAddresses.count == 2)
    }

    @Test("Encode and decode SYNC with addresses (should have none)")
    func syncMessageNoAddressesInEncodeDecode() throws {
        // SYNC messages should not have addresses per spec
        let message = DCUtRMessage.sync()
        let encoded = DCUtRProtobuf.encode(message)
        let decoded = try DCUtRProtobuf.decode(encoded)

        #expect(decoded.type == .sync)
        #expect(decoded.observedAddresses.isEmpty)
    }

    @Test("Decode message with 64-bit fixed field skips correctly")
    func decode64BitFieldSkipped() throws {
        var data = Data()
        // Field 1: type = CONNECT (100)
        data.append(0x08)
        data.append(100)  // type 100 as single byte varint
        // Unknown field with wire type 1 (64-bit)
        // Field 99, wire type 1: (99 << 3) | 1 = 793 = 0xB9 0x06
        data.append(contentsOf: [0xB9, 0x06])
        data.append(contentsOf: [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])  // 8 bytes

        let decoded = try DCUtRProtobuf.decode(data)

        #expect(decoded.type == .connect)
    }

    @Test("Decode message with 32-bit fixed field skips correctly")
    func decode32BitFieldSkipped() throws {
        var data = Data()
        // Field 1: type = CONNECT (100)
        data.append(0x08)
        data.append(100)
        // Unknown field with wire type 5 (32-bit)
        // Field 99, wire type 5: (99 << 3) | 5 = 797 = 0xBD 0x06
        data.append(contentsOf: [0xBD, 0x06])
        data.append(contentsOf: [0x01, 0x02, 0x03, 0x04])  // 4 bytes

        let decoded = try DCUtRProtobuf.decode(data)

        #expect(decoded.type == .connect)
    }
}

// MARK: - Address Filtering (isPrivateAddress) Matrix

@Suite("DCUtR isPrivateAddress Matrix")
struct DCUtRAddressFilteringTests {

    @Test("Public IPv4 addresses are not private")
    func publicIPv4() {
        #expect(!isPrivateAddress("8.8.8.8"))
        #expect(!isPrivateAddress("1.1.1.1"))
        #expect(!isPrivateAddress("203.0.113.10"))
    }

    @Test("Private / loopback / link-local / CGNAT IPv4 are private")
    func privateIPv4() {
        #expect(isPrivateAddress("127.0.0.1"))
        #expect(isPrivateAddress("10.1.2.3"))
        #expect(isPrivateAddress("172.16.0.1"))
        #expect(isPrivateAddress("172.31.255.255"))
        #expect(isPrivateAddress("192.168.0.1"))
        #expect(isPrivateAddress("169.254.0.1"))
        #expect(isPrivateAddress("169.254.169.254")) // cloud metadata
        #expect(isPrivateAddress("100.64.0.1"))      // CGNAT
        #expect(isPrivateAddress("0.0.0.0"))
        #expect(isPrivateAddress("224.0.0.1"))       // multicast
        #expect(isPrivateAddress("255.255.255.255"))
    }

    @Test("IPv4-mapped IPv6 to private is private (bypass closed)")
    func ipv4MappedPrivate() {
        #expect(isPrivateAddress("::ffff:127.0.0.1"))
        #expect(isPrivateAddress("::ffff:192.168.1.1"))
        #expect(isPrivateAddress("::ffff:169.254.169.254"))
        // IPv4-mapped to a public address is NOT private.
        #expect(!isPrivateAddress("::ffff:8.8.8.8"))
    }

    @Test("NAT64 / link-local / ULA / multicast IPv6 are private")
    func privateIPv6() {
        #expect(isPrivateAddress("::1"))             // loopback
        #expect(isPrivateAddress("::"))              // unspecified
        #expect(isPrivateAddress("fe80::1"))         // link-local
        #expect(isPrivateAddress("febf::1"))         // fe80::/10 upper edge
        #expect(isPrivateAddress("fc00::1"))         // ULA
        #expect(isPrivateAddress("fd00::1"))         // ULA
        #expect(isPrivateAddress("ff02::1"))         // multicast
        #expect(isPrivateAddress("64:ff9b::1.2.3.4")) // NAT64
    }

    @Test("Public IPv6 is not private")
    func publicIPv6() {
        #expect(!isPrivateAddress("2606:4700:4700::1111"))
    }

    @Test("Malformed addresses fail closed (treated as private)")
    func malformedFailClosed() {
        #expect(isPrivateAddress(""))
        #expect(isPrivateAddress("not-an-ip"))
        #expect(isPrivateAddress("999.1.1.1"))
        #expect(isPrivateAddress("1.2.3"))
        #expect(isPrivateAddress("example.com"))     // DNS host string
        #expect(isPrivateAddress("gggg::1"))
        #expect(isPrivateAddress("::ffff:999.0.0.0"))
    }
}
