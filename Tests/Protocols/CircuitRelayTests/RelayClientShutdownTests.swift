/// RelayClientShutdownTests - Shutdown lifecycle tests for RelayClient.

import Testing
import Foundation
import NIOCore
@testable import P2PCircuitRelay
@testable import P2PCore
@testable import P2PMux
@testable import P2PProtocols

@Suite("RelayClient Shutdown Tests")
struct RelayClientShutdownTests {

    @Test("Shutdown terminates event stream", .timeLimit(.minutes(1)))
    func shutdownTerminatesEventStream() async throws {
        let client = RelayClient()
        let events = client.events

        let consumeTask = Task {
            var count = 0
            for await _ in events { count += 1 }
            return count
        }

        do { try await Task.sleep(for: .milliseconds(50)) } catch {}

        try await client.shutdown()

        let count = await consumeTask.value
        #expect(count == 0)
    }

    @Test("Shutdown is idempotent", .timeLimit(.minutes(1)))
    func shutdownIsIdempotent() async throws {
        let client = RelayClient()
        try await client.shutdown()
        try await client.shutdown()
        try await client.shutdown()
    }

    @Test("Shutdown resumes pending acceptConnection waiters", .timeLimit(.minutes(1)))
    func shutdownResumesPendingAcceptConnectionWaiters() async throws {
        let client = RelayClient(configuration: .init(connectTimeout: .seconds(30)))
        let acceptTask = Task {
            try await client.acceptConnection()
        }

        try await Task.sleep(for: .milliseconds(50))
        try await client.shutdown()

        await #expect(throws: CircuitRelayError.self) {
            _ = try await acceptTask.value
        }
    }

    @Test("acceptConnection fails after shutdown", .timeLimit(.minutes(1)))
    func acceptConnectionFailsAfterShutdown() async throws {
        let client = RelayClient()
        try await client.shutdown()

        await #expect(throws: CircuitRelayError.self) {
            _ = try await client.acceptConnection()
        }
    }

    @Test("Shutdown closes queued relay connections", .timeLimit(.minutes(1)))
    func shutdownClosesQueuedRelayConnections() async throws {
        let client = RelayClient()
        let relayKey = KeyPair.generateEd25519()
        let targetKey = KeyPair.generateEd25519()
        let sourceKey = KeyPair.generateEd25519()

        let (relayStream, clientStream) = MockMuxedStream.createPair(
            protocolID: CircuitRelayProtocol.stopProtocolID
        )
        let connect = StopMessage.connect(from: sourceKey.peerID, limit: .default)
        try await relayStream.writeLengthPrefixedMessage(
            ByteBuffer(bytes: CircuitRelayProtobuf.encode(connect))
        )

        let context = makeStreamContext(
            stream: clientStream,
            remotePeer: relayKey.peerID,
            localPeer: targetKey.peerID,
            protocolID: CircuitRelayProtocol.stopProtocolID
        )
        await client.handleInboundStream(context)

        try await client.shutdown()

        await #expect(throws: Error.self) {
            try await clientStream.write(ByteBuffer(string: "must be closed"))
        }
    }

    @Test("STOP direct listener path closes connections after client shutdown", .timeLimit(.minutes(1)))
    func stopDirectListenerPathClosesAfterClientShutdown() async throws {
        let client = RelayClient()
        let relayKey = KeyPair.generateEd25519()
        let targetKey = KeyPair.generateEd25519()
        let sourceKey = KeyPair.generateEd25519()

        let reservation = Reservation(
            relay: relayKey.peerID,
            expiration: ContinuousClock.now + .seconds(3600),
            addresses: [],
            voucher: nil
        )
        let listener = RelayListener(
            relay: relayKey.peerID,
            client: client,
            localAddress: Multiaddr(uncheckedProtocols: [.p2p(relayKey.peerID), .p2pCircuit]),
            reservation: reservation
        )

        try await client.shutdown()

        let (relayStream, clientStream) = MockMuxedStream.createPair(
            protocolID: CircuitRelayProtocol.stopProtocolID
        )
        let connect = StopMessage.connect(from: sourceKey.peerID, limit: .default)
        try await relayStream.writeLengthPrefixedMessage(
            ByteBuffer(bytes: CircuitRelayProtobuf.encode(connect))
        )

        let context = makeStreamContext(
            stream: clientStream,
            remotePeer: relayKey.peerID,
            localPeer: targetKey.peerID,
            protocolID: CircuitRelayProtocol.stopProtocolID
        )
        await client.handleInboundStream(context)

        await #expect(throws: Error.self) {
            try await clientStream.write(ByteBuffer(string: "must be closed"))
        }
        try await listener.close()
    }
}
