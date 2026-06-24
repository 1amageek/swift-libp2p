import Testing
import Foundation
@testable import P2PDiscoveryMDNS
@testable import P2PDiscovery
@testable import P2PCore
import MDNS
import P2PCoreTransport

// MARK: - TXT helpers (new flat-dict + newline-packed-dnsaddr model)
//
// The MDNS facade models TXT attributes as `[String: [UInt8]]` (one value per
// key). The libp2p codec packs MULTIPLE `dnsaddr` multiaddrs into the single
// `txt["dnsaddr"]` value, newline ("\n") separated. These helpers build that
// flat dict from string inputs so the tests read like the old multi-value API.

private func txtString(_ value: String) -> [UInt8] { Array(value.utf8) }

private func dnsaddrTXT(_ multiaddrs: [String]) -> [String: [UInt8]] {
    [PeerTXTKey.dnsaddr: Array(multiaddrs.joined(separator: "\n").utf8)]
}

@Suite("PeerIDServiceCodec Tests")
struct PeerIDServiceCodecTests {

    // MARK: - Encode Tests

    @Test("Encode creates service with correct name")
    func encodeServiceName() throws {
        let keyPair = KeyPair.generateEd25519()
        let peerID = keyPair.peerID
        let addresses = [try Multiaddr("/ip4/127.0.0.1/tcp/4001")]
        let configuration = MDNSConfiguration()

        let service = PeerIDServiceCodec.encode(
            peerID: peerID,
            addresses: addresses,
            port: 4001,
            configuration: configuration
        )

        #expect(service.name == peerID.description)
    }

    @Test("Encode creates service with correct port")
    func encodeServicePort() throws {
        let keyPair = KeyPair.generateEd25519()
        let peerID = keyPair.peerID
        let configuration = MDNSConfiguration()

        let service = PeerIDServiceCodec.encode(
            peerID: peerID,
            addresses: [],
            port: 9999,
            configuration: configuration
        )

        #expect(service.port == 9999)
    }

    @Test("Encode creates service with service type from configuration")
    func encodeServiceType() throws {
        let keyPair = KeyPair.generateEd25519()
        let peerID = keyPair.peerID
        let configuration = MDNSConfiguration(serviceType: "_custom._udp")

        let service = PeerIDServiceCodec.encode(
            peerID: peerID,
            addresses: [],
            port: 4001,
            configuration: configuration
        )

        #expect(service.type == "_custom._udp")
    }

    @Test("Encode creates service with domain from configuration")
    func encodeServiceDomain() throws {
        let keyPair = KeyPair.generateEd25519()
        let peerID = keyPair.peerID
        let configuration = MDNSConfiguration(domain: "custom.")

        let service = PeerIDServiceCodec.encode(
            peerID: peerID,
            addresses: [],
            port: 4001,
            configuration: configuration
        )

        #expect(service.domain == "custom.")
    }

    @Test("Encode includes agent version in TXT record")
    func encodeAgentVersion() throws {
        let keyPair = KeyPair.generateEd25519()
        let peerID = keyPair.peerID
        let configuration = MDNSConfiguration(agentVersion: "test-agent/1.0")

        let service = PeerIDServiceCodec.encode(
            peerID: peerID,
            addresses: [],
            port: 4001,
            configuration: configuration
        )

        #expect(service.txt[PeerTXTKey.agentVersion] == txtString("test-agent/1.0"))
    }

    @Test("Encode extracts protocols from addresses")
    func encodeExtractsProtocols() throws {
        let keyPair = KeyPair.generateEd25519()
        let peerID = keyPair.peerID
        let addresses = [
            try Multiaddr("/ip4/127.0.0.1/tcp/4001"),
            try Multiaddr("/ip4/127.0.0.1/udp/4002")
        ]
        let configuration = MDNSConfiguration()

        let service = PeerIDServiceCodec.encode(
            peerID: peerID,
            addresses: addresses,
            port: 4001,
            configuration: configuration
        )

        let protocolsBytes = service.txt[PeerTXTKey.protocols]
        #expect(protocolsBytes != nil)
        let protocols = protocolsBytes.map { String(decoding: $0, as: UTF8.self) }
        // Should contain ip4, tcp, udp (sorted)
        #expect(protocols?.contains("ip4") == true)
        #expect(protocols?.contains("tcp") == true)
        #expect(protocols?.contains("udp") == true)
    }

    @Test("Encode with empty addresses has no protocols")
    func encodeEmptyAddressesNoProtocols() throws {
        let keyPair = KeyPair.generateEd25519()
        let peerID = keyPair.peerID
        let configuration = MDNSConfiguration()

        let service = PeerIDServiceCodec.encode(
            peerID: peerID,
            addresses: [],
            port: 4001,
            configuration: configuration
        )

        #expect(service.txt[PeerTXTKey.protocols] == nil)
    }

    @Test("Encode supports custom service name override")
    func encodeCustomServiceName() throws {
        let keyPair = KeyPair.generateEd25519()
        let peerID = keyPair.peerID
        let customName = "opaque-peer-name"

        let service = PeerIDServiceCodec.encode(
            peerID: peerID,
            addresses: [],
            port: 4001,
            configuration: MDNSConfiguration(),
            serviceName: customName
        )

        #expect(service.name == customName)
    }

    // MARK: - Decode Tests

    @Test("Decode service with valid PeerID name")
    func decodeValidPeerID() throws {
        let keyPair = KeyPair.generateEd25519()
        let peerID = keyPair.peerID
        let observer = KeyPair.generateEd25519().peerID

        let service = MDNSService(
            name: peerID.description,
            type: "_p2p._udp",
            domain: "local.",
            port: 4001,
            addresses: [.v4(127, 0, 0, 1)]
        )

        let candidate = try PeerIDServiceCodec.decode(service: service, observer: observer)

        #expect(candidate.peerID == peerID)
    }

    @Test("Decode service with invalid PeerID name throws invalidPeerID")
    func decodeInvalidPeerID() {
        let observer = KeyPair.generateEd25519().peerID

        let service = MDNSService(
            name: "invalid-peer-id",
            type: "_p2p._udp",
            domain: "local.",
            port: 4001,
            addresses: [.v4(127, 0, 0, 1)]
        )

        #expect(throws: MDNSDiscoveryError.self) {
            try PeerIDServiceCodec.decode(service: service, observer: observer)
        }
    }

    @Test("Decode builds addresses from IPv4")
    func decodeIPv4Addresses() throws {
        let keyPair = KeyPair.generateEd25519()
        let peerID = keyPair.peerID
        let observer = KeyPair.generateEd25519().peerID

        let service = MDNSService(
            name: peerID.description,
            type: "_p2p._udp",
            domain: "local.",
            port: 4001,
            addresses: [.v4(192, 168, 1, 1), .v4(10, 0, 0, 1)]
        )

        let candidate = try PeerIDServiceCodec.decode(service: service, observer: observer)

        // Each IPv4 generates TCP address with p2p component
        #expect(candidate.addresses.count == 2)
    }

    @Test("Decode builds addresses from IPv6")
    func decodeIPv6Addresses() throws {
        let keyPair = KeyPair.generateEd25519()
        let peerID = keyPair.peerID
        let observer = KeyPair.generateEd25519().peerID

        // 2001:db8::1
        let service = MDNSService(
            name: peerID.description,
            type: "_p2p._udp",
            domain: "local.",
            port: 4001,
            addresses: [.v6(InlineIPv6(0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x01))]
        )

        let candidate = try PeerIDServiceCodec.decode(service: service, observer: observer)

        // IPv6 generates TCP address with p2p component
        #expect(candidate.addresses.count == 1)
    }

    @Test("Decode with no port returns empty addresses")
    func decodeNoPort() throws {
        let keyPair = KeyPair.generateEd25519()
        let peerID = keyPair.peerID
        let observer = KeyPair.generateEd25519().peerID

        let service = MDNSService(
            name: peerID.description,
            type: "_p2p._udp",
            domain: "local.",
            port: nil,
            addresses: [.v4(127, 0, 0, 1)]
        )

        let candidate = try PeerIDServiceCodec.decode(service: service, observer: observer)

        #expect(candidate.addresses.isEmpty)
    }

    // MARK: - Score Calculation Tests

    @Test("Score is at least 0.5 for basic discovery")
    func scoreBaseValue() throws {
        let keyPair = KeyPair.generateEd25519()
        let peerID = keyPair.peerID
        let observer = KeyPair.generateEd25519().peerID

        let service = MDNSService(
            name: peerID.description,
            type: "_p2p._udp",
            domain: "local.",
            port: nil,
            addresses: []
        )

        let candidate = try PeerIDServiceCodec.decode(service: service, observer: observer)

        #expect(candidate.score >= 0.5)
    }

    @Test("Score increases with addresses")
    func scoreIncreasesWithAddresses() throws {
        let keyPair = KeyPair.generateEd25519()
        let peerID = keyPair.peerID
        let observer = KeyPair.generateEd25519().peerID

        let serviceNoAddr = MDNSService(
            name: peerID.description,
            type: "_p2p._udp",
            domain: "local.",
            port: nil,
            addresses: []
        )

        let serviceWithAddr = MDNSService(
            name: peerID.description,
            type: "_p2p._udp",
            domain: "local.",
            host: "host.local",
            port: 4001,
            addresses: [.v4(127, 0, 0, 1)]
        )

        let candidateNoAddr = try PeerIDServiceCodec.decode(service: serviceNoAddr, observer: observer)
        let candidateWithAddr = try PeerIDServiceCodec.decode(service: serviceWithAddr, observer: observer)

        #expect(candidateWithAddr.score > candidateNoAddr.score)
    }

    @Test("Score increases with both IPv4 and IPv6")
    func scoreIncreasesWithDualStack() throws {
        let keyPair = KeyPair.generateEd25519()
        let peerID = keyPair.peerID
        let observer = KeyPair.generateEd25519().peerID

        let serviceIPv4Only = MDNSService(
            name: peerID.description,
            type: "_p2p._udp",
            domain: "local.",
            host: "host.local",
            port: 4001,
            addresses: [.v4(127, 0, 0, 1)]
        )

        // 127.0.0.1 + ::1
        let serviceDualStack = MDNSService(
            name: peerID.description,
            type: "_p2p._udp",
            domain: "local.",
            host: "host.local",
            port: 4001,
            addresses: [
                .v4(127, 0, 0, 1),
                .v6(InlineIPv6(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x01))
            ]
        )

        let candidateIPv4 = try PeerIDServiceCodec.decode(service: serviceIPv4Only, observer: observer)
        let candidateDual = try PeerIDServiceCodec.decode(service: serviceDualStack, observer: observer)

        #expect(candidateDual.score > candidateIPv4.score)
    }

    @Test("Score capped at 1.0")
    func scoreCapped() throws {
        let keyPair = KeyPair.generateEd25519()
        let peerID = keyPair.peerID
        let observer = KeyPair.generateEd25519().peerID

        // Create a fully resolved service with all bonuses (host + port + dual stack)
        let service = MDNSService(
            name: peerID.description,
            type: "_p2p._udp",
            domain: "local.",
            host: "host.local",
            port: 4001,
            addresses: [
                .v4(127, 0, 0, 1),
                .v4(192, 168, 1, 1),
                .v6(InlineIPv6(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x01)),
                .v6(InlineIPv6(0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x01))
            ]
        )

        let candidate = try PeerIDServiceCodec.decode(service: service, observer: observer)

        #expect(candidate.score <= 1.0)
    }

    // MARK: - Observation Conversion Tests

    @Test("toObservation creates valid observation")
    func toObservationBasic() throws {
        let keyPair = KeyPair.generateEd25519()
        let peerID = keyPair.peerID
        let observer = KeyPair.generateEd25519().peerID

        let service = MDNSService(
            name: peerID.description,
            type: "_p2p._udp",
            domain: "local.",
            port: 4001,
            addresses: [.v4(192, 168, 1, 1)]
        )

        let observation = try PeerIDServiceCodec.toObservation(
            service: service,
            kind: .announcement,
            observer: observer,
            sequenceNumber: 42
        )

        #expect(observation.subject == peerID)
        #expect(observation.observer == observer)
        #expect(observation.kind == .announcement)
        #expect(observation.sequenceNumber == 42)
    }

    @Test("toObservation with invalid PeerID throws invalidPeerID")
    func toObservationInvalidPeerID() {
        let observer = KeyPair.generateEd25519().peerID

        let service = MDNSService(
            name: "invalid-name",
            type: "_p2p._udp",
            domain: "local.",
            port: 4001,
            addresses: [.v4(127, 0, 0, 1)]
        )

        #expect(throws: MDNSDiscoveryError.self) {
            try PeerIDServiceCodec.toObservation(
                service: service,
                kind: .reachable,
                observer: observer,
                sequenceNumber: 1
            )
        }
    }

    @Test("toObservation includes address hints")
    func toObservationIncludesHints() throws {
        let keyPair = KeyPair.generateEd25519()
        let peerID = keyPair.peerID
        let observer = KeyPair.generateEd25519().peerID

        let service = MDNSService(
            name: peerID.description,
            type: "_p2p._udp",
            domain: "local.",
            port: 4001,
            addresses: [
                .v4(192, 168, 1, 1),
                .v4(10, 0, 0, 1),
                .v6(InlineIPv6(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x01))
            ]
        )

        let observation = try PeerIDServiceCodec.toObservation(
            service: service,
            kind: .reachable,
            observer: observer,
            sequenceNumber: 1
        )

        // Should have an address hint for each IP (2 IPv4 + 1 IPv6)
        #expect(observation.hints.count == 3)
    }

    @Test("toObservation with unreachable kind")
    func toObservationUnreachable() throws {
        let keyPair = KeyPair.generateEd25519()
        let peerID = keyPair.peerID
        let observer = KeyPair.generateEd25519().peerID

        let service = MDNSService(
            name: peerID.description,
            type: "_p2p._udp",
            domain: "local.",
            port: 4001,
            addresses: [.v4(127, 0, 0, 1)]
        )

        let observation = try PeerIDServiceCodec.toObservation(
            service: service,
            kind: .unreachable,
            observer: observer,
            sequenceNumber: 99
        )

        #expect(observation.kind == .unreachable)
    }
}

// MARK: - PeerTXTKey Tests

@Suite("PeerTXTKey Tests")
struct PeerTXTKeyTests {

    @Test("Public key constant is 'pk'")
    func publicKeyConstant() {
        #expect(PeerTXTKey.publicKey == "pk")
    }

    @Test("Agent version constant is 'agent'")
    func agentVersionConstant() {
        #expect(PeerTXTKey.agentVersion == "agent")
    }

    @Test("Protocols constant is 'protos'")
    func protocolsConstant() {
        #expect(PeerTXTKey.protocols == "protos")
    }
}

// MARK: - MDNSConfiguration Tests

@Suite("MDNSConfiguration Tests")
struct MDNSConfigurationTests {

    @Test("Default configuration values")
    func defaultValues() {
        let config = MDNSConfiguration()

        #expect(config.serviceType == "_p2p._udp")
        #expect(config.domain == "local")
        #expect(config.queryInterval > .zero)
        #expect(config.peerNameStrategy == .random)
    }

    @Test("Custom service type")
    func customServiceType() {
        let config = MDNSConfiguration(serviceType: "_custom._tcp")

        #expect(config.serviceType == "_custom._tcp")
    }

    @Test("Custom domain")
    func customDomain() {
        let config = MDNSConfiguration(domain: "custom.")

        #expect(config.domain == "custom.")
    }

    @Test("Custom agent version")
    func customAgentVersion() {
        let config = MDNSConfiguration(agentVersion: "my-app/2.0")

        #expect(config.agentVersion == "my-app/2.0")
    }

    @Test("Custom peer name strategy")
    func customPeerNameStrategy() {
        let config = MDNSConfiguration(peerNameStrategy: .peerID)
        #expect(config.peerNameStrategy == .peerID)
    }

    // MARK: - dnsaddr TXT Attribute Tests (libp2p mDNS spec)
    //
    // The facade packs multiple dnsaddr multiaddrs into the single
    // `txt["dnsaddr"]` value, newline-separated. These tests read/write that
    // packed value via the `dnsaddrTXT` / split helpers.

    @Test("Encode includes dnsaddr TXT attributes")
    func encodeDnsaddrAttributes() throws {
        let keyPair = KeyPair.generateEd25519()
        let peerID = keyPair.peerID
        let addresses = [
            try Multiaddr("/ip4/127.0.0.1/tcp/4001"),
            try Multiaddr("/ip6/::1/tcp/4001")
        ]

        let service = PeerIDServiceCodec.encode(
            peerID: peerID,
            addresses: addresses,
            port: 4001,
            configuration: MDNSConfiguration()
        )

        // The codec packs the dnsaddr entries into one newline-separated value.
        let packed = try #require(service.txt[PeerTXTKey.dnsaddr])
        let dnsaddrValues = String(decoding: packed, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)

        #expect(dnsaddrValues.count == 2)
        #expect(dnsaddrValues[0].contains("/ip4/127.0.0.1/tcp/4001"))
        #expect(dnsaddrValues[1].contains("/ip6/::1/tcp/4001"))

        // All dnsaddr values should include p2p component
        for value in dnsaddrValues {
            #expect(value.contains("/p2p/"))
        }
    }

    @Test("Encode preserves existing p2p component in multiaddr")
    func encodePreservesP2PComponent() throws {
        let keyPair = KeyPair.generateEd25519()
        let peerID = keyPair.peerID
        let addresses = [
            try Multiaddr("/ip4/127.0.0.1/tcp/4001/p2p/\(peerID)")
        ]

        let service = PeerIDServiceCodec.encode(
            peerID: peerID,
            addresses: addresses,
            port: 4001,
            configuration: MDNSConfiguration()
        )

        let packed = try #require(service.txt[PeerTXTKey.dnsaddr])
        let dnsaddrValues = String(decoding: packed, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        #expect(dnsaddrValues.count == 1)
        #expect(dnsaddrValues[0] == "/ip4/127.0.0.1/tcp/4001/p2p/\(peerID)")
    }

    @Test("Decode reads dnsaddr TXT attributes")
    func decodeDnsaddrAttributes() throws {
        let keyPair = KeyPair.generateEd25519()
        let peerID = keyPair.peerID
        let observer = KeyPair.generateEd25519().peerID

        let service = MDNSService(
            name: peerID.description,
            type: "_p2p._udp",
            domain: "local.",
            port: 4001,
            txt: dnsaddrTXT([
                "/ip4/192.168.1.1/tcp/4001/p2p/\(peerID)",
                "/ip6/fe80::1/tcp/4001/p2p/\(peerID)"
            ])
        )

        let candidate = try PeerIDServiceCodec.decode(service: service, observer: observer)

        #expect(candidate.addresses.count == 2)
        #expect(candidate.addresses[0].description == "/ip4/192.168.1.1/tcp/4001/p2p/\(peerID)")
        #expect(candidate.addresses[1].description == "/ip6/fe80::1/tcp/4001/p2p/\(peerID)")
    }

    @Test("Decode succeeds with opaque service name when dnsaddr contains peer ID")
    func decodeWithOpaqueServiceName() throws {
        let keyPair = KeyPair.generateEd25519()
        let peerID = keyPair.peerID
        let observer = KeyPair.generateEd25519().peerID

        let service = MDNSService(
            name: "opaque-peer-name",
            type: "_p2p._udp",
            domain: "local.",
            port: 4001,
            txt: dnsaddrTXT(["/ip4/192.168.1.1/tcp/4001/p2p/\(peerID)"])
        )

        let candidate = try PeerIDServiceCodec.decode(service: service, observer: observer)

        #expect(candidate.peerID == peerID)
        #expect(candidate.addresses.count == 1)
    }

    @Test("Decode normalizes scoped IPv6 dnsaddr to canonical ip6zone form")
    func decodeNormalizesScopedIPv6Dnsaddr() throws {
        let keyPair = KeyPair.generateEd25519()
        let peerID = keyPair.peerID
        let observer = KeyPair.generateEd25519().peerID

        let service = MDNSService(
            name: "opaque-peer-name",
            type: "_p2p._udp",
            domain: "local.",
            port: 4001,
            txt: dnsaddrTXT(["/ip6/fe80::1%en0/tcp/4001/p2p/\(peerID)"])
        )

        let candidate = try PeerIDServiceCodec.decode(service: service, observer: observer)

        #expect(candidate.peerID == peerID)
        #expect(candidate.addresses.count == 1)
        #expect(candidate.addresses[0].description == "/ip6zone/en0/ip6/fe80::1/tcp/4001/p2p/\(peerID)")
    }

    @Test("inferPeerID prefers dnsaddr over service name")
    func inferPeerIDPrefersDnsaddr() throws {
        let keyPair = KeyPair.generateEd25519()
        let peerID = keyPair.peerID

        let service = MDNSService(
            name: "opaque-peer-name",
            type: "_p2p._udp",
            domain: "local.",
            port: 4001,
            txt: dnsaddrTXT(["/ip4/10.0.0.1/tcp/4001/p2p/\(peerID)"])
        )

        let inferred = try PeerIDServiceCodec.inferPeerID(from: service)
        #expect(inferred == peerID)
    }

    @Test("inferPeerID falls back to legacy service name")
    func inferPeerIDFallbackToServiceName() throws {
        let peerID = KeyPair.generateEd25519().peerID

        let service = MDNSService(
            name: peerID.description,
            type: "_p2p._udp",
            domain: "local.",
            port: 4001,
            addresses: []
        )

        let inferred = try PeerIDServiceCodec.inferPeerID(from: service)
        #expect(inferred == peerID)
    }

    @Test("Decode skips invalid dnsaddr values")
    func decodeSkipsInvalidDnsaddr() throws {
        let keyPair = KeyPair.generateEd25519()
        let peerID = keyPair.peerID
        let observer = KeyPair.generateEd25519().peerID

        let service = MDNSService(
            name: peerID.description,
            type: "_p2p._udp",
            domain: "local.",
            port: 4001,
            txt: dnsaddrTXT([
                "/ip4/192.168.1.1/tcp/4001/p2p/\(peerID)",
                "invalid-multiaddr",
                "/ip6/fe80::1/tcp/4001/p2p/\(peerID)"
            ])
        )

        let candidate = try PeerIDServiceCodec.decode(service: service, observer: observer)

        // Should skip invalid multiaddr and continue
        #expect(candidate.addresses.count == 2)
        #expect(candidate.addresses[0].description == "/ip4/192.168.1.1/tcp/4001/p2p/\(peerID)")
        #expect(candidate.addresses[1].description == "/ip6/fe80::1/tcp/4001/p2p/\(peerID)")
    }

    @Test("Decode adds p2p component if missing from dnsaddr")
    func decodeAddsP2PComponent() throws {
        let keyPair = KeyPair.generateEd25519()
        let peerID = keyPair.peerID
        let observer = KeyPair.generateEd25519().peerID

        let service = MDNSService(
            name: peerID.description,
            type: "_p2p._udp",
            domain: "local.",
            port: 4001,
            txt: dnsaddrTXT(["/ip4/192.168.1.1/tcp/4001"])
        )

        let candidate = try PeerIDServiceCodec.decode(service: service, observer: observer)

        #expect(candidate.addresses.count == 1)
        #expect(candidate.addresses[0].description == "/ip4/192.168.1.1/tcp/4001/p2p/\(peerID)")
    }

    @Test("Decode skips dnsaddr with mismatched peer ID")
    func decodeSkipsMismatchedPeerID() throws {
        let keyPair = KeyPair.generateEd25519()
        let peerID = keyPair.peerID
        let otherPeerID = KeyPair.generateEd25519().peerID
        let observer = KeyPair.generateEd25519().peerID

        // Both peer IDs appear in dnsaddr; the codec resolves the subject from the
        // service name (peerID) and keeps only the matching dnsaddr entry. When
        // multiple distinct peer IDs are present, dnsaddr-based inference returns
        // nil, so inference falls back to the service name.
        let service = MDNSService(
            name: peerID.description,
            type: "_p2p._udp",
            domain: "local.",
            port: 4001,
            txt: dnsaddrTXT([
                "/ip4/192.168.1.1/tcp/4001/p2p/\(peerID)",
                "/ip4/192.168.1.2/tcp/4001/p2p/\(otherPeerID)"
            ])
        )

        let candidate = try PeerIDServiceCodec.decode(service: service, observer: observer)

        // Should skip mismatched peer ID
        #expect(candidate.peerID == peerID)
        #expect(candidate.addresses.count == 1)
        #expect(candidate.addresses[0].description == "/ip4/192.168.1.1/tcp/4001/p2p/\(peerID)")
    }

    @Test("Decode falls back to A/AAAA records when no dnsaddr")
    func decodeFallbackToARecords() throws {
        let keyPair = KeyPair.generateEd25519()
        let peerID = keyPair.peerID
        let observer = KeyPair.generateEd25519().peerID

        // 192.168.1.1 + 2001:db8::1
        let service = MDNSService(
            name: peerID.description,
            type: "_p2p._udp",
            domain: "local.",
            port: 4001,
            addresses: [
                .v4(192, 168, 1, 1),
                .v6(InlineIPv6(0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x01))
            ]
        )

        let candidate = try PeerIDServiceCodec.decode(service: service, observer: observer)

        // Should fall back to A/AAAA records: one IPv4 + one IPv6 address.
        #expect(candidate.addresses.count == 2)
        #expect(candidate.addresses[0].description == "/ip4/192.168.1.1/tcp/4001/p2p/\(peerID)")
        // The IPv6 fallback is rendered from raw bytes and canonicalized by
        // Multiaddr; assert it is an ip6 address with the right port + p2p rather
        // than pinning Multiaddr's exact IPv6 text canonicalization.
        let ipv6Addr = candidate.addresses[1].description
        #expect(ipv6Addr.hasPrefix("/ip6/"))
        #expect(ipv6Addr.contains("/tcp/4001/p2p/\(peerID)"))
    }

    @Test("Decode prefers dnsaddr over A/AAAA records")
    func decodePrefersDnsaddr() throws {
        let keyPair = KeyPair.generateEd25519()
        let peerID = keyPair.peerID
        let observer = KeyPair.generateEd25519().peerID

        let service = MDNSService(
            name: peerID.description,
            type: "_p2p._udp",
            domain: "local.",
            port: 4001,
            addresses: [.v4(192, 168, 1, 1)],
            txt: dnsaddrTXT(["/ip4/10.0.0.1/tcp/5001/p2p/\(peerID)"])
        )

        let candidate = try PeerIDServiceCodec.decode(service: service, observer: observer)

        // Should use dnsaddr, not A record
        #expect(candidate.addresses.count == 1)
        #expect(candidate.addresses[0].description == "/ip4/10.0.0.1/tcp/5001/p2p/\(peerID)")
    }

    @Test("toObservation reads dnsaddr TXT attributes")
    func toObservationDnsaddr() throws {
        let keyPair = KeyPair.generateEd25519()
        let peerID = keyPair.peerID
        let observer = KeyPair.generateEd25519().peerID

        let service = MDNSService(
            name: peerID.description,
            type: "_p2p._udp",
            domain: "local.",
            port: 4001,
            txt: dnsaddrTXT(["/ip4/192.168.1.1/tcp/4001/p2p/\(peerID)"])
        )

        let observation = try PeerIDServiceCodec.toObservation(
            service: service,
            kind: .reachable,
            observer: observer,
            sequenceNumber: 1
        )

        #expect(observation.hints.count == 1)
        #expect(observation.hints[0].description == "/ip4/192.168.1.1/tcp/4001/p2p/\(peerID)")
    }

    @Test("toObservation falls back to A/AAAA records")
    func toObservationFallback() throws {
        let keyPair = KeyPair.generateEd25519()
        let peerID = keyPair.peerID
        let observer = KeyPair.generateEd25519().peerID

        // 192.168.1.1 + fe80::1 (link-local IPv6 is skipped in fallback)
        let service = MDNSService(
            name: peerID.description,
            type: "_p2p._udp",
            domain: "local.",
            port: 4001,
            addresses: [
                .v4(192, 168, 1, 1),
                .v6(InlineIPv6(0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x01))
            ]
        )

        let observation = try PeerIDServiceCodec.toObservation(
            service: service,
            kind: .reachable,
            observer: observer,
            sequenceNumber: 1
        )

        // The link-local IPv6 is skipped (no scope), leaving the single IPv4 hint.
        #expect(observation.hints.count == 1)
        #expect(observation.hints[0].description == "/ip4/192.168.1.1/tcp/4001/p2p/\(peerID)")
    }

    @Test("Decode fallback skips link-local IPv6 without scope")
    func decodeFallbackSkipsLinkLocalIPv6() throws {
        let keyPair = KeyPair.generateEd25519()
        let peerID = keyPair.peerID
        let observer = KeyPair.generateEd25519().peerID

        // fe80::1 link-local IPv6
        let service = MDNSService(
            name: peerID.description,
            type: "_p2p._udp",
            domain: "local.",
            port: 4001,
            addresses: [.v6(InlineIPv6(0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x01))]
        )

        let candidate = try PeerIDServiceCodec.decode(service: service, observer: observer)
        #expect(candidate.addresses.isEmpty)
    }
}
