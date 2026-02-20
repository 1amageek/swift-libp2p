import Foundation
import NIOCore
import Testing
@testable import P2PCore
@testable import P2PMux
@testable import P2PNegotiation
@testable import P2PProtocols
@testable import P2PTransportQUIC

@Suite("Ping Interop Tests", .serialized)
struct PingInteropTests {
    @Test("Ping go-libp2p over QUIC", .timeLimit(.minutes(2)))
    func pingGoLibp2p() async throws {
        let harness = try await GoLibp2pHarness.start()
        defer { stopGoHarness(harness) }

        try await assertPingRoundTrip(to: harness.nodeInfo.address)
    }

    @Test("Ping rust-libp2p over QUIC", .timeLimit(.minutes(2)))
    func pingRustLibp2p() async throws {
        let harness = try await RustLibp2pHarness.start()
        defer { stopRustHarness(harness) }

        try await assertPingRoundTrip(to: harness.nodeInfo.address)
    }

    private func assertPingRoundTrip(to address: String) async throws {
        let keyPair = KeyPair.generateEd25519()
        let transport = QUICTransport()
        let connection = try await transport.dialSecured(
            Multiaddr(address),
            localKeyPair: keyPair
        )
        defer { closeConnection(connection) }

        let stream = try await connection.newStream()
        defer { closeStream(stream) }

        let negotiationResult = try await MultistreamSelect.negotiate(
            protocols: [LibP2PProtocol.ping],
            read: { Data(buffer: try await stream.read()) },
            write: { data in
                try await stream.write(ByteBuffer(bytes: data))
            }
        )
        #expect(negotiationResult.protocolID == LibP2PProtocol.ping)

        let payload = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        try await stream.write(ByteBuffer(bytes: payload))
        let response = try await stream.read()
        #expect(Data(buffer: response) == payload)
    }
}

private func stopGoHarness(_ harness: GoLibp2pHarness) {
    Task {
        do {
            try await harness.stop()
        } catch {
        }
    }
}

private func stopRustHarness(_ harness: RustLibp2pHarness) {
    Task {
        do {
            try await harness.stop()
        } catch {
        }
    }
}

private func closeStream(_ stream: MuxedStream) {
    Task {
        do {
            try await stream.close()
        } catch {
        }
    }
}

private func closeConnection(_ connection: any MuxedConnection) {
    Task {
        do {
            try await connection.close()
        } catch {
        }
    }
}
