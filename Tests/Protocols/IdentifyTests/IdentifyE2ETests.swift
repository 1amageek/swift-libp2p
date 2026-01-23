/// IdentifyE2ETests - End-to-end tests for Identify protocol over QUIC
///
/// Tests the Identify protocol with actual QUIC network connections.

import Testing
import Foundation
@testable import P2PIdentify
@testable import P2PTransportQUIC
@testable import P2PTransport
@testable import P2PCore
@testable import P2PMux

@Suite("Identify E2E Tests")
struct IdentifyE2ETests {

    // MARK: - Basic Connectivity Test (known working pattern)

    @Test("Simple bidirectional stream test", .timeLimit(.minutes(1)))
    func simpleBidirectionalStream() async throws {
        let serverKeyPair = KeyPair.generateEd25519()
        let clientKeyPair = KeyPair.generateEd25519()
        let transport = QUICTransport()

        // Start server
        let listener = try await transport.listenSecured(
            try Multiaddr("/ip4/127.0.0.1/udp/0/quic-v1"),
            localKeyPair: serverKeyPair
        )

        // Accept and handle in background - EXACT same pattern as QUICE2ETests
        let serverTask = Task { () -> (any MuxedConnection)? in
            for await serverConnection in listener.connections {
                // Accept stream from client
                let stream = try await serverConnection.acceptStream()

                // Read data
                let received = try await stream.read()

                // Echo back with modification
                try await stream.write(received + Data(" - echoed".utf8))

                // Close write side
                try await stream.closeWrite()

                return serverConnection
            }
            return nil
        }

        // Client connects and sends data
        let clientConnection = try await transport.dialSecured(
            listener.localAddress,
            localKeyPair: clientKeyPair
        )

        // Open stream
        let clientStream = try await clientConnection.newStream()

        // Send data
        let testData = Data("Hello QUIC".utf8)
        try await clientStream.write(testData)
        try await clientStream.closeWrite()

        // Read response
        let response = try await clientStream.read()
        #expect(response == Data("Hello QUIC - echoed".utf8))

        // Cleanup
        let serverConnection = try? await serverTask.value
        try await clientStream.close()
        try await clientConnection.close()
        try? await serverConnection?.close()
        try await listener.close()
    }

    // MARK: - Protobuf Tests

    @Test("Identify Protobuf roundtrip", .timeLimit(.minutes(1)))
    func identifyProtobufRoundtrip() throws {
        let keyPair = KeyPair.generateEd25519()

        let originalInfo = IdentifyInfo(
            publicKey: keyPair.publicKey,
            listenAddresses: [
                try Multiaddr("/ip4/127.0.0.1/udp/4001/quic-v1"),
                try Multiaddr("/ip4/0.0.0.0/tcp/4001")
            ],
            protocols: ["/ipfs/id/1.0.0", "/ipfs/ping/1.0.0", "/meshsub/1.1.0"],
            observedAddress: try Multiaddr("/ip4/1.2.3.4/udp/12345/quic-v1"),
            protocolVersion: "ipfs/0.1.0",
            agentVersion: "swift-libp2p/0.1.0",
            signedPeerRecord: nil
        )

        // Encode
        let encoded = try IdentifyProtobuf.encode(originalInfo)

        // Decode
        let decoded = try IdentifyProtobuf.decode(encoded)

        // Verify all fields
        #expect(decoded.publicKey == originalInfo.publicKey)
        #expect(decoded.listenAddresses == originalInfo.listenAddresses)
        #expect(decoded.protocols == originalInfo.protocols)
        #expect(decoded.observedAddress == originalInfo.observedAddress)
        #expect(decoded.protocolVersion == originalInfo.protocolVersion)
        #expect(decoded.agentVersion == originalInfo.agentVersion)
    }

    // MARK: - QUIC E2E Tests

    @Test("Identify protocol wire format over QUIC", .timeLimit(.minutes(1)))
    func identifyWireFormat() async throws {
        let serverKeyPair = KeyPair.generateEd25519()
        let clientKeyPair = KeyPair.generateEd25519()
        let transport = QUICTransport()

        // Start server
        let listener = try await transport.listenSecured(
            try Multiaddr("/ip4/127.0.0.1/udp/0/quic-v1"),
            localKeyPair: serverKeyPair
        )
        let serverAddress = listener.localAddress

        // Server task: accept connection and send identify response
        let serverTask = Task { () -> (any MuxedConnection)? in
            for await serverConnection in listener.connections {
                // Accept stream from client
                let stream = try await serverConnection.acceptStream()

                // Build server's identify info
                let serverInfo = IdentifyInfo(
                    publicKey: serverKeyPair.publicKey,
                    listenAddresses: [serverAddress],
                    protocols: ["/ipfs/id/1.0.0", "/ipfs/ping/1.0.0"],
                    observedAddress: nil,
                    protocolVersion: "ipfs/0.1.0",
                    agentVersion: "swift-libp2p-test/1.0.0",
                    signedPeerRecord: nil
                )

                // Encode and send response
                let data = try IdentifyProtobuf.encode(serverInfo)
                try await stream.write(data)
                try await stream.closeWrite()

                return serverConnection
            }
            return nil
        }

        // Client: connect and request identify
        let clientConn = try await transport.dialSecured(
            serverAddress,
            localKeyPair: clientKeyPair
        )

        // Open stream for identify request
        let stream = try await clientConn.newStream()

        // Send empty request to trigger server-side stream accept
        try await stream.write(Data())
        try await stream.closeWrite()

        // Read server's identify response
        let receivedData = try await stream.read()

        // Decode the response
        let receivedInfo = try IdentifyProtobuf.decode(receivedData)

        // Verify the received info
        #expect(receivedInfo.publicKey == serverKeyPair.publicKey)
        #expect(receivedInfo.agentVersion == "swift-libp2p-test/1.0.0")
        #expect(receivedInfo.protocolVersion == "ipfs/0.1.0")
        #expect(receivedInfo.protocols.contains("/ipfs/id/1.0.0"))
        #expect(receivedInfo.protocols.contains("/ipfs/ping/1.0.0"))

        // Cleanup
        let serverConn = try? await serverTask.value
        try await stream.close()
        try await clientConn.close()
        try? await serverConn?.close()
        try await listener.close()
    }

    @Test("Identify returns correct public key", .timeLimit(.minutes(1)))
    func identifyPublicKey() async throws {
        let serverKeyPair = KeyPair.generateEd25519()
        let clientKeyPair = KeyPair.generateEd25519()
        let transport = QUICTransport()

        let listener = try await transport.listenSecured(
            try Multiaddr("/ip4/127.0.0.1/udp/0/quic-v1"),
            localKeyPair: serverKeyPair
        )

        // Server handler
        let serverTask = Task { () -> (any MuxedConnection)? in
            for await serverConnection in listener.connections {
                let stream = try await serverConnection.acceptStream()

                let info = IdentifyInfo(
                    publicKey: serverKeyPair.publicKey,
                    listenAddresses: [],
                    protocols: [],
                    observedAddress: nil,
                    protocolVersion: nil,
                    agentVersion: nil,
                    signedPeerRecord: nil
                )
                try await stream.write(try IdentifyProtobuf.encode(info))
                try await stream.closeWrite()

                return serverConnection
            }
            return nil
        }

        // Client request
        let clientConn = try await transport.dialSecured(
            listener.localAddress,
            localKeyPair: clientKeyPair
        )

        let stream = try await clientConn.newStream()

        // Send empty request to trigger server-side stream accept
        try await stream.write(Data())
        try await stream.closeWrite()

        let data = try await stream.read()
        let info = try IdentifyProtobuf.decode(data)

        // Verify public key matches and derives correct PeerID
        #expect(info.publicKey == serverKeyPair.publicKey)
        if let publicKey = info.publicKey {
            let derivedPeerID = PeerID(publicKey: publicKey)
            #expect(derivedPeerID == serverKeyPair.peerID)
        }

        // Cleanup
        let serverConn = try? await serverTask.value
        try await stream.close()
        try await clientConn.close()
        try? await serverConn?.close()
        try await listener.close()
    }

    @Test("Identify with multiple listen addresses", .timeLimit(.minutes(1)))
    func identifyMultipleAddresses() async throws {
        let serverKeyPair = KeyPair.generateEd25519()
        let clientKeyPair = KeyPair.generateEd25519()
        let transport = QUICTransport()

        let listener = try await transport.listenSecured(
            try Multiaddr("/ip4/127.0.0.1/udp/0/quic-v1"),
            localKeyPair: serverKeyPair
        )

        let listenAddrs = [
            try Multiaddr("/ip4/127.0.0.1/udp/4001/quic-v1"),
            try Multiaddr("/ip4/192.168.1.1/udp/4001/quic-v1"),
            try Multiaddr("/ip6/::1/udp/4001/quic-v1")
        ]

        // Server handler
        let serverTask = Task { () -> (any MuxedConnection)? in
            for await serverConnection in listener.connections {
                let stream = try await serverConnection.acceptStream()

                let info = IdentifyInfo(
                    publicKey: serverKeyPair.publicKey,
                    listenAddresses: listenAddrs,
                    protocols: ["/ipfs/id/1.0.0"],
                    observedAddress: nil,
                    protocolVersion: "ipfs/0.1.0",
                    agentVersion: "swift-libp2p/0.1.0",
                    signedPeerRecord: nil
                )
                try await stream.write(try IdentifyProtobuf.encode(info))
                try await stream.closeWrite()

                return serverConnection
            }
            return nil
        }

        // Client request
        let clientConn = try await transport.dialSecured(
            listener.localAddress,
            localKeyPair: clientKeyPair
        )

        let stream = try await clientConn.newStream()

        // Send empty request to trigger server-side stream accept
        try await stream.write(Data())
        try await stream.closeWrite()

        let data = try await stream.read()
        let info = try IdentifyProtobuf.decode(data)

        // Verify all listen addresses are present
        #expect(info.listenAddresses.count == 3)
        #expect(info.listenAddresses.contains(listenAddrs[0]))
        #expect(info.listenAddresses.contains(listenAddrs[1]))
        #expect(info.listenAddresses.contains(listenAddrs[2]))

        // Cleanup
        let serverConn = try? await serverTask.value
        try await stream.close()
        try await clientConn.close()
        try? await serverConn?.close()
        try await listener.close()
    }
}
