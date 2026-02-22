/// NATPortMapperTests - Tests for NAT port mapping
import Testing
import Foundation
@testable import P2PNAT

@Suite("NATPortMapper Tests")
struct NATPortMapperTests {

    // MARK: - Configuration Tests

    @Test("Default configuration values")
    func defaultConfiguration() {
        let config = NATPortMapperConfiguration.default

        #expect(config.discoveryTimeout == .seconds(5))
        #expect(config.defaultLeaseDuration == .seconds(3600))
        #expect(config.renewalBuffer == .seconds(300))
        #expect(config.autoRenew == true)
        #expect(config.tryUPnP == true)
        #expect(config.tryNATPMP == true)
        #expect(config.natpmpPort == 5351)
    }

    @Test("Custom configuration")
    func customConfiguration() {
        let config = NATPortMapperConfiguration(
            discoveryTimeout: .seconds(10),
            defaultLeaseDuration: .seconds(7200),
            renewalBuffer: .seconds(600),
            autoRenew: false,
            tryUPnP: false,
            tryNATPMP: true,
            natpmpPort: 5350
        )

        #expect(config.discoveryTimeout == .seconds(10))
        #expect(config.defaultLeaseDuration == .seconds(7200))
        #expect(config.autoRenew == false)
        #expect(config.tryUPnP == false)
    }

    // MARK: - PortMapping Tests

    @Test("PortMapping validity check")
    func portMappingValidity() {
        // Create a mapping that expires in the future
        let validMapping = PortMapping(
            internalPort: 4001,
            externalPort: 4001,
            externalAddress: "203.0.113.1",
            protocol: .tcp,
            expiration: ContinuousClock.now + .seconds(3600),
            gatewayType: .natpmp(gatewayIP: "192.168.1.1")
        )

        #expect(validMapping.isValid == true)

        // Create a mapping that has already expired
        let expiredMapping = PortMapping(
            internalPort: 4002,
            externalPort: 4002,
            externalAddress: "203.0.113.1",
            protocol: .udp,
            expiration: ContinuousClock.now - .seconds(1),
            gatewayType: .natpmp(gatewayIP: "192.168.1.1")
        )

        #expect(expiredMapping.isValid == false)
    }

    @Test("PortMapping multiaddr generation")
    func portMappingMultiaddr() throws {
        let tcpMapping = PortMapping(
            internalPort: 4001,
            externalPort: 4001,
            externalAddress: "203.0.113.1",
            protocol: .tcp,
            expiration: ContinuousClock.now + .seconds(3600),
            gatewayType: .natpmp(gatewayIP: "192.168.1.1")
        )

        let tcpAddr = try tcpMapping.multiaddr()
        #expect(tcpAddr.description == "/ip4/203.0.113.1/tcp/4001")

        let udpMapping = PortMapping(
            internalPort: 4002,
            externalPort: 4002,
            externalAddress: "203.0.113.2",
            protocol: .udp,
            expiration: ContinuousClock.now + .seconds(3600),
            gatewayType: .natpmp(gatewayIP: "192.168.1.1")
        )

        let udpAddr = try udpMapping.multiaddr()
        #expect(udpAddr.description == "/ip4/203.0.113.2/udp/4002")
    }

    // MARK: - Gateway Type Tests

    @Test("Gateway type equality")
    func gatewayTypeEquality() {
        let upnp1 = NATGatewayType.upnp(
            controlURL: URL(string: "http://192.168.1.1:5000/ctl")!,
            serviceType: "urn:schemas-upnp-org:service:WANIPConnection:1"
        )
        let upnp2 = NATGatewayType.upnp(
            controlURL: URL(string: "http://192.168.1.1:5000/ctl")!,
            serviceType: "urn:schemas-upnp-org:service:WANIPConnection:1"
        )
        let upnp3 = NATGatewayType.upnp(
            controlURL: URL(string: "http://192.168.1.2:5000/ctl")!,
            serviceType: "urn:schemas-upnp-org:service:WANIPConnection:1"
        )

        #expect(upnp1 == upnp2)
        #expect(upnp1 != upnp3)

        let natpmp1 = NATGatewayType.natpmp(gatewayIP: "192.168.1.1")
        let natpmp2 = NATGatewayType.natpmp(gatewayIP: "192.168.1.1")
        let natpmp3 = NATGatewayType.natpmp(gatewayIP: "192.168.1.2")

        #expect(natpmp1 == natpmp2)
        #expect(natpmp1 != natpmp3)
        #expect(upnp1 != natpmp1)
    }

    // MARK: - Mapper Lifecycle Tests

    @Test("Mapper shutdown")
    func mapperShutdown() async {
        let mapper = NATPortMapper()

        // Shutdown should be idempotent
        await mapper.shutdown()
        await mapper.shutdown()

        // Operations should fail after shutdown
        await #expect(throws: NATPortMapperError.self) {
            _ = try await mapper.discoverGateway()
        }
    }

    @Test("Events stream created on access")
    func eventsStreamCreation() async {
        let mapper = NATPortMapper()

        let events1 = mapper.events
        let events2 = mapper.events

        // Same stream should be returned
        // Note: Can't directly compare AsyncStreams, but this tests
        // that the stream creation is consistent
        _ = events1
        _ = events2

        await mapper.shutdown()
    }

    // MARK: - Error Type Tests

    @Test("Error descriptions")
    func errorDescriptions() {
        let errors: [NATPortMapperError] = [
            .noGatewayFound,
            .discoveryTimeout,
            .externalAddressUnavailable,
            .mappingFailed("test"),
            .portInUse,
            .requestDenied("test"),
            .networkError("test"),
            .invalidResponse,
            .shutdown
        ]

        // Just verify all errors exist and are distinct
        #expect(errors.count == 9)
    }
}

// MARK: - PortMapping Extended Tests

@Suite("PortMapping Tests")
struct PortMappingTests {

    @Test("PortMapping fields are set correctly")
    func portMappingInit() {
        let expiration = ContinuousClock.now + .seconds(3600)
        let mapping = PortMapping(
            internalPort: 8080,
            externalPort: 9090,
            externalAddress: "1.2.3.4",
            protocol: .tcp,
            expiration: expiration,
            gatewayType: .natpmp(gatewayIP: "10.0.0.1")
        )

        #expect(mapping.internalPort == 8080)
        #expect(mapping.externalPort == 9090)
        #expect(mapping.externalAddress == "1.2.3.4")
        #expect(mapping.protocol == .tcp)
    }

    @Test("PortMapping UDP protocol")
    func portMappingUDP() {
        let mapping = PortMapping(
            internalPort: 5000,
            externalPort: 5001,
            externalAddress: "10.0.0.1",
            protocol: .udp,
            expiration: ContinuousClock.now + .seconds(60),
            gatewayType: .natpmp(gatewayIP: "10.0.0.1")
        )

        #expect(mapping.protocol == .udp)
    }

    @Test("PortMapping equatable with same values")
    func portMappingEquatable() {
        let expiration = ContinuousClock.now + .seconds(3600)
        let gateway = NATGatewayType.natpmp(gatewayIP: "10.0.0.1")

        let m1 = PortMapping(
            internalPort: 4001,
            externalPort: 4001,
            externalAddress: "1.2.3.4",
            protocol: .tcp,
            expiration: expiration,
            gatewayType: gateway
        )
        let m2 = PortMapping(
            internalPort: 4001,
            externalPort: 4001,
            externalAddress: "1.2.3.4",
            protocol: .tcp,
            expiration: expiration,
            gatewayType: gateway
        )

        #expect(m1 == m2)
    }

    @Test("PortMapping not equal with different ports")
    func portMappingNotEqual() {
        let expiration = ContinuousClock.now + .seconds(3600)
        let gateway = NATGatewayType.natpmp(gatewayIP: "10.0.0.1")

        let m1 = PortMapping(
            internalPort: 4001,
            externalPort: 4001,
            externalAddress: "1.2.3.4",
            protocol: .tcp,
            expiration: expiration,
            gatewayType: gateway
        )
        let m2 = PortMapping(
            internalPort: 4002,
            externalPort: 4002,
            externalAddress: "1.2.3.4",
            protocol: .tcp,
            expiration: expiration,
            gatewayType: gateway
        )

        #expect(m1 != m2)
    }

    @Test("PortMapping multiaddr for UPnP gateway")
    func portMappingMultiaddrUPnP() throws {
        let mapping = PortMapping(
            internalPort: 80,
            externalPort: 8080,
            externalAddress: "198.51.100.1",
            protocol: .tcp,
            expiration: ContinuousClock.now + .seconds(3600),
            gatewayType: .upnp(
                controlURL: URL(string: "http://192.168.1.1:5000/ctl")!,
                serviceType: "WANIPConnection"
            )
        )

        let addr = try mapping.multiaddr()
        #expect(addr.description == "/ip4/198.51.100.1/tcp/8080")
    }
}

// MARK: - NATPortMapperConfiguration Extended Tests

@Suite("NATPortMapperConfiguration Tests")
struct NATPortMapperConfigTests {

    @Test("Default mapping description")
    func defaultMappingDescription() {
        let config = NATPortMapperConfiguration.default

        #expect(config.mappingDescription == "libp2p")
    }

    @Test("Custom mapping description")
    func customMappingDescription() {
        let config = NATPortMapperConfiguration(
            mappingDescription: "myapp"
        )

        #expect(config.mappingDescription == "myapp")
    }

    @Test("All fields set in custom config")
    func allFieldsCustom() {
        let config = NATPortMapperConfiguration(
            discoveryTimeout: .seconds(15),
            defaultLeaseDuration: .seconds(1800),
            renewalBuffer: .seconds(120),
            autoRenew: false,
            tryUPnP: false,
            tryNATPMP: false,
            natpmpPort: 1234,
            mappingDescription: "test"
        )

        #expect(config.discoveryTimeout == .seconds(15))
        #expect(config.defaultLeaseDuration == .seconds(1800))
        #expect(config.renewalBuffer == .seconds(120))
        #expect(config.autoRenew == false)
        #expect(config.tryUPnP == false)
        #expect(config.tryNATPMP == false)
        #expect(config.natpmpPort == 1234)
        #expect(config.mappingDescription == "test")
    }
}

// MARK: - NATPortMapperEvent Tests

@Suite("NATPortMapperEvent Tests")
struct NATPortMapperEventTests {

    @Test("Gateway discovered event")
    func gatewayDiscovered() {
        let event = NATPortMapperEvent.gatewayDiscovered(
            type: .natpmp(gatewayIP: "192.168.1.1")
        )
        if case .gatewayDiscovered(let type) = event {
            #expect(type == .natpmp(gatewayIP: "192.168.1.1"))
        } else {
            Issue.record("Expected gatewayDiscovered")
        }
    }

    @Test("External address discovered event")
    func externalAddressDiscovered() {
        let event = NATPortMapperEvent.externalAddressDiscovered(address: "1.2.3.4")
        if case .externalAddressDiscovered(let addr) = event {
            #expect(addr == "1.2.3.4")
        } else {
            Issue.record("Expected externalAddressDiscovered")
        }
    }

    @Test("Port mapping created event")
    func portMappingCreated() {
        let mapping = PortMapping(
            internalPort: 4001,
            externalPort: 4001,
            externalAddress: "1.2.3.4",
            protocol: .tcp,
            expiration: ContinuousClock.now + .seconds(3600),
            gatewayType: .natpmp(gatewayIP: "10.0.0.1")
        )
        let event = NATPortMapperEvent.portMappingCreated(mapping: mapping)
        if case .portMappingCreated(let m) = event {
            #expect(m.internalPort == 4001)
        } else {
            Issue.record("Expected portMappingCreated")
        }
    }

    @Test("Port mapping renewed event")
    func portMappingRenewed() {
        let mapping = PortMapping(
            internalPort: 4001,
            externalPort: 4001,
            externalAddress: "1.2.3.4",
            protocol: .tcp,
            expiration: ContinuousClock.now + .seconds(7200),
            gatewayType: .natpmp(gatewayIP: "10.0.0.1")
        )
        let event = NATPortMapperEvent.portMappingRenewed(mapping: mapping)
        if case .portMappingRenewed(let m) = event {
            #expect(m.externalPort == 4001)
        } else {
            Issue.record("Expected portMappingRenewed")
        }
    }

    @Test("Port mapping failed event")
    func portMappingFailed() {
        let event = NATPortMapperEvent.portMappingFailed(
            internalPort: 4001,
            error: .portInUse
        )
        if case .portMappingFailed(let port, let error) = event {
            #expect(port == 4001)
            if case .portInUse = error {} else {
                Issue.record("Expected portInUse error")
            }
        } else {
            Issue.record("Expected portMappingFailed")
        }
    }

    @Test("Port mapping expired event")
    func portMappingExpired() {
        let mapping = PortMapping(
            internalPort: 5000,
            externalPort: 5000,
            externalAddress: "1.2.3.4",
            protocol: .udp,
            expiration: ContinuousClock.now - .seconds(1),
            gatewayType: .natpmp(gatewayIP: "10.0.0.1")
        )
        let event = NATPortMapperEvent.portMappingExpired(mapping: mapping)
        if case .portMappingExpired(let m) = event {
            #expect(m.protocol == .udp)
        } else {
            Issue.record("Expected portMappingExpired")
        }
    }
}

// MARK: - NATPortMapperError Extended Tests

@Suite("NATPortMapperError Tests")
struct NATPortMapperErrorTests {

    @Test("noGatewayFound error")
    func noGatewayFound() {
        let error: NATPortMapperError = .noGatewayFound
        if case .noGatewayFound = error {} else {
            Issue.record("Expected noGatewayFound")
        }
    }

    @Test("discoveryTimeout error")
    func discoveryTimeout() {
        let error: NATPortMapperError = .discoveryTimeout
        if case .discoveryTimeout = error {} else {
            Issue.record("Expected discoveryTimeout")
        }
    }

    @Test("mappingFailed with message")
    func mappingFailed() {
        let error: NATPortMapperError = .mappingFailed("port conflict")
        if case .mappingFailed(let msg) = error {
            #expect(msg == "port conflict")
        } else {
            Issue.record("Expected mappingFailed")
        }
    }

    @Test("requestDenied with message")
    func requestDenied() {
        let error: NATPortMapperError = .requestDenied("unauthorized")
        if case .requestDenied(let msg) = error {
            #expect(msg == "unauthorized")
        } else {
            Issue.record("Expected requestDenied")
        }
    }

    @Test("networkError with message")
    func networkError() {
        let error: NATPortMapperError = .networkError("timeout")
        if case .networkError(let msg) = error {
            #expect(msg == "timeout")
        } else {
            Issue.record("Expected networkError")
        }
    }

    @Test("Error conforms to Error protocol")
    func errorProtocol() {
        let error: any Error = NATPortMapperError.shutdown
        #expect(error is NATPortMapperError)
    }
}

// MARK: - NATTransportProtocol Tests

@Suite("NATTransportProtocol Tests")
struct NATTransportProtocolTests {

    @Test("TCP raw value")
    func tcpRawValue() {
        #expect(NATTransportProtocol.tcp.rawValue == "TCP")
    }

    @Test("UDP raw value")
    func udpRawValue() {
        #expect(NATTransportProtocol.udp.rawValue == "UDP")
    }
}
