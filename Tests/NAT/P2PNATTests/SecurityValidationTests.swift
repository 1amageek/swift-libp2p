/// SecurityValidationTests - DoS / SSRF / spoofing hardening for NAT layer.
import Testing
import Foundation
@testable import P2PNAT

// MARK: - IP Address Validation

@Suite("IPAddressValidator Tests")
struct IPAddressValidatorTests {

    @Test("parses valid IPv4 to 4 bytes")
    func parseIPv4() throws {
        let bytes = try #require(IPAddressValidator.parse("192.168.1.1"))
        #expect(bytes == [192, 168, 1, 1])
    }

    @Test("parses valid IPv6 to 16 bytes")
    func parseIPv6() throws {
        let bytes = try #require(IPAddressValidator.parse("::1"))
        #expect(bytes.count == 16)
        #expect(bytes.last == 1)
    }

    @Test("rejects hostnames (no DNS resolution)")
    func rejectHostname() {
        #expect(IPAddressValidator.parse("example.com") == nil)
        #expect(IPAddressValidator.parse("router.local") == nil)
    }

    @Test("classifies RFC1918 private ranges")
    func classifyPrivate() {
        #expect(IPAddressValidator.classify("10.0.0.1") == .privateRange)
        #expect(IPAddressValidator.classify("172.16.5.4") == .privateRange)
        #expect(IPAddressValidator.classify("172.31.255.255") == .privateRange)
        #expect(IPAddressValidator.classify("192.168.0.1") == .privateRange)
        // 172.32 is NOT private
        #expect(IPAddressValidator.classify("172.32.0.1") == .global)
    }

    @Test("classifies link-local incl. metadata endpoint")
    func classifyLinkLocal() {
        #expect(IPAddressValidator.classify("169.254.1.1") == .linkLocal)
        #expect(IPAddressValidator.classify("169.254.169.254") == .linkLocal)
        #expect(IPAddressValidator.classify("fe80::1") == .linkLocal)
    }

    @Test("classifies loopback / unspecified / multicast / cgnat")
    func classifySpecial() {
        #expect(IPAddressValidator.classify("127.0.0.1") == .loopback)
        #expect(IPAddressValidator.classify("0.0.0.0") == .unspecified)
        #expect(IPAddressValidator.classify("224.0.0.1") == .multicast)
        #expect(IPAddressValidator.classify("239.255.255.250") == .multicast)
        #expect(IPAddressValidator.classify("100.64.0.1") == .cgnat)
    }

    @Test("classifies public addresses as global")
    func classifyGlobal() {
        #expect(IPAddressValidator.classify("8.8.8.8") == .global)
        #expect(IPAddressValidator.classify("203.0.113.1") == .global)
        #expect(IPAddressValidator.classify("2606:4700:4700::1111") == .global)
    }

    @Test("isLANAddress accepts only private / link-local")
    func lanAddress() {
        #expect(IPAddressValidator.isLANAddress("192.168.1.1"))
        #expect(IPAddressValidator.isLANAddress("10.1.2.3"))
        #expect(IPAddressValidator.isLANAddress("169.254.1.1"))
        #expect(!IPAddressValidator.isLANAddress("8.8.8.8"))
        #expect(!IPAddressValidator.isLANAddress("127.0.0.1"))
        #expect(!IPAddressValidator.isLANAddress("0.0.0.0"))
    }

    @Test("isRoutableExternalAddress rejects bogons")
    func routableExternal() {
        #expect(IPAddressValidator.isRoutableExternalAddress("203.0.113.7"))
        #expect(!IPAddressValidator.isRoutableExternalAddress("0.0.0.0"))
        #expect(!IPAddressValidator.isRoutableExternalAddress("127.0.0.1"))
        #expect(!IPAddressValidator.isRoutableExternalAddress("192.168.1.1"))
        #expect(!IPAddressValidator.isRoutableExternalAddress("169.254.169.254"))
        #expect(!IPAddressValidator.isRoutableExternalAddress("224.0.0.1"))
        #expect(!IPAddressValidator.isRoutableExternalAddress("100.64.0.1"))
    }
}

// MARK: - UPnP Gateway URL Validation (SSRF)

@Suite("UPnP Gateway URL Validation Tests")
struct UPnPGatewayURLValidationTests {

    @Test("accepts http URL to LAN host")
    func acceptsLANHost() throws {
        try UPnPHandler.validateGatewayURL(URL(string: "http://192.168.1.1:1900/desc.xml")!)
        try UPnPHandler.validateGatewayURL(URL(string: "http://10.0.0.1/rootDesc.xml")!)
    }

    @Test("rejects cloud metadata endpoint (169.254.169.254)")
    func rejectsMetadataEndpoint() {
        #expect(throws: NATPortMapperError.self) {
            try UPnPHandler.validateGatewayURL(URL(string: "http://169.254.169.254/latest/meta-data/")!)
        }
    }

    @Test("rejects public host")
    func rejectsPublicHost() {
        #expect(throws: NATPortMapperError.self) {
            try UPnPHandler.validateGatewayURL(URL(string: "http://8.8.8.8/desc.xml")!)
        }
        #expect(throws: NATPortMapperError.self) {
            try UPnPHandler.validateGatewayURL(URL(string: "http://203.0.113.1/desc.xml")!)
        }
    }

    @Test("rejects file:// scheme")
    func rejectsFileScheme() {
        #expect(throws: NATPortMapperError.self) {
            try UPnPHandler.validateGatewayURL(URL(string: "file:///etc/passwd")!)
        }
    }

    @Test("rejects https (non-http) scheme")
    func rejectsHTTPS() {
        #expect(throws: NATPortMapperError.self) {
            try UPnPHandler.validateGatewayURL(URL(string: "https://192.168.1.1/desc.xml")!)
        }
    }

    @Test("rejects DNS hostname (no resolution allowed)")
    func rejectsHostname() {
        #expect(throws: NATPortMapperError.self) {
            try UPnPHandler.validateGatewayURL(URL(string: "http://router.local/desc.xml")!)
        }
        #expect(throws: NATPortMapperError.self) {
            try UPnPHandler.validateGatewayURL(URL(string: "http://attacker.example.com/desc.xml")!)
        }
    }

    @Test("rejects loopback host")
    func rejectsLoopback() {
        #expect(throws: NATPortMapperError.self) {
            try UPnPHandler.validateGatewayURL(URL(string: "http://127.0.0.1/desc.xml")!)
        }
    }
}

// MARK: - UPnP Service Type Allowlist + XML Escaping (SOAP injection)

@Suite("UPnP SOAP Injection Tests")
struct UPnPSOAPInjectionTests {

    @Test("service type allowlist accepts known URNs")
    func serviceTypeAllowlistAccepts() throws {
        try UPnPHandler.validateServiceType("urn:schemas-upnp-org:service:WANIPConnection:1")
        try UPnPHandler.validateServiceType("urn:schemas-upnp-org:service:WANPPPConnection:1")
    }

    @Test("service type allowlist rejects injected URN")
    func serviceTypeAllowlistRejects() {
        #expect(throws: NATPortMapperError.self) {
            try UPnPHandler.validateServiceType("\"><inject>evil</inject>")
        }
        #expect(throws: NATPortMapperError.self) {
            try UPnPHandler.validateServiceType("urn:schemas-upnp-org:service:Evil:1")
        }
    }

    @Test("xmlEscape neutralizes injection characters")
    func xmlEscape() {
        let dangerous = "</NewPortMappingDescription><evil>&\"'"
        let escaped = UPnPHandler.xmlEscape(dangerous)
        #expect(!escaped.contains("<evil>"))
        #expect(!escaped.contains("</NewPortMappingDescription>"))
        #expect(escaped.contains("&lt;"))
        #expect(escaped.contains("&gt;"))
        #expect(escaped.contains("&amp;"))
        #expect(escaped.contains("&quot;"))
        #expect(escaped.contains("&apos;"))
    }

    @Test("xmlEscape leaves benign values intact")
    func xmlEscapeBenign() {
        #expect(UPnPHandler.xmlEscape("libp2p") == "libp2p")
        #expect(UPnPHandler.xmlEscape("192.168.1.10") == "192.168.1.10")
    }
}

// MARK: - Lifetime Clamping (renewal hot-loop prevention)

@Suite("NAT Lifetime Clamp Tests")
struct NATLifetimeClampTests {

    @Test("lifetime 0 is clamped up to the floor (no hot-loop)")
    func zeroLifetimeClamped() {
        let config = NATPortMapperConfiguration(
            minLeaseLifetime: .seconds(60),
            maxLeaseLifetime: .seconds(86400)
        )
        let clamped = config.clampedLifetime(seconds: 0)
        #expect(clamped == .seconds(60))
    }

    @Test("excessive lifetime is clamped down to the ceiling")
    func excessiveLifetimeClamped() {
        let config = NATPortMapperConfiguration(
            minLeaseLifetime: .seconds(60),
            maxLeaseLifetime: .seconds(3600)
        )
        let clamped = config.clampedLifetime(seconds: 999_999)
        #expect(clamped == .seconds(3600))
    }

    @Test("in-range lifetime is preserved")
    func inRangeLifetime() {
        let config = NATPortMapperConfiguration(
            minLeaseLifetime: .seconds(60),
            maxLeaseLifetime: .seconds(86400)
        )
        let clamped = config.clampedLifetime(seconds: 1800)
        #expect(clamped == .seconds(1800))
    }
}

// MARK: - PCP Response Validation

@Suite("PCP Validation Tests")
struct PCPValidationTests {

    /// Builds a minimal 4-byte PCP ANNOUNCE response with the given result code.
    private func announceResponse(version: UInt8 = 2, resultCode: UInt8) -> [UInt8] {
        [version, 0x80, 0, resultCode]
    }

    @Test("ANNOUNCE result code 0 (SUCCESS) is accepted")
    func announceSuccessAccepted() throws {
        try PCPHandler.validateAnnounceResponse(announceResponse(resultCode: 0))
    }

    @Test("ANNOUNCE result code 1 (UNSUPP_VERSION) is rejected")
    func announceUnsuppVersionRejected() {
        #expect(throws: NATPortMapperError.self) {
            try PCPHandler.validateAnnounceResponse(announceResponse(resultCode: 1))
        }
    }

    @Test("ANNOUNCE with other error codes is rejected")
    func announceErrorRejected() {
        for code: UInt8 in [2, 3, 8, 13] {
            #expect(throws: NATPortMapperError.self) {
                try PCPHandler.validateAnnounceResponse(announceResponse(resultCode: code))
            }
        }
    }

    /// Builds a 60-byte PCP MAP/PEER response advertising the given IPv4-mapped
    /// external address at offset 44.
    private func mapResponse(
        version: UInt8 = 2,
        resultCode: UInt8 = 0,
        externalIPv4: (UInt8, UInt8, UInt8, UInt8)
    ) -> [UInt8] {
        var r = [UInt8](repeating: 0, count: 60)
        r[0] = version
        r[3] = resultCode
        // IPv4-mapped IPv6 at offset 44: 0...0, ff, ff, a, b, c, d
        r[54] = 0xFF
        r[55] = 0xFF
        r[56] = externalIPv4.0
        r[57] = externalIPv4.1
        r[58] = externalIPv4.2
        r[59] = externalIPv4.3
        return r
    }

    @Test("external address: routable public IP is accepted")
    func externalPublicAccepted() throws {
        let handler = PCPHandler()
        let response = mapResponse(externalIPv4: (203, 0, 113, 5))
        let addr = try handler.parseExternalAddress(from: response)
        #expect(addr == "203.0.113.5")
    }

    @Test("external address: bogus 0.0.0.0 is rejected")
    func externalUnspecifiedRejected() {
        let handler = PCPHandler()
        let response = mapResponse(externalIPv4: (0, 0, 0, 0))
        #expect(throws: NATPortMapperError.self) {
            _ = try handler.parseExternalAddress(from: response)
        }
    }

    @Test("external address: private IP is rejected as bogon")
    func externalPrivateRejected() {
        let handler = PCPHandler()
        let response = mapResponse(externalIPv4: (192, 168, 1, 1))
        #expect(throws: NATPortMapperError.self) {
            _ = try handler.parseExternalAddress(from: response)
        }
    }

    @Test("external address: error result code is rejected")
    func externalErrorRejected() {
        let handler = PCPHandler()
        let response = mapResponse(resultCode: 3, externalIPv4: (203, 0, 113, 5))
        #expect(throws: NATPortMapperError.self) {
            _ = try handler.parseExternalAddress(from: response)
        }
    }
}
