/// Tests for WebRTC Transport bridge

import Testing
import Foundation
@testable import P2PTransportWebRTC
@testable import P2PCore
@testable import P2PTransport

@Suite("WebRTC Transport Tests")
struct WebRTCTransportTests {

    @Test("WebRTC transport protocol chains")
    func protocolChains() {
        let transport = WebRTCTransport()
        #expect(transport.protocols.count == 2)
        #expect(transport.protocols[0] == ["ip4", "udp", "webrtc-direct"])
        #expect(transport.protocols[1] == ["ip6", "udp", "webrtc-direct"])
    }

    @Test("Can dial WebRTC address")
    func canDialWebRTC() throws {
        let transport = WebRTCTransport()

        // Valid WebRTC Direct address
        let addr = try Multiaddr("/ip4/127.0.0.1/udp/4001/webrtc-direct/certhash/uEiAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
        #expect(transport.canDial(addr))
    }

    @Test("Cannot dial TCP address")
    func cannotDialTCP() throws {
        let transport = WebRTCTransport()
        let addr = try Multiaddr("/ip4/127.0.0.1/tcp/4001")
        #expect(!transport.canDial(addr))
    }

    @Test("Can listen on WebRTC address")
    func canListenWebRTC() throws {
        let transport = WebRTCTransport()
        let addr = try Multiaddr("/ip4/0.0.0.0/udp/4001/webrtc-direct")
        #expect(transport.canListen(addr))
    }

    @Test("Cannot dial WebRTC address without certhash")
    func cannotDialWithoutCerthash() throws {
        let transport = WebRTCTransport()

        // Without certhash the DTLS fingerprint cannot be verified
        let addr = try Multiaddr("/ip4/127.0.0.1/udp/4001/webrtc-direct")
        #expect(!transport.canDial(addr))
    }

    @Test("Cannot dial WebRTC address with non-sha256 certhash")
    func cannotDialWithWrongHashFunction() {
        let transport = WebRTCTransport()

        // sha1 (0x11, 20 bytes) instead of sha2-256 (0x12, 32 bytes)
        let sha1Hash = Data([0x11, 0x14] + Array(repeating: UInt8(0xAB), count: 20))
        let addr = Multiaddr(uncheckedProtocols: [
            .ip4("127.0.0.1"), .udp(4001), .webrtcDirect, .certhash(sha1Hash)
        ])
        #expect(!transport.canDial(addr))
    }

    @Test("Cannot dial WebRTC address with truncated certhash digest")
    func cannotDialWithTruncatedDigest() {
        let transport = WebRTCTransport()

        // Correct sha2-256 header but only 16 digest bytes
        let truncated = Data([0x12, 0x20] + Array(repeating: UInt8(0xAB), count: 16))
        let addr = Multiaddr(uncheckedProtocols: [
            .ip4("127.0.0.1"), .udp(4001), .webrtcDirect, .certhash(truncated)
        ])
        #expect(!transport.canDial(addr))
    }

    @Test("Can dial WebRTC address with trailing /p2p component")
    func canDialWithPeerIDComponent() {
        let transport = WebRTCTransport()

        let certhash = Data([0x12, 0x20] + Array(repeating: UInt8(0xAB), count: 32))
        let peer = KeyPair.generateEd25519().peerID
        let addr = Multiaddr(uncheckedProtocols: [
            .ip4("127.0.0.1"), .udp(4001), .webrtcDirect, .certhash(certhash), .p2p(peer)
        ])
        #expect(transport.canDial(addr))
    }
}

@Suite("WebRTC Multiaddr Tests")
struct WebRTCMultiaddrTests {

    @Test("Parse webrtc-direct multiaddr")
    func parseWebRTCDirect() throws {
        let addr = try Multiaddr("/ip4/192.168.1.1/udp/4001/webrtc-direct")
        #expect(addr.ipAddress == "192.168.1.1")
        #expect(addr.udpPort == 4001)

        let hasWebRTC = addr.protocols.contains {
            if case .webrtcDirect = $0 { return true }
            return false
        }
        #expect(hasWebRTC)
    }

    @Test("Parse certhash in multiaddr")
    func parseCerthash() throws {
        let addr = try Multiaddr("/ip4/127.0.0.1/udp/4001/webrtc-direct/certhash/uEiAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")

        var certhashData: Data?
        for proto in addr.protocols {
            if case .certhash(let data) = proto {
                certhashData = data
            }
        }
        #expect(certhashData != nil)
        #expect(!certhashData!.isEmpty)
    }

    @Test("WebRTC Direct factory method")
    func webrtcDirectFactory() {
        let certhash = Data([0x12, 0x20] + Array(repeating: UInt8(0xAB), count: 32))
        let addr = Multiaddr.webrtcDirect(host: "192.168.1.1", port: 4001, certhash: certhash)

        #expect(addr.ipAddress == "192.168.1.1")
        #expect(addr.udpPort == 4001)

        let hasWebRTC = addr.protocols.contains {
            if case .webrtcDirect = $0 { return true }
            return false
        }
        #expect(hasWebRTC)

        let hasCerthash = addr.protocols.contains {
            if case .certhash = $0 { return true }
            return false
        }
        #expect(hasCerthash)
    }

    @Test("WebRTC multiaddr roundtrip string encoding")
    func multiaddrStringRoundtrip() throws {
        let original = try Multiaddr("/ip4/192.168.1.1/udp/4001/webrtc-direct")
        let description = original.description
        let decoded = try Multiaddr(description)
        #expect(original == decoded)
    }

    @Test("WebRTC IPv6 address")
    func webrtcIPv6() {
        let certhash = Data([0x12, 0x20] + Array(repeating: UInt8(0), count: 32))
        let addr = Multiaddr.webrtcDirect(host: "::1", port: 4001, certhash: certhash)
        #expect(addr.ipAddress != nil)
        #expect(addr.udpPort == 4001)
    }
}
