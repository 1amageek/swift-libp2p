import Testing
import Foundation
@testable import P2PCore

@Suite("Multiaddr Tests")
struct MultiaddrTests {

    @Test("Parse simple TCP address")
    func parseSimpleTCP() throws {
        let addr = try Multiaddr("/ip4/127.0.0.1/tcp/4001")

        #expect(addr.protocols.count == 2)
        #expect(addr.ipAddress == "127.0.0.1")
        #expect(addr.tcpPort == 4001)
    }

    @Test("Parse IPv6 TCP address")
    func parseIPv6TCP() throws {
        let addr = try Multiaddr("/ip6/::1/tcp/4001")

        #expect(addr.protocols.count == 2)
        #expect(addr.ipAddress == "0:0:0:0:0:0:0:1")
        #expect(addr.tcpPort == 4001)
    }

    @Test("Parse QUIC address")
    func parseQUIC() throws {
        let addr = try Multiaddr("/ip4/192.168.1.1/udp/4001/quic-v1")

        #expect(addr.protocols.count == 3)
        #expect(addr.ipAddress == "192.168.1.1")
        #expect(addr.udpPort == 4001)
    }

    @Test("Parse address with PeerID")
    func parseWithPeerID() throws {
        let keyPair = KeyPair.generateEd25519()
        let peerID = keyPair.peerID

        let addrString = "/ip4/127.0.0.1/tcp/4001/p2p/\(peerID)"
        let addr = try Multiaddr(addrString)

        #expect(addr.protocols.count == 3)
        #expect(addr.peerID == peerID)
    }

    @Test("String roundtrip")
    func stringRoundtrip() throws {
        let original = "/ip4/192.168.1.100/tcp/8080"
        let addr = try Multiaddr(original)
        let restored = addr.description

        #expect(restored == original)
    }

    @Test("Bytes roundtrip")
    func bytesRoundtrip() throws {
        let addr = try Multiaddr("/ip4/10.0.0.1/tcp/1234")
        let bytes = addr.bytes
        let restored = try Multiaddr(bytes: bytes)

        #expect(addr == restored)
    }

    @Test("Factory methods")
    func factoryMethods() {
        let tcp = Multiaddr.tcp(host: "127.0.0.1", port: 8080)
        #expect(tcp.ipAddress == "127.0.0.1")
        #expect(tcp.tcpPort == 8080)

        let quic = Multiaddr.quic(host: "192.168.1.1", port: 4001)
        #expect(quic.ipAddress == "192.168.1.1")
        #expect(quic.udpPort == 4001)
    }

    @Test("Encapsulation")
    func encapsulation() throws {
        let keyPair = KeyPair.generateEd25519()
        let base = try Multiaddr("/ip4/127.0.0.1/tcp/4001")
        let withPeer = try base.encapsulate(.p2p(keyPair.peerID))

        #expect(withPeer.protocols.count == 3)
        #expect(withPeer.peerID == keyPair.peerID)
    }

    @Test("Decapsulation")
    func decapsulation() throws {
        let keyPair = KeyPair.generateEd25519()
        let full = try Multiaddr("/ip4/127.0.0.1/tcp/4001/p2p/\(keyPair.peerID)")
        let base = full.decapsulate(code: 421) // p2p code

        #expect(base.protocols.count == 2)
        #expect(base.peerID == nil)
    }

    // MARK: - DoS Protection Tests

    @Test("Rejects input exceeding max string size")
    func rejectsOversizedStringInput() {
        // Create a string larger than multiaddrMaxInputSize (1024 bytes)
        let oversizedString = "/" + String(repeating: "x", count: multiaddrMaxInputSize + 100)

        #expect(throws: MultiaddrError.inputTooLarge(size: oversizedString.utf8.count, max: multiaddrMaxInputSize)) {
            _ = try Multiaddr(oversizedString)
        }
    }

    @Test("Rejects input exceeding max byte size")
    func rejectsOversizedBytesInput() {
        // Create bytes larger than multiaddrMaxInputSize (1024 bytes)
        let oversizedBytes = Data(repeating: 0xFF, count: multiaddrMaxInputSize + 100)

        #expect(throws: MultiaddrError.inputTooLarge(size: oversizedBytes.count, max: multiaddrMaxInputSize)) {
            _ = try Multiaddr(bytes: oversizedBytes)
        }
    }

    @Test("Rejects too many protocol components")
    func rejectsTooManyComponents() {
        // Create an address with more than multiaddrMaxComponents (20) components
        // Each "/ip4/1.2.3.4" counts as one component
        var components: [MultiaddrProtocol] = []
        for i in 0..<(multiaddrMaxComponents + 5) {
            components.append(.ip4("1.2.3.\(i % 256)"))
        }

        #expect(throws: MultiaddrError.tooManyComponents(count: components.count, max: multiaddrMaxComponents)) {
            _ = try Multiaddr(protocols: components)
        }
    }

    @Test("Accepts address at maximum component limit")
    func acceptsMaxComponents() throws {
        // Create an address with exactly multiaddrMaxComponents (20) components
        var components: [MultiaddrProtocol] = []
        for i in 0..<multiaddrMaxComponents {
            components.append(.ip4("1.2.3.\(i % 256)"))
        }

        let addr = try Multiaddr(protocols: components)
        #expect(addr.protocols.count == multiaddrMaxComponents)
    }

    @Test("Accepts large but valid string input")
    func acceptsLargeValidInput() throws {
        // Create a valid address string close to but under the limit
        // /ip4/xxx.xxx.xxx.xxx/tcp/xxxxx is about 30 chars
        let addr = try Multiaddr("/ip4/192.168.100.100/tcp/65535")
        #expect(addr.protocols.count == 2)
    }

    @Test("Unchecked initializer bypasses validation")
    func uncheckedBypassesValidation() {
        // This would throw with the checked initializer
        var components: [MultiaddrProtocol] = []
        for i in 0..<(multiaddrMaxComponents + 5) {
            components.append(.ip4("1.2.3.\(i % 256)"))
        }

        // uncheckedProtocols does not validate
        let addr = Multiaddr(uncheckedProtocols: components)
        #expect(addr.protocols.count == multiaddrMaxComponents + 5)
    }

    // MARK: - WebTransport Protocol Tests

    @Test("Parse WebTransport address")
    func parseWebTransport() throws {
        let addr = try Multiaddr("/ip4/127.0.0.1/udp/4433/quic-v1/webtransport")

        #expect(addr.protocols.count == 4)
        #expect(addr.ipAddress == "127.0.0.1")
        #expect(addr.udpPort == 4433)

        let hasWebtransport = addr.protocols.contains { proto in
            if case .webtransport = proto { return true }
            return false
        }
        #expect(hasWebtransport)
    }

    @Test("WebTransport address string roundtrip")
    func webTransportStringRoundtrip() throws {
        let original = "/ip4/127.0.0.1/udp/4433/quic-v1/webtransport"
        let addr = try Multiaddr(original)
        #expect(addr.description == original)
    }

    @Test("WebTransport address bytes roundtrip")
    func webTransportBytesRoundtrip() throws {
        let addr = try Multiaddr("/ip4/192.168.1.1/udp/4433/quic-v1/webtransport")
        let bytes = addr.bytes
        let restored = try Multiaddr(bytes: bytes)
        #expect(addr == restored)
    }

    @Test("WebTransport protocol code is 480")
    func webTransportProtocolCode() {
        let proto = MultiaddrProtocol.webtransport
        #expect(proto.code == 480)
        #expect(proto.name == "webtransport")
        #expect(proto.valueString == nil)
        #expect(proto.valueBytes == Data())
    }

    @Test("WebTransport factory method")
    func webTransportFactory() {
        let addr = Multiaddr.webtransport(host: "127.0.0.1", port: 4433)
        #expect(addr.ipAddress == "127.0.0.1")
        #expect(addr.udpPort == 4433)
        #expect(addr.description == "/ip4/127.0.0.1/udp/4433/quic-v1/webtransport")
    }

    @Test("WebTransport factory method with certhashes")
    func webTransportFactoryWithCerthashes() {
        let hash1 = Data([0x12, 0x20] + Array(repeating: UInt8(0xAA), count: 32))
        let hash2 = Data([0x12, 0x20] + Array(repeating: UInt8(0xBB), count: 32))
        let addr = Multiaddr.webtransport(host: "10.0.0.1", port: 443, certhashes: [hash1, hash2])

        #expect(addr.protocols.count == 6)  // ip4, udp, quic-v1, webtransport, certhash, certhash
        let hasWT = addr.protocols.contains { if case .webtransport = $0 { return true }; return false }
        #expect(hasWT)
    }

    @Test("WebTransport factory method with IPv6")
    func webTransportFactoryIPv6() {
        let addr = Multiaddr.webtransport(host: "::1", port: 4433)
        #expect(addr.ipAddress == "0:0:0:0:0:0:0:1")
        #expect(addr.udpPort == 4433)

        let hasWT = addr.protocols.contains { if case .webtransport = $0 { return true }; return false }
        #expect(hasWT)
    }

    @Test("WebTransport address with certhash string roundtrip")
    func webTransportWithCerthashStringRoundtrip() throws {
        let hashData = Data([0x12, 0x20] + Array(repeating: UInt8(0x42), count: 32))
        let addr = Multiaddr(uncheckedProtocols: [
            .ip4("127.0.0.1"), .udp(4433), .quicV1, .webtransport, .certhash(hashData)
        ])
        let roundtripped = try Multiaddr(addr.description)
        #expect(addr == roundtripped)
    }

    @Test("SocketAddress init rejects oversized input")
    func socketAddressRejectsOversizedInput() {
        // Create a socket address string larger than multiaddrMaxInputSize
        let oversizedHost = String(repeating: "x", count: multiaddrMaxInputSize + 100)
        let oversizedSocketAddr = "\(oversizedHost):4001"

        let result = Multiaddr(socketAddress: oversizedSocketAddr)
        #expect(result == nil)
    }

    @Test("SocketAddress init accepts valid input")
    func socketAddressAcceptsValidInput() {
        // Valid IPv4 socket address
        let addr1 = Multiaddr(socketAddress: "192.168.1.100:4001")
        #expect(addr1 != nil)
        #expect(addr1?.ipAddress == "192.168.1.100")
        #expect(addr1?.tcpPort == 4001)

        // Valid IPv6 socket address
        let addr2 = Multiaddr(socketAddress: "[::1]:5353", transport: .udp)
        #expect(addr2 != nil)
        #expect(addr2?.ipAddress == "0:0:0:0:0:0:0:1")
        #expect(addr2?.udpPort == 5353)
    }

    @Test("IPv6 address rejects oversized input")
    func ipv6RejectsOversizedInput() {
        // Create an oversized IPv6-like string (longer than 45 chars)
        let oversizedIPv6 = String(repeating: "1234:", count: 20) + "1234"  // ~100 chars

        // This should fail to parse as IPv6
        let addr = Multiaddr(socketAddress: "[\(oversizedIPv6)]:4001")
        #expect(addr == nil)
    }

    @Test("IPv6 address accepts valid long addresses")
    func ipv6AcceptsValidLongAddresses() throws {
        // Fully expanded IPv6 address (39 chars): 2001:0db8:85a3:0000:0000:8a2e:0370:7334
        let fullIPv6 = try Multiaddr("/ip6/2001:db8:85a3:0:0:8a2e:370:7334/tcp/4001")
        #expect(fullIPv6.protocols.count == 2)

        // Compressed IPv6
        let compressed = try Multiaddr("/ip6/::1/tcp/4001")
        #expect(compressed.ipAddress == "0:0:0:0:0:0:0:1")
    }
}

@Suite("Varint Tests")
struct VarintTests {

    @Test("Encode small numbers")
    func encodeSmall() {
        #expect(Varint.encode(0) == Data([0x00]))
        #expect(Varint.encode(1) == Data([0x01]))
        #expect(Varint.encode(127) == Data([0x7F]))
    }

    @Test("Encode larger numbers")
    func encodeLarger() {
        #expect(Varint.encode(128) == Data([0x80, 0x01]))
        #expect(Varint.encode(300) == Data([0xAC, 0x02]))
    }

    @Test("Decode roundtrip")
    func decodeRoundtrip() throws {
        for value: UInt64 in [0, 1, 127, 128, 255, 256, 16383, 16384, 1_000_000] {
            let encoded = Varint.encode(value)
            let (decoded, _) = try Varint.decode(encoded)
            #expect(decoded == value)
        }
    }

    @Test("Decode throws on insufficient data")
    func decodeInsufficientData() {
        // High bit set but no more data
        #expect(throws: VarintError.insufficientData) {
            _ = try Varint.decode(Data([0x80]))
        }
    }

    @Test("Decode throws on overflow")
    func decodeOverflow() {
        // 10 bytes all with continuation bit - exceeds 64-bit
        let overflowData = Data([0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80])
        #expect(throws: VarintError.overflow) {
            _ = try Varint.decode(overflowData)
        }
    }

    // MARK: - Safe Int Conversion Tests

    @Test("decodeAsInt succeeds for values within Int range")
    func decodeAsIntSucceeds() throws {
        let data = Varint.encode(UInt64(Int.max))
        let (value, _) = try Varint.decodeAsInt(data)
        #expect(value == Int.max)
    }

    @Test("decodeAsInt throws for values exceeding Int.max")
    func decodeAsIntThrowsForLargeValues() {
        let largeValue = UInt64(Int.max) + 1
        let data = Varint.encode(largeValue)

        #expect(throws: VarintError.self) {
            _ = try Varint.decodeAsInt(data)
        }
    }

    @Test("decodeAsInt throws valueExceedsIntMax with correct value")
    func decodeAsIntErrorContainsValue() {
        let largeValue = UInt64(Int.max) + 1
        let data = Varint.encode(largeValue)

        do {
            _ = try Varint.decodeAsInt(data)
            Issue.record("Expected error to be thrown")
        } catch VarintError.valueExceedsIntMax(let value) {
            #expect(value == largeValue)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("toInt succeeds for values within Int range")
    func toIntSucceeds() throws {
        #expect(try Varint.toInt(0) == 0)
        #expect(try Varint.toInt(UInt64(Int.max)) == Int.max)
    }

    @Test("toInt throws for values exceeding Int.max")
    func toIntThrowsForLargeValues() {
        let largeValue = UInt64(Int.max) + 1
        #expect(throws: VarintError.valueExceedsIntMax(largeValue)) {
            _ = try Varint.toInt(largeValue)
        }
    }

    @Test("decodeAsIntWithRemainder returns correct remainder")
    func decodeAsIntWithRemainderWorks() throws {
        let encoded = Varint.encode(42)
        let extraData = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let data = encoded + extraData

        let (value, remainder) = try Varint.decodeAsIntWithRemainder(data)
        #expect(value == 42)
        #expect(remainder == extraData)
    }
}

@Suite("Base58 Tests")
struct Base58Tests {

    @Test("Encode empty data")
    func encodeEmpty() {
        #expect(Base58.encode(Data()) == "")
    }

    @Test("Encode known values")
    func encodeKnown() {
        #expect(Base58.encode(Data([0x00])) == "1")
        #expect(Base58.encode(Data([0x00, 0x00])) == "11")
        #expect(Base58.encode(Data("Hello".utf8)) == "9Ajdvzr")
    }

    @Test("Decode roundtrip")
    func decodeRoundtrip() throws {
        let testData = [
            Data(),
            Data([0x00]),
            Data([0x00, 0x00, 0x01]),
            Data("Hello, World!".utf8),
            Data(repeating: 0xFF, count: 32)
        ]

        for data in testData {
            let encoded = Base58.encode(data)
            let decoded = try Base58.decode(encoded)
            #expect(decoded == data)
        }
    }
}
