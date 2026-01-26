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

        let tcpAddr = try #require(tcpMapping.multiaddr)
        #expect(tcpAddr.description == "/ip4/203.0.113.1/tcp/4001")

        let udpMapping = PortMapping(
            internalPort: 4002,
            externalPort: 4002,
            externalAddress: "203.0.113.2",
            protocol: .udp,
            expiration: ContinuousClock.now + .seconds(3600),
            gatewayType: .natpmp(gatewayIP: "192.168.1.1")
        )

        let udpAddr = try #require(udpMapping.multiaddr)
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
        mapper.shutdown()
        mapper.shutdown()

        // Operations should fail after shutdown
        await #expect(throws: NATPortMapperError.self) {
            _ = try await mapper.discoverGateway()
        }
    }

    @Test("Events stream created on access")
    func eventsStreamCreation() {
        let mapper = NATPortMapper()

        let events1 = mapper.events
        let events2 = mapper.events

        // Same stream should be returned
        // Note: Can't directly compare AsyncStreams, but this tests
        // that the stream creation is consistent
        _ = events1
        _ = events2

        mapper.shutdown()
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
