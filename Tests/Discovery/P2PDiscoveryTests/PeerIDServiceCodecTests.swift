import Testing
import Foundation
@testable import P2PDiscoveryMDNS
@testable import P2PDiscovery
@testable import P2PCore
import mDNS

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

        #expect(service.txtRecord[PeerTXTKey.agentVersion] == "test-agent/1.0")
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

        let protocols = service.txtRecord[PeerTXTKey.protocols]
        #expect(protocols != nil)
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

        #expect(service.txtRecord[PeerTXTKey.protocols] == nil)
    }

    // MARK: - Decode Tests

    @Test("Decode service with valid PeerID name")
    func decodeValidPeerID() throws {
        let keyPair = KeyPair.generateEd25519()
        let peerID = keyPair.peerID
        let observer = KeyPair.generateEd25519().peerID

        let service = Service(
            name: peerID.description,
            type: "_p2p._udp",
            domain: "local.",
            port: 4001,
            ipv4Addresses: [IPv4Address(string: "127.0.0.1")!],
            ipv6Addresses: [],
            txtRecord: TXTRecord()
        )

        let candidate = try PeerIDServiceCodec.decode(service: service, observer: observer)

        #expect(candidate.peerID == peerID)
    }

    @Test("Decode service with invalid PeerID name throws invalidPeerID")
    func decodeInvalidPeerID() {
        let observer = KeyPair.generateEd25519().peerID

        let service = Service(
            name: "invalid-peer-id",
            type: "_p2p._udp",
            domain: "local.",
            port: 4001,
            ipv4Addresses: [IPv4Address(string: "127.0.0.1")!],
            ipv6Addresses: [],
            txtRecord: TXTRecord()
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

        let service = Service(
            name: peerID.description,
            type: "_p2p._udp",
            domain: "local.",
            port: 4001,
            ipv4Addresses: [IPv4Address(string: "192.168.1.1")!, IPv4Address(string: "10.0.0.1")!],
            ipv6Addresses: [],
            txtRecord: TXTRecord()
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

        let service = Service(
            name: peerID.description,
            type: "_p2p._udp",
            domain: "local.",
            port: 4001,
            ipv4Addresses: [],
            ipv6Addresses: [IPv6Address(string: "fe80::1")!],
            txtRecord: TXTRecord()
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

        let service = Service(
            name: peerID.description,
            type: "_p2p._udp",
            domain: "local.",
            port: nil,
            ipv4Addresses: [IPv4Address(string: "127.0.0.1")!],
            ipv6Addresses: [],
            txtRecord: TXTRecord()
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

        let service = Service(
            name: peerID.description,
            type: "_p2p._udp",
            domain: "local.",
            port: nil,
            ipv4Addresses: [],
            ipv6Addresses: [],
            txtRecord: TXTRecord()
        )

        let candidate = try PeerIDServiceCodec.decode(service: service, observer: observer)

        #expect(candidate.score >= 0.5)
    }

    @Test("Score increases with addresses")
    func scoreIncreasesWithAddresses() throws {
        let keyPair = KeyPair.generateEd25519()
        let peerID = keyPair.peerID
        let observer = KeyPair.generateEd25519().peerID

        let serviceNoAddr = Service(
            name: peerID.description,
            type: "_p2p._udp",
            domain: "local.",
            port: nil,
            ipv4Addresses: [],
            ipv6Addresses: [],
            txtRecord: TXTRecord()
        )

        let serviceWithAddr = Service(
            name: peerID.description,
            type: "_p2p._udp",
            domain: "local.",
            port: 4001,
            ipv4Addresses: [IPv4Address(string: "127.0.0.1")!],
            ipv6Addresses: [],
            txtRecord: TXTRecord()
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

        let serviceIPv4Only = Service(
            name: peerID.description,
            type: "_p2p._udp",
            domain: "local.",
            port: 4001,
            ipv4Addresses: [IPv4Address(string: "127.0.0.1")!],
            ipv6Addresses: [],
            txtRecord: TXTRecord()
        )

        let serviceDualStack = Service(
            name: peerID.description,
            type: "_p2p._udp",
            domain: "local.",
            port: 4001,
            ipv4Addresses: [IPv4Address(string: "127.0.0.1")!],
            ipv6Addresses: [IPv6Address(string: "::1")!],
            txtRecord: TXTRecord()
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

        // Create a fully resolved service with all bonuses
        let service = Service(
            name: peerID.description,
            type: "_p2p._udp",
            domain: "local.",
            port: 4001,
            ipv4Addresses: [IPv4Address(string: "127.0.0.1")!, IPv4Address(string: "192.168.1.1")!],
            ipv6Addresses: [IPv6Address(string: "::1")!, IPv6Address(string: "fe80::1")!],
            txtRecord: TXTRecord()
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

        let service = Service(
            name: peerID.description,
            type: "_p2p._udp",
            domain: "local.",
            port: 4001,
            ipv4Addresses: [IPv4Address(string: "192.168.1.1")!],
            ipv6Addresses: [],
            txtRecord: TXTRecord()
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

        let service = Service(
            name: "invalid-name",
            type: "_p2p._udp",
            domain: "local.",
            port: 4001,
            ipv4Addresses: [IPv4Address(string: "127.0.0.1")!],
            ipv6Addresses: [],
            txtRecord: TXTRecord()
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

        let service = Service(
            name: peerID.description,
            type: "_p2p._udp",
            domain: "local.",
            port: 4001,
            ipv4Addresses: [IPv4Address(string: "192.168.1.1")!, IPv4Address(string: "10.0.0.1")!],
            ipv6Addresses: [IPv6Address(string: "::1")!],
            txtRecord: TXTRecord()
        )

        let observation = try PeerIDServiceCodec.toObservation(
            service: service,
            kind: .reachable,
            observer: observer,
            sequenceNumber: 1
        )

        // Should have UDP addresses for each IP
        #expect(observation.hints.count == 3)
    }

    @Test("toObservation with unreachable kind")
    func toObservationUnreachable() throws {
        let keyPair = KeyPair.generateEd25519()
        let peerID = keyPair.peerID
        let observer = KeyPair.generateEd25519().peerID

        let service = Service(
            name: peerID.description,
            type: "_p2p._udp",
            domain: "local.",
            port: 4001,
            ipv4Addresses: [IPv4Address(string: "127.0.0.1")!],
            ipv6Addresses: [],
            txtRecord: TXTRecord()
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

    // MARK: - dnsaddr TXT Attribute Tests (libp2p mDNS spec)

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

        let dnsaddrValues = service.txtRecord.values(forKey: "dnsaddr")
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

        let dnsaddrValues = service.txtRecord.values(forKey: "dnsaddr")
        #expect(dnsaddrValues.count == 1)
        #expect(dnsaddrValues[0] == "/ip4/127.0.0.1/tcp/4001/p2p/\(peerID)")
    }

    @Test("Decode reads dnsaddr TXT attributes")
    func decodeDnsaddrAttributes() throws {
        let keyPair = KeyPair.generateEd25519()
        let peerID = keyPair.peerID
        let observer = KeyPair.generateEd25519().peerID

        var txtRecord = TXTRecord()
        txtRecord.appendValue("/ip4/192.168.1.1/tcp/4001/p2p/\(peerID)", forKey: "dnsaddr")
        txtRecord.appendValue("/ip6/fe80::1/tcp/4001/p2p/\(peerID)", forKey: "dnsaddr")

        let service = Service(
            name: peerID.description,
            type: "_p2p._udp",
            domain: "local.",
            port: 4001,
            ipv4Addresses: [],
            ipv6Addresses: [],
            txtRecord: txtRecord
        )

        let candidate = try PeerIDServiceCodec.decode(service: service, observer: observer)

        #expect(candidate.addresses.count == 2)
        #expect(candidate.addresses[0].description == "/ip4/192.168.1.1/tcp/4001/p2p/\(peerID)")
        #expect(candidate.addresses[1].description == "/ip6/fe80::1/tcp/4001/p2p/\(peerID)")
    }

    @Test("Decode skips invalid dnsaddr values")
    func decodeSkipsInvalidDnsaddr() throws {
        let keyPair = KeyPair.generateEd25519()
        let peerID = keyPair.peerID
        let observer = KeyPair.generateEd25519().peerID

        var txtRecord = TXTRecord()
        txtRecord.appendValue("/ip4/192.168.1.1/tcp/4001/p2p/\(peerID)", forKey: "dnsaddr")
        txtRecord.appendValue("invalid-multiaddr", forKey: "dnsaddr")
        txtRecord.appendValue("/ip6/fe80::1/tcp/4001/p2p/\(peerID)", forKey: "dnsaddr")

        let service = Service(
            name: peerID.description,
            type: "_p2p._udp",
            domain: "local.",
            port: 4001,
            ipv4Addresses: [],
            ipv6Addresses: [],
            txtRecord: txtRecord
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

        var txtRecord = TXTRecord()
        txtRecord.appendValue("/ip4/192.168.1.1/tcp/4001", forKey: "dnsaddr")

        let service = Service(
            name: peerID.description,
            type: "_p2p._udp",
            domain: "local.",
            port: 4001,
            ipv4Addresses: [],
            ipv6Addresses: [],
            txtRecord: txtRecord
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

        var txtRecord = TXTRecord()
        txtRecord.appendValue("/ip4/192.168.1.1/tcp/4001/p2p/\(peerID)", forKey: "dnsaddr")
        txtRecord.appendValue("/ip4/192.168.1.2/tcp/4001/p2p/\(otherPeerID)", forKey: "dnsaddr")

        let service = Service(
            name: peerID.description,
            type: "_p2p._udp",
            domain: "local.",
            port: 4001,
            ipv4Addresses: [],
            ipv6Addresses: [],
            txtRecord: txtRecord
        )

        let candidate = try PeerIDServiceCodec.decode(service: service, observer: observer)

        // Should skip mismatched peer ID
        #expect(candidate.addresses.count == 1)
        #expect(candidate.addresses[0].description == "/ip4/192.168.1.1/tcp/4001/p2p/\(peerID)")
    }

    @Test("Decode falls back to A/AAAA records when no dnsaddr")
    func decodeFallbackToARecords() throws {
        let keyPair = KeyPair.generateEd25519()
        let peerID = keyPair.peerID
        let observer = KeyPair.generateEd25519().peerID

        let service = Service(
            name: peerID.description,
            type: "_p2p._udp",
            domain: "local.",
            port: 4001,
            ipv4Addresses: [IPv4Address(string: "192.168.1.1")!],
            ipv6Addresses: [IPv6Address(string: "fe80::1")!],
            txtRecord: TXTRecord()
        )

        let candidate = try PeerIDServiceCodec.decode(service: service, observer: observer)

        // Should fall back to A/AAAA records
        #expect(candidate.addresses.count == 2)
        #expect(candidate.addresses[0].description == "/ip4/192.168.1.1/tcp/4001/p2p/\(peerID)")
        #expect(candidate.addresses[1].description == "/ip6/fe80::1/tcp/4001/p2p/\(peerID)")
    }

    @Test("Decode prefers dnsaddr over A/AAAA records")
    func decodePrefersDnsaddr() throws {
        let keyPair = KeyPair.generateEd25519()
        let peerID = keyPair.peerID
        let observer = KeyPair.generateEd25519().peerID

        var txtRecord = TXTRecord()
        txtRecord.appendValue("/ip4/10.0.0.1/tcp/5001/p2p/\(peerID)", forKey: "dnsaddr")

        let service = Service(
            name: peerID.description,
            type: "_p2p._udp",
            domain: "local.",
            port: 4001,
            ipv4Addresses: [IPv4Address(string: "192.168.1.1")!],
            ipv6Addresses: [],
            txtRecord: txtRecord
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

        var txtRecord = TXTRecord()
        txtRecord.appendValue("/ip4/192.168.1.1/tcp/4001/p2p/\(peerID)", forKey: "dnsaddr")

        let service = Service(
            name: peerID.description,
            type: "_p2p._udp",
            domain: "local.",
            port: 4001,
            ipv4Addresses: [],
            ipv6Addresses: [],
            txtRecord: txtRecord
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

        let service = Service(
            name: peerID.description,
            type: "_p2p._udp",
            domain: "local.",
            port: 4001,
            ipv4Addresses: [IPv4Address(string: "192.168.1.1")!],
            ipv6Addresses: [],
            txtRecord: TXTRecord()
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
}
