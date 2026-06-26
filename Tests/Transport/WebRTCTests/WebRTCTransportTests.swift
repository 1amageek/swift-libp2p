/// Tests for WebRTC Transport bridge

import Testing
import Foundation
import NIOEmbedded
import NIOPosix
@testable import WebRTC
@testable import P2PTransportWebRTC
@testable import P2PCore
@testable import P2PTransport

@Suite("WebRTC Transport Tests", .serialized)
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

    // MARK: - Port Validation (Finding 9)

    @Test("Cannot dial WebRTC address with port 0")
    func cannotDialPortZero() {
        let transport = WebRTCTransport()

        // Port 0 is not a valid dial target; it must be rejected rather than
        // silently substituted.
        let certhash = Data([0x12, 0x20] + Array(repeating: UInt8(0xAB), count: 32))
        let addr = Multiaddr(uncheckedProtocols: [
            .ip4("127.0.0.1"), .udp(0), .webrtcDirect, .certhash(certhash)
        ])
        #expect(!transport.canDial(addr))
    }

    @Test("dialSecured rejects WebRTC address with port 0")
    func dialSecuredRejectsPortZero() async {
        let transport = WebRTCTransport()
        let keyPair = KeyPair.generateEd25519()

        let certhash = Data([0x12, 0x20] + Array(repeating: UInt8(0xAB), count: 32))
        let addr = Multiaddr(uncheckedProtocols: [
            .ip4("127.0.0.1"), .udp(0), .webrtcDirect, .certhash(certhash)
        ])

        await #expect(throws: TransportError.self) {
            _ = try await transport.dialSecured(addr, localKeyPair: keyPair)
        }
    }

    @Test(
        "Inbound WebRTC capacity is enforced before raw accept",
        .timeLimit(.minutes(1)),
        .enabled(if: webRTCLiveNetworkTestsEnabled, "Set SWIFT_LIBP2P_ENABLE_LIVE_NETWORK_TESTS=1")
    )
    func inboundCapacityIsEnforcedBeforeRawAccept() async throws {
        let certificate = try WebRTCCertificate.generateSelfSigned()
        let endpoint = WebRTCEndpoint(certificate: certificate)
        try await withWebRTCTestSocket { socket in
            let rawListener = try endpoint.listen()
            let securedListener = WebRTCSecuredListener(
                listener: rawListener,
                socket: socket,
                localAddress: try Multiaddr("/ip4/127.0.0.1/udp/0/webrtc-direct"),
                localKeyPair: KeyPair.generateEd25519()
            )

            for port in 10_000..<(10_000 + 64) {
                let address = try SocketAddress(ipAddress: "127.0.0.1", port: port)
                securedListener.handleNewPeer(address)
                #expect(rawListener.connection(for: address.addressKey) != nil)
            }

            let rejectedAddress = try SocketAddress(ipAddress: "127.0.0.1", port: 10_064)
            securedListener.handleNewPeer(rejectedAddress)
            #expect(rawListener.connection(for: rejectedAddress.addressKey) == nil)

            try await securedListener.close()
        }
    }

    @Test(
        "Inbound WebRTC capacity slot is released when handshake connection closes",
        .timeLimit(.minutes(1)),
        .enabled(if: webRTCLiveNetworkTestsEnabled, "Set SWIFT_LIBP2P_ENABLE_LIVE_NETWORK_TESTS=1")
    )
    func inboundCapacitySlotReleasedAfterClose() async throws {
        let certificate = try WebRTCCertificate.generateSelfSigned()
        let endpoint = WebRTCEndpoint(certificate: certificate)
        try await withWebRTCTestSocket { socket in
            let rawListener = try endpoint.listen()
            let securedListener = WebRTCSecuredListener(
                listener: rawListener,
                socket: socket,
                localAddress: try Multiaddr("/ip4/127.0.0.1/udp/0/webrtc-direct"),
                localKeyPair: KeyPair.generateEd25519()
            )
            securedListener.startAccepting()

            var admittedAddresses: [SocketAddress] = []
            for port in 11_000..<(11_000 + 64) {
                let address = try SocketAddress(ipAddress: "127.0.0.1", port: port)
                admittedAddresses.append(address)
                securedListener.handleNewPeer(address)
                #expect(rawListener.connection(for: address.addressKey) != nil)
            }

            let firstConnection = try #require(rawListener.connection(for: admittedAddresses[0].addressKey))
            firstConnection.close()

            let replacementAddress = try SocketAddress(ipAddress: "127.0.0.1", port: 11_064)
            for _ in 0..<50 {
                securedListener.handleNewPeer(replacementAddress)
                if rawListener.connection(for: replacementAddress.addressKey) != nil {
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }

            #expect(rawListener.connection(for: replacementAddress.addressKey) != nil)
            try await securedListener.close()
        }
    }

    private func withWebRTCTestSocket<T>(
        _ body: (WebRTCUDPSocket) async throws -> T
    ) async throws -> T {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let channel = try await DatagramBootstrap(group: group)
                .bind(host: "127.0.0.1", port: 0)
                .get()
            let socket = WebRTCUDPSocket(channel: channel)
            do {
                let result = try await body(socket)
                socket.close()
                try await group.shutdownGracefully()
                return result
            } catch {
                socket.close()
                do {
                    try await group.shutdownGracefully()
                } catch {
                    Issue.record("Failed to shut down WebRTC test event loop: \(error)")
                }
                throw error
            }
        } catch {
            do {
                try await group.shutdownGracefully()
            } catch {
                Issue.record("Failed to shut down WebRTC test event loop: \(error)")
            }
            throw error
        }
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
