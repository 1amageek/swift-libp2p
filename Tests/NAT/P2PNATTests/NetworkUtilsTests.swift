/// NetworkUtilsTests - Tests for XML extraction and network utilities
import Testing
import Foundation
@testable import P2PNAT

@Suite("NetworkUtils Tests")
struct NetworkUtilsTests {

    // MARK: - XML Tag Value Extraction

    @Test("extractXMLTagValue extracts tag content")
    func extractTagContent() {
        let xml = "<root><Name>value</Name></root>"
        #expect(extractXMLTagValue(named: "Name", from: xml) == "value")
    }

    @Test("extractXMLTagValue returns nil for missing tag")
    func extractTagMissing() {
        let xml = "<root><Other>value</Other></root>"
        #expect(extractXMLTagValue(named: "Name", from: xml) == nil)
    }

    @Test("extractXMLTagValue handles nested XML")
    func extractTagNested() {
        let xml = """
            <root>
                <service>
                    <serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType>
                    <controlURL>/ctl/IPConn</controlURL>
                </service>
            </root>
            """
        #expect(extractXMLTagValue(named: "controlURL", from: xml) == "/ctl/IPConn")
        #expect(extractXMLTagValue(named: "serviceType", from: xml) == "urn:schemas-upnp-org:service:WANIPConnection:1")
    }

    @Test("extractXMLTagValue handles IP address in tag")
    func extractTagIPAddress() {
        let xml = "<NewExternalIPAddress>203.0.113.1</NewExternalIPAddress>"
        #expect(extractXMLTagValue(named: "NewExternalIPAddress", from: xml) == "203.0.113.1")
    }

    @Test("extractXMLTagValue returns nil for empty tag")
    func extractTagEmpty() {
        let xml = "<Name></Name>"
        #expect(extractXMLTagValue(named: "Name", from: xml) == nil)
    }

    @Test("extractXMLTagValue returns nil for empty string")
    func extractFromEmptyString() {
        #expect(extractXMLTagValue(named: "Name", from: "") == nil)
    }

    // MARK: - Service Block Extraction

    @Test("extractServiceBlock finds matching service block")
    func extractServiceBlockMatching() {
        let xml = """
            <root>
                <service>
                    <serviceType>urn:schemas-upnp-org:service:WANCommonInterfaceConfig:1</serviceType>
                    <controlURL>/ctl/CommonIfCfg</controlURL>
                </service>
                <service>
                    <serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType>
                    <controlURL>/ctl/IPConn</controlURL>
                </service>
            </root>
            """
        let block = extractServiceBlock(containing: "WANIPConnection", from: xml)
        #expect(block != nil)
        #expect(block!.contains("WANIPConnection"))
        #expect(block!.contains("/ctl/IPConn"))
        // Must NOT contain the other service's controlURL
        #expect(!block!.contains("/ctl/CommonIfCfg"))
    }

    @Test("extractServiceBlock returns nil when no match")
    func extractServiceBlockNoMatch() {
        let xml = """
            <root>
                <service>
                    <serviceType>urn:schemas-upnp-org:service:WANCommonInterfaceConfig:1</serviceType>
                    <controlURL>/ctl/CommonIfCfg</controlURL>
                </service>
            </root>
            """
        #expect(extractServiceBlock(containing: "WANIPConnection", from: xml) == nil)
    }

    @Test("extractServiceBlock returns nil for empty XML")
    func extractServiceBlockEmpty() {
        #expect(extractServiceBlock(containing: "test", from: "") == nil)
    }

    @Test("extractServiceBlock scopes controlURL correctly")
    func extractServiceBlockScoping() {
        // Two services with different controlURLs — extraction must pick the right one
        let xml = """
            <device>
                <service>
                    <serviceType>urn:schemas-upnp-org:service:WANCommonInterfaceConfig:1</serviceType>
                    <controlURL>/ctl/wrong</controlURL>
                </service>
                <service>
                    <serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType>
                    <controlURL>/ctl/correct</controlURL>
                </service>
            </device>
            """
        let block = extractServiceBlock(
            containing: "urn:schemas-upnp-org:service:WANIPConnection:1",
            from: xml
        )
        #expect(block != nil)
        let controlURL = extractXMLTagValue(named: "controlURL", from: block!)
        #expect(controlURL == "/ctl/correct")
    }

    // MARK: - UDPSocket

    @Test("UDPSocket creates successfully")
    func udpSocketCreates() throws {
        // Should not throw
        let _ = try UDPSocket()
    }
}
