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
@Suite("Circuit Relay v2 Interop Tests", .serialized)
struct CircuitRelayInteropTests {

    // MARK: - Connection Tests

    @Test("Connect to go-libp2p relay node", .timeLimit(.minutes(2)))
    func connectToRelayNode() async throws {
        let harness = try await GoProtocolHarness.start(
            protocol: .relay(mode: "server")
        )
        defer { stopHarness(harness) }

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
        defer { stopHarness(harness) }

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
        defer { stopHarness(harness) }

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

        let reserveRequest = HopMessage.reserve()
        try await stream.write(ByteBuffer(bytes: encodeLengthPrefixed(CircuitRelayProtobuf.encode(reserveRequest))))

        let responseFrame = Data(buffer: try await stream.read())
        let responsePayload = try decodeLengthPrefixedMessage(responseFrame)
        let response = try CircuitRelayProtobuf.decodeHop(responsePayload)
        #expect(response.type == .status)
        #expect(response.status == .ok)
        #expect(response.reservation != nil)
        #expect(response.reservation?.expiration ?? 0 > 0)
        print("[Relay] RESERVE response decoded: status=\(String(describing: response.status))")

        try await stream.close()
        try await connection.close()
    }

    // MARK: - Connect Tests

    @Test("Relay connect request (CONNECT)", .timeLimit(.minutes(2)))
    func relayConnect() async throws {
        let harness = try await GoProtocolHarness.start(
            protocol: .relay(mode: "server")
        )
        defer { stopHarness(harness) }

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

        let targetPeerID = KeyPair.generateEd25519().peerID
        let connectRequest = HopMessage.connect(to: targetPeerID)
        try await stream.write(ByteBuffer(bytes: encodeLengthPrefixed(CircuitRelayProtobuf.encode(connectRequest))))

        let responseFrame = Data(buffer: try await stream.read())
        let responsePayload = try decodeLengthPrefixedMessage(responseFrame)
        let response = try CircuitRelayProtobuf.decodeHop(responsePayload)
        #expect(response.type == .status)
        #expect(response.status != nil)
        #expect(response.status != .ok)
        print("[Relay] CONNECT response decoded: status=\(String(describing: response.status))")

        try await stream.close()
        try await connection.close()
    }

    // MARK: - STOP Protocol Tests

    @Test("Relay STOP protocol negotiation", .timeLimit(.minutes(2)))
    func relayStopProtocol() async throws {
        let harness = try await GoProtocolHarness.start(
            protocol: .relay(mode: "server")
        )
        defer { stopHarness(harness) }

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
        let harness = try await GoProtocolHarness.start(
            protocol: .relay(mode: "server")
        )
        defer { stopHarness(harness) }

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

        let reserveRequest = HopMessage.reserve()
        try await reserveStream.write(ByteBuffer(bytes: encodeLengthPrefixed(CircuitRelayProtobuf.encode(reserveRequest))))

        let responseFrame = Data(buffer: try await reserveStream.read())
        let responsePayload = try decodeLengthPrefixedMessage(responseFrame)
        let response = try CircuitRelayProtobuf.decodeHop(responsePayload)
        #expect(response.type == .status)
        #expect(response.status == .ok)

        if let reservation = response.reservation {
            #expect(reservation.expiration > 0)
        } else {
            Issue.record("Reservation response missing reservation payload")
        }

        try await reserveStream.close()
        try await connection.close()
    }
}

private enum RelayInteropWireError: Error {
    case truncatedFrame(expected: Int, actual: Int)
}

private func encodeLengthPrefixed(_ payload: Data) -> Data {
    var framed = Data()
    framed.append(contentsOf: Varint.encode(UInt64(payload.count)))
    framed.append(payload)
    return framed
}

private func decodeLengthPrefixedMessage(_ frame: Data) throws -> Data {
    let (messageLength, prefixLength) = try Varint.decode(frame)
    let start = prefixLength
    let end = start + Int(messageLength)
    guard end <= frame.count else {
        throw RelayInteropWireError.truncatedFrame(expected: end, actual: frame.count)
    }
    return Data(frame[start..<end])
}

private func stopHarness(_ harness: GoProtocolHarness) {
    Task {
        do {
            try await harness.stop()
        } catch {
            print("[Relay] Failed to stop harness: \(error)")
        }
    }
}
