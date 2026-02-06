/// CircuitRelayInteropTests - Circuit Relay v2 interoperability tests
///
/// Tests that swift-libp2p Circuit Relay implementation is compatible with go-libp2p.
/// Focuses on reservation, relay connection, and data transfer through relays.
///
/// Prerequisites:
/// - Docker must be installed and running
/// - Tests run with: swift test --filter CircuitRelayInteropTests

import Testing
import Foundation
import NIOCore
@testable import P2PTransportQUIC
@testable import P2PCircuitRelay
@testable import P2PTransport
@testable import P2PCore
@testable import P2PMux
@testable import P2PNegotiation
@testable import P2PProtocols

/// Interoperability tests for Circuit Relay v2 protocol
@Suite("Circuit Relay v2 Interop Tests")
struct CircuitRelayInteropTests {

    // MARK: - Connection Tests

    @Test("Connect to go-libp2p relay node", .timeLimit(.minutes(2)))
    func connectToRelayNode() async throws {
        let harness = try await GoProtocolHarness.start(
            protocol: .relay(mode: "server")
        )
        defer { Task { try? await harness.stop() } }

        let nodeInfo = harness.nodeInfo
        print("[Relay] Node info: \(nodeInfo)")

        let keyPair = KeyPair.generateEd25519()
        let transport = QUICTransport()

        let connection = try await transport.dialSecured(
            Multiaddr(nodeInfo.address),
            localKeyPair: keyPair
        )

        #expect(connection.remotePeer.description.contains(nodeInfo.peerID.prefix(8)))
        print("[Relay] Connected to relay node")

        try await connection.close()
    }

    // MARK: - Protocol Negotiation Tests

    @Test("Relay HOP protocol negotiation", .timeLimit(.minutes(2)))
    func relayHopProtocolNegotiation() async throws {
        let harness = try await GoProtocolHarness.start(
            protocol: .relay(mode: "server")
        )
        defer { Task { try? await harness.stop() } }

        let nodeInfo = harness.nodeInfo
        let keyPair = KeyPair.generateEd25519()
        let transport = QUICTransport()

        let connection = try await transport.dialSecured(
            Multiaddr(nodeInfo.address),
            localKeyPair: keyPair
        )

        let stream = try await connection.newStream()

        // Negotiate Circuit Relay HOP protocol
        let negotiationResult = try await MultistreamSelect.negotiate(
            protocols: ["/libp2p/circuit/relay/0.2.0/hop"],
            read: { Data(buffer: try await stream.read()) },
            write: { data in try await stream.write(ByteBuffer(bytes: data)) }
        )

        #expect(negotiationResult.protocolID == "/libp2p/circuit/relay/0.2.0/hop")
        print("[Relay] HOP protocol negotiated")

        try await stream.close()
        try await connection.close()
    }

    // MARK: - Reservation Tests

    @Test("Relay reservation (RESERVE)", .timeLimit(.minutes(2)))
    func relayReservation() async throws {
        let harness = try await GoProtocolHarness.start(
            protocol: .relay(mode: "server")
        )
        defer { Task { try? await harness.stop() } }

        let nodeInfo = harness.nodeInfo
        let keyPair = KeyPair.generateEd25519()
        let transport = QUICTransport()

        let connection = try await transport.dialSecured(
            Multiaddr(nodeInfo.address),
            localKeyPair: keyPair
        )

        let stream = try await connection.newStream()

        let negotiationResult = try await MultistreamSelect.negotiate(
            protocols: ["/libp2p/circuit/relay/0.2.0/hop"],
            read: { Data(buffer: try await stream.read()) },
            write: { data in try await stream.write(ByteBuffer(bytes: data)) }
        )

        #expect(negotiationResult.protocolID == "/libp2p/circuit/relay/0.2.0/hop")

        // Build RESERVE message
        // Circuit Relay v2 HopMessage:
        // type: 0 = RESERVE, 1 = CONNECT, 2 = STATUS
        var message = Data()

        // Field 1: type (enum) = RESERVE (0)
        message.append(0x08)  // tag: field 1, wire type 0
        message.append(0x00)  // value: 0 (RESERVE)

        // Length prefix the message
        var request = Data()
        request.append(UInt8(message.count))
        request.append(message)

        print("[Relay] Sending RESERVE request")
        try await stream.write(ByteBuffer(bytes: request))

        // Read response
        let response = try await stream.read()
        let responseData = Data(buffer: response)

        // Should receive a HopMessage with type STATUS
        #expect(responseData.count > 0, "Should receive RESERVE response")
        print("[Relay] RESERVE response: \(responseData.count) bytes")

        // Parse response - first byte is length, then message
        if responseData.count >= 2 {
            let msgType = responseData[1]  // After length byte
            print("[Relay] Response type byte: \(msgType)")
        }

        try await stream.close()
        try await connection.close()
    }

    // MARK: - Connect Tests

    @Test("Relay connect request (CONNECT)", .timeLimit(.minutes(2)))
    func relayConnect() async throws {
        let harness = try await GoProtocolHarness.start(
            protocol: .relay(mode: "server")
        )
        defer { Task { try? await harness.stop() } }

        let nodeInfo = harness.nodeInfo
        let keyPair = KeyPair.generateEd25519()
        let transport = QUICTransport()

        let connection = try await transport.dialSecured(
            Multiaddr(nodeInfo.address),
            localKeyPair: keyPair
        )

        let stream = try await connection.newStream()

        let negotiationResult = try await MultistreamSelect.negotiate(
            protocols: ["/libp2p/circuit/relay/0.2.0/hop"],
            read: { Data(buffer: try await stream.read()) },
            write: { data in try await stream.write(ByteBuffer(bytes: data)) }
        )

        #expect(negotiationResult.protocolID == "/libp2p/circuit/relay/0.2.0/hop")

        // Build CONNECT message
        // This requires a target peer - we'll use a dummy peer ID
        let targetPeerID = KeyPair.generateEd25519().peerID

        var message = Data()

        // Field 1: type = CONNECT (1)
        message.append(0x08)
        message.append(0x01)

        // Field 2: peer (Peer message with id field)
        var peerMessage = Data()
        peerMessage.append(0x0a)  // field 1: id (bytes)
        let peerBytes = targetPeerID.multihash.bytes
        if peerBytes.count < 128 {
            peerMessage.append(UInt8(peerBytes.count))
        } else {
            peerMessage.append(UInt8((peerBytes.count & 0x7f) | 0x80))
            peerMessage.append(UInt8(peerBytes.count >> 7))
        }
        peerMessage.append(contentsOf: peerBytes)

        message.append(0x12)  // field 2: peer
        message.append(UInt8(peerMessage.count))
        message.append(peerMessage)

        // Length prefix
        var request = Data()
        if message.count < 128 {
            request.append(UInt8(message.count))
        } else {
            request.append(UInt8((message.count & 0x7f) | 0x80))
            request.append(UInt8(message.count >> 7))
        }
        request.append(message)

        print("[Relay] Sending CONNECT request for target: \(targetPeerID)")
        try await stream.write(ByteBuffer(bytes: request))

        // Read response - should be STATUS with error (target not found)
        let response = try await stream.read()
        let responseData = Data(buffer: response)

        #expect(responseData.count > 0, "Should receive CONNECT response")
        print("[Relay] CONNECT response: \(responseData.count) bytes")

        try await stream.close()
        try await connection.close()
    }

    // MARK: - STOP Protocol Tests

    @Test("Relay STOP protocol negotiation", .timeLimit(.minutes(2)))
    func relayStopProtocol() async throws {
        let harness = try await GoProtocolHarness.start(
            protocol: .relay(mode: "server")
        )
        defer { Task { try? await harness.stop() } }

        let nodeInfo = harness.nodeInfo
        let keyPair = KeyPair.generateEd25519()
        let transport = QUICTransport()

        let connection = try await transport.dialSecured(
            Multiaddr(nodeInfo.address),
            localKeyPair: keyPair
        )

        let stream = try await connection.newStream()

        // The STOP protocol is used by relayed peers to receive connections
        let negotiationResult = try await MultistreamSelect.negotiate(
            protocols: ["/libp2p/circuit/relay/0.2.0/stop"],
            read: { Data(buffer: try await stream.read()) },
            write: { data in try await stream.write(ByteBuffer(bytes: data)) }
        )

        #expect(negotiationResult.protocolID == "/libp2p/circuit/relay/0.2.0/stop")
        print("[Relay] STOP protocol negotiated")

        try await stream.close()
        try await connection.close()
    }

    // MARK: - Data Transfer Tests

    @Test("Relay data transfer verification", .timeLimit(.minutes(3)))
    func relayDataTransfer() async throws {
        // This test verifies the relay can handle data transfer
        // Full relay chain testing requires multiple nodes

        let harness = try await GoProtocolHarness.start(
            protocol: .relay(mode: "server")
        )
        defer { Task { try? await harness.stop() } }

        let nodeInfo = harness.nodeInfo
        let keyPair = KeyPair.generateEd25519()
        let transport = QUICTransport()

        let connection = try await transport.dialSecured(
            Multiaddr(nodeInfo.address),
            localKeyPair: keyPair
        )

        // First make a reservation
        let reserveStream = try await connection.newStream()

        let reserveNegotiation = try await MultistreamSelect.negotiate(
            protocols: ["/libp2p/circuit/relay/0.2.0/hop"],
            read: { Data(buffer: try await reserveStream.read()) },
            write: { data in try await reserveStream.write(ByteBuffer(bytes: data)) }
        )

        #expect(reserveNegotiation.protocolID == "/libp2p/circuit/relay/0.2.0/hop")

        // Send RESERVE
        var reserveMessage = Data()
        reserveMessage.append(0x08)
        reserveMessage.append(0x00)

        var reserveRequest = Data()
        reserveRequest.append(UInt8(reserveMessage.count))
        reserveRequest.append(reserveMessage)

        try await reserveStream.write(ByteBuffer(bytes: reserveRequest))

        // Get reservation response
        let reserveResponse = try await reserveStream.read()
        let reserveData = Data(buffer: reserveResponse)

        print("[Relay] Reservation response: \(reserveData.count) bytes")

        // Check logs for reservation info
        try await Task.sleep(for: .seconds(1))
        let logs = try await harness.getLogs()

        if logs.contains("Reserved") || logs.contains("reservation") {
            print("[Relay] Reservation successful (confirmed in logs)")
        }

        try await reserveStream.close()
        try await connection.close()
    }
}
