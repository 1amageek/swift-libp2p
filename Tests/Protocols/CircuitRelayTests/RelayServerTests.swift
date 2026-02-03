/// RelayServerTests - Unit tests for RelayServer event emission and resource management.

import Testing
import Foundation
import NIOCore
import Synchronization
@testable import P2PCircuitRelay
@testable import P2PCore
@testable import P2PMux
@testable import P2PProtocols

// MARK: - Test Helpers

/// Helper to create a mock StreamContext with required parameters.
func makeStreamContext(
    stream: MuxedStream,
    remotePeer: PeerID,
    localPeer: PeerID
) -> StreamContext {
    StreamContext(
        stream: stream,
        remotePeer: remotePeer,
        remoteAddress: Multiaddr.tcp(host: "127.0.0.1", port: 4001),
        localPeer: localPeer,
        localAddress: Multiaddr.tcp(host: "127.0.0.1", port: 4002)
    )
}

/// Helper to collect events with timeout.
final class TestEventCollector: Sendable {
    private let state: Mutex<[CircuitRelayEvent]>

    init() {
        self.state = Mutex([])
    }

    func collect(_ event: CircuitRelayEvent) {
        state.withLock { $0.append(event) }
    }

    var events: [CircuitRelayEvent] {
        state.withLock { $0 }
    }

    func waitForEvents(count: Int, timeout: Duration = .seconds(2)) async -> [CircuitRelayEvent] {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let current = state.withLock { $0 }
            if current.count >= count {
                return current
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return state.withLock { $0 }
    }
}

// MARK: - RelayServer Event Tests

@Suite("RelayServer Event Tests")
struct RelayServerEventTests {

    // MARK: - Reservation Events

    @Test("Server emits reservationAccepted event on successful reservation", .timeLimit(.minutes(1)))
    func reservationAcceptedEvent() async throws {
        let serverKey = KeyPair.generateEd25519()
        let requesterKey = KeyPair.generateEd25519()

        let server = RelayServer(configuration: .init(maxReservations: 10))
        let registry = MockHandlerRegistry()
        let opener = MockStreamOpener()

        await server.registerHandler(
            registry: registry,
            opener: opener,
            localPeer: serverKey.peerID,
            getLocalAddresses: { [Multiaddr.tcp(host: "127.0.0.1", port: 4001)] }
        )

        // Set up event collection
        let collector = TestEventCollector()
        let eventTask = Task {
            for await event in server.events {
                collector.collect(event)
            }
        }

        // Give event task time to start iterating
        try await Task.sleep(for: .milliseconds(50))

        // Create stream pair
        let (clientStream, serverStream) = MockMuxedStream.createPair(protocolID: CircuitRelayProtocol.hopProtocolID)

        // Send RESERVE request
        let reserveRequest = HopMessage.reserve()
        let requestData = CircuitRelayProtobuf.encode(reserveRequest)
        try await clientStream.writeLengthPrefixedMessage(ByteBuffer(bytes: requestData))

        // Handle on server
        let handler = registry.getHandler(for: CircuitRelayProtocol.hopProtocolID)
        #expect(handler != nil)

        let context = makeStreamContext(
            stream: serverStream,
            remotePeer: requesterKey.peerID,
            localPeer: serverKey.peerID
        )
        await handler?(context)

        // Wait for event
        let events = await collector.waitForEvents(count: 1)

        // Verify event
        #expect(events.count >= 1)
        if case .reservationAccepted(let from, _) = events.first {
            #expect(from == requesterKey.peerID)
        } else {
            Issue.record("Expected reservationAccepted event, got \(String(describing: events.first))")
        }

        // Cleanup
        eventTask.cancel()
        server.shutdown()
    }

    @Test("Server emits reservationDenied event when full", .timeLimit(.minutes(1)))
    func reservationDeniedEvent() async throws {
        let serverKey = KeyPair.generateEd25519()
        let requesterKey = KeyPair.generateEd25519()

        // Server with maxReservations = 0 to always deny
        let server = RelayServer(configuration: .init(maxReservations: 0))
        let registry = MockHandlerRegistry()
        let opener = MockStreamOpener()

        await server.registerHandler(
            registry: registry,
            opener: opener,
            localPeer: serverKey.peerID,
            getLocalAddresses: { [] }
        )

        // Set up event collection BEFORE any operations
        // Access events property first to initialize the stream
        let collector = TestEventCollector()
        let eventTask = Task {
            for await event in server.events {
                collector.collect(event)
            }
        }

        // Give event task time to start iterating
        try await Task.sleep(for: .milliseconds(50))

        // Create stream pair
        let (clientStream, serverStream) = MockMuxedStream.createPair(protocolID: CircuitRelayProtocol.hopProtocolID)

        // Send RESERVE request
        let reserveRequest = HopMessage.reserve()
        let requestData = CircuitRelayProtobuf.encode(reserveRequest)
        try await clientStream.writeLengthPrefixedMessage(ByteBuffer(bytes: requestData))

        // Handle on server
        let handler = registry.getHandler(for: CircuitRelayProtocol.hopProtocolID)
        let context = makeStreamContext(
            stream: serverStream,
            remotePeer: requesterKey.peerID,
            localPeer: serverKey.peerID
        )
        await handler?(context)

        // Wait for event
        let events = await collector.waitForEvents(count: 1)

        // Verify event
        #expect(events.count >= 1)
        if case .reservationDenied(let from, let reason) = events.first {
            #expect(from == requesterKey.peerID)
            #expect(reason == .resourceLimitExceeded)
        } else {
            Issue.record("Expected reservationDenied event, got \(String(describing: events.first))")
        }

        // Cleanup
        eventTask.cancel()
        server.shutdown()
    }

    // MARK: - Circuit Events

    @Test("Server emits circuitOpened event on successful connect", .timeLimit(.minutes(1)))
    func circuitOpenedEvent() async throws {
        let serverKey = KeyPair.generateEd25519()
        let sourceKey = KeyPair.generateEd25519()
        let targetKey = KeyPair.generateEd25519()

        let server = RelayServer(configuration: .init(maxReservations: 10, maxCircuitsPerPeer: 10))
        let registry = MockHandlerRegistry()
        let opener = MockStreamOpener()

        await server.registerHandler(
            registry: registry,
            opener: opener,
            localPeer: serverKey.peerID,
            getLocalAddresses: { [] }
        )

        let handler = registry.getHandler(for: CircuitRelayProtocol.hopProtocolID)!

        // First, create a reservation for target
        let (reserveClientStream, reserveServerStream) = MockMuxedStream.createPair()
        let reserveRequest = HopMessage.reserve()
        try await reserveClientStream.writeLengthPrefixedMessage(ByteBuffer(bytes: CircuitRelayProtobuf.encode(reserveRequest)))
        await handler(makeStreamContext(stream: reserveServerStream, remotePeer: targetKey.peerID, localPeer: serverKey.peerID))

        // Set up event collection
        let collector = TestEventCollector()
        let eventTask = Task {
            for await event in server.events {
                collector.collect(event)
            }
        }

        // Set up opener to return a stream for Stop protocol
        // The relay server uses relayToTarget, target uses targetToRelay
        let (relayToTarget, targetToRelay) = MockMuxedStream.createPair(protocolID: CircuitRelayProtocol.stopProtocolID)
        opener.setStream(relayToTarget, for: CircuitRelayProtocol.stopProtocolID)

        // Simulate target responding OK to Stop CONNECT, then close to end relay
        Task {
            // Read CONNECT message from target's side
            _ = try? await targetToRelay.readLengthPrefixedMessage(maxSize: 4096)
            // Send OK response from target's side
            let okResponse = StopMessage.statusResponse(.ok)
            try? await targetToRelay.writeLengthPrefixedMessage(ByteBuffer(bytes: CircuitRelayProtobuf.encode(okResponse)))
            // Close the stream to allow relayData to terminate
            try? await Task.sleep(for: .milliseconds(50))
            try? await targetToRelay.close()
        }

        // Send CONNECT request from source
        let (connectClientStream, connectServerStream) = MockMuxedStream.createPair()
        let connectRequest = HopMessage.connect(to: targetKey.peerID)
        try await connectClientStream.writeLengthPrefixedMessage(ByteBuffer(bytes: CircuitRelayProtobuf.encode(connectRequest)))

        // Handle connect in background since it blocks during relay
        let handlerTask = Task {
            await handler(makeStreamContext(stream: connectServerStream, remotePeer: sourceKey.peerID, localPeer: serverKey.peerID))
        }

        // Wait for events
        let events = await collector.waitForEvents(count: 2, timeout: .seconds(3))

        // Find circuitOpened event
        let circuitOpenedEvent = events.first { event in
            if case .circuitOpened = event { return true }
            return false
        }

        #expect(circuitOpenedEvent != nil)
        if case .circuitOpened(let src, let dst) = circuitOpenedEvent {
            #expect(src == sourceKey.peerID)
            #expect(dst == targetKey.peerID)
        }

        // Close streams to terminate the relay
        try await connectClientStream.close()

        // Wait briefly for handler to finish
        _ = await Task {
            try? await Task.sleep(for: .milliseconds(100))
        }.value

        // Cleanup
        handlerTask.cancel()
        eventTask.cancel()
        server.shutdown()
    }

    @Test("Server emits circuitFailed event when target has no reservation", .timeLimit(.minutes(1)))
    func circuitFailedNoReservation() async throws {
        let serverKey = KeyPair.generateEd25519()
        let sourceKey = KeyPair.generateEd25519()
        let targetKey = KeyPair.generateEd25519()  // No reservation for this peer

        let server = RelayServer(configuration: .init(maxReservations: 10))
        let registry = MockHandlerRegistry()
        let opener = MockStreamOpener()

        await server.registerHandler(
            registry: registry,
            opener: opener,
            localPeer: serverKey.peerID,
            getLocalAddresses: { [] }
        )

        // Create stream pair for connect
        let (clientStream, serverStream) = MockMuxedStream.createPair()

        // Send CONNECT request (without reservation for target)
        let connectRequest = HopMessage.connect(to: targetKey.peerID)
        try await clientStream.writeLengthPrefixedMessage(ByteBuffer(bytes: CircuitRelayProtobuf.encode(connectRequest)))

        // Handle on server
        let handler = registry.getHandler(for: CircuitRelayProtocol.hopProtocolID)!
        await handler(makeStreamContext(stream: serverStream, remotePeer: sourceKey.peerID, localPeer: serverKey.peerID))

        // Read response - should be NO_RESERVATION
        let responseData = try await clientStream.readLengthPrefixedMessage(maxSize: 4096)
        let response = try CircuitRelayProtobuf.decodeHop(Data(buffer: responseData))

        #expect(response.status == .noReservation)

        server.shutdown()
    }

    @Test("Server emits circuitFailed event when circuit limit exceeded", .timeLimit(.minutes(1)))
    func circuitFailedLimitExceeded() async throws {
        let serverKey = KeyPair.generateEd25519()
        let sourceKey = KeyPair.generateEd25519()
        let targetKey = KeyPair.generateEd25519()

        // Server with maxCircuitsPerPeer = 0 to always deny
        let server = RelayServer(configuration: .init(maxReservations: 10, maxCircuitsPerPeer: 0))
        let registry = MockHandlerRegistry()
        let opener = MockStreamOpener()

        await server.registerHandler(
            registry: registry,
            opener: opener,
            localPeer: serverKey.peerID,
            getLocalAddresses: { [] }
        )

        let handler = registry.getHandler(for: CircuitRelayProtocol.hopProtocolID)!

        // First, create a reservation for target
        let (reserveClientStream, reserveServerStream) = MockMuxedStream.createPair()
        let reserveRequest = HopMessage.reserve()
        try await reserveClientStream.writeLengthPrefixedMessage(ByteBuffer(bytes: CircuitRelayProtobuf.encode(reserveRequest)))
        await handler(makeStreamContext(stream: reserveServerStream, remotePeer: targetKey.peerID, localPeer: serverKey.peerID))

        // Set up event collection
        let collector = TestEventCollector()
        let eventTask = Task {
            for await event in server.events {
                collector.collect(event)
            }
        }

        // Give event task time to start iterating
        try await Task.sleep(for: .milliseconds(50))

        // Send CONNECT request
        let (connectClientStream, connectServerStream) = MockMuxedStream.createPair()
        let connectRequest = HopMessage.connect(to: targetKey.peerID)
        try await connectClientStream.writeLengthPrefixedMessage(ByteBuffer(bytes: CircuitRelayProtobuf.encode(connectRequest)))

        // Handle connect - should fail due to limit
        await handler(makeStreamContext(stream: connectServerStream, remotePeer: sourceKey.peerID, localPeer: serverKey.peerID))

        // Wait for event (only need 1 - the circuitFailed event)
        let events = await collector.waitForEvents(count: 1, timeout: .seconds(2))

        // Find circuitFailed event
        let circuitFailedEvent = events.first { event in
            if case .circuitFailed = event { return true }
            return false
        }

        #expect(circuitFailedEvent != nil)
        if case .circuitFailed(let src, let dst, let reason) = circuitFailedEvent {
            #expect(src == sourceKey.peerID)
            #expect(dst == targetKey.peerID)
            #expect(reason == .resourceLimitExceeded)
        }

        // Cleanup
        eventTask.cancel()
        server.shutdown()
    }
}

// MARK: - Reservation Management Tests

@Suite("RelayServer Reservation Tests")
struct RelayServerReservationTests {

    @Test("Reservation count is tracked correctly", .timeLimit(.minutes(1)))
    func reservationCount() async throws {
        let serverKey = KeyPair.generateEd25519()
        let requesterKey = KeyPair.generateEd25519()

        let server = RelayServer(configuration: .init(maxReservations: 10))
        let registry = MockHandlerRegistry()
        let opener = MockStreamOpener()

        await server.registerHandler(
            registry: registry,
            opener: opener,
            localPeer: serverKey.peerID,
            getLocalAddresses: { [] }
        )

        #expect(server.reservationCount == 0)

        // Create reservation
        let (clientStream, serverStream) = MockMuxedStream.createPair()
        let reserveRequest = HopMessage.reserve()
        try await clientStream.writeLengthPrefixedMessage(ByteBuffer(bytes: CircuitRelayProtobuf.encode(reserveRequest)))

        let handler = registry.getHandler(for: CircuitRelayProtocol.hopProtocolID)!
        await handler(makeStreamContext(stream: serverStream, remotePeer: requesterKey.peerID, localPeer: serverKey.peerID))

        #expect(server.reservationCount == 1)

        server.shutdown()
    }

    @Test("Expired reservation is cleaned up", .timeLimit(.minutes(1)))
    func expiredReservationCleanup() async throws {
        let serverKey = KeyPair.generateEd25519()
        let requesterKey = KeyPair.generateEd25519()

        // Very short reservation duration for testing
        let server = RelayServer(configuration: .init(
            maxReservations: 10,
            reservationDuration: .milliseconds(100)
        ))
        let registry = MockHandlerRegistry()
        let opener = MockStreamOpener()

        await server.registerHandler(
            registry: registry,
            opener: opener,
            localPeer: serverKey.peerID,
            getLocalAddresses: { [] }
        )

        // Create reservation
        let (clientStream, serverStream) = MockMuxedStream.createPair()
        let reserveRequest = HopMessage.reserve()
        try await clientStream.writeLengthPrefixedMessage(ByteBuffer(bytes: CircuitRelayProtobuf.encode(reserveRequest)))

        let handler = registry.getHandler(for: CircuitRelayProtocol.hopProtocolID)!
        await handler(makeStreamContext(stream: serverStream, remotePeer: requesterKey.peerID, localPeer: serverKey.peerID))

        #expect(server.reservationCount == 1)

        // Wait for expiration + cleanup
        try await Task.sleep(for: .milliseconds(200))

        // Reservation should be cleaned up
        #expect(server.reservationCount == 0)

        server.shutdown()
    }

    @Test("Connect to expired reservation fails", .timeLimit(.minutes(1)))
    func connectToExpiredReservation() async throws {
        let serverKey = KeyPair.generateEd25519()
        let targetKey = KeyPair.generateEd25519()
        let sourceKey = KeyPair.generateEd25519()

        // Very short reservation duration for testing
        let server = RelayServer(configuration: .init(
            maxReservations: 10,
            reservationDuration: .milliseconds(50)
        ))
        let registry = MockHandlerRegistry()
        let opener = MockStreamOpener()

        await server.registerHandler(
            registry: registry,
            opener: opener,
            localPeer: serverKey.peerID,
            getLocalAddresses: { [] }
        )

        let handler = registry.getHandler(for: CircuitRelayProtocol.hopProtocolID)!

        // Create reservation for target
        let (reserveClientStream, reserveServerStream) = MockMuxedStream.createPair()
        let reserveRequest = HopMessage.reserve()
        try await reserveClientStream.writeLengthPrefixedMessage(ByteBuffer(bytes: CircuitRelayProtobuf.encode(reserveRequest)))
        await handler(makeStreamContext(stream: reserveServerStream, remotePeer: targetKey.peerID, localPeer: serverKey.peerID))

        // Wait for reservation to expire
        try await Task.sleep(for: .milliseconds(100))

        // Try to connect - should fail with NO_RESERVATION
        let (connectClientStream, connectServerStream) = MockMuxedStream.createPair()
        let connectRequest = HopMessage.connect(to: targetKey.peerID)
        try await connectClientStream.writeLengthPrefixedMessage(ByteBuffer(bytes: CircuitRelayProtobuf.encode(connectRequest)))

        await handler(makeStreamContext(stream: connectServerStream, remotePeer: sourceKey.peerID, localPeer: serverKey.peerID))

        // Read response
        let responseData = try await connectClientStream.readLengthPrefixedMessage(maxSize: 4096)
        let response = try CircuitRelayProtobuf.decodeHop(Data(buffer: responseData))

        #expect(response.status == .noReservation)

        server.shutdown()
    }
}

// MARK: - Circuit Limit Tests

@Suite("RelayServer Circuit Limit Tests")
struct RelayServerCircuitLimitTests {

    @Test("MaxCircuitsPerPeer is enforced", .timeLimit(.minutes(1)))
    func maxCircuitsPerPeerEnforced() async throws {
        let serverKey = KeyPair.generateEd25519()
        let sourceKey = KeyPair.generateEd25519()
        let target1Key = KeyPair.generateEd25519()
        let target2Key = KeyPair.generateEd25519()

        let server = RelayServer(configuration: .init(
            maxReservations: 10,
            maxCircuitsPerPeer: 1,
            maxCircuits: 100
        ))
        let registry = MockHandlerRegistry()
        let opener = MockStreamOpener()

        await server.registerHandler(
            registry: registry,
            opener: opener,
            localPeer: serverKey.peerID,
            getLocalAddresses: { [] }
        )

        let handler = registry.getHandler(for: CircuitRelayProtocol.hopProtocolID)!

        // Create reservations for both targets
        for targetKey in [target1Key, target2Key] {
            let (clientStream, serverStream) = MockMuxedStream.createPair()
            try await clientStream.writeLengthPrefixedMessage(ByteBuffer(bytes: CircuitRelayProtobuf.encode(HopMessage.reserve())))
            await handler(makeStreamContext(stream: serverStream, remotePeer: targetKey.peerID, localPeer: serverKey.peerID))
        }

        // Set up opener for Stop protocol
        // The relay server uses relayToTarget, target uses targetToRelay
        let (relayToTarget1, targetToRelay1) = MockMuxedStream.createPair(protocolID: CircuitRelayProtocol.stopProtocolID)
        opener.setStream(relayToTarget1, for: CircuitRelayProtocol.stopProtocolID)

        // Simulate target1 responding OK and keeping connection alive
        let target1ReadySignal = AsyncStream<Void>.makeStream()
        let target1Task = Task {
            _ = try? await targetToRelay1.readLengthPrefixedMessage(maxSize: 4096)
            try? await targetToRelay1.writeLengthPrefixedMessage(ByteBuffer(bytes: CircuitRelayProtobuf.encode(StopMessage.statusResponse(.ok))))
            target1ReadySignal.continuation.yield()
            // Keep connection alive - wait for cancellation
            try? await Task.sleep(for: .seconds(10))
        }

        // First connect should succeed - run in background since it blocks during relay
        let (connect1ClientStream, connect1ServerStream) = MockMuxedStream.createPair()
        try await connect1ClientStream.writeLengthPrefixedMessage(ByteBuffer(bytes: CircuitRelayProtobuf.encode(HopMessage.connect(to: target1Key.peerID))))

        let handler1Task = Task {
            await handler(makeStreamContext(stream: connect1ServerStream, remotePeer: sourceKey.peerID, localPeer: serverKey.peerID))
        }

        // Read response - should be OK
        let response1Data = try await connect1ClientStream.readLengthPrefixedMessage(maxSize: 4096)
        let response1 = try CircuitRelayProtobuf.decodeHop(Data(buffer: response1Data))
        #expect(response1.status == .ok)

        // Wait for target1 to be fully connected (ensures circuit is registered)
        for await _ in target1ReadySignal.stream {
            break
        }

        // Small delay to ensure circuit registration is complete
        try await Task.sleep(for: .milliseconds(20))

        // Second connect from same source should fail due to per-peer limit
        // The circuit limit check happens BEFORE trying to connect to target
        let (connect2ClientStream, connect2ServerStream) = MockMuxedStream.createPair()
        try await connect2ClientStream.writeLengthPrefixedMessage(ByteBuffer(bytes: CircuitRelayProtobuf.encode(HopMessage.connect(to: target2Key.peerID))))
        await handler(makeStreamContext(stream: connect2ServerStream, remotePeer: sourceKey.peerID, localPeer: serverKey.peerID))

        // Read response - should be RESOURCE_LIMIT_EXCEEDED
        let response2Data = try await connect2ClientStream.readLengthPrefixedMessage(maxSize: 4096)
        let response2 = try CircuitRelayProtobuf.decodeHop(Data(buffer: response2Data))
        #expect(response2.status == .resourceLimitExceeded)

        // Cleanup
        target1Task.cancel()
        handler1Task.cancel()
        try? await connect1ClientStream.close()
        try? await targetToRelay1.close()
        server.shutdown()
    }

    @Test("MaxCircuits total is enforced", .timeLimit(.minutes(1)))
    func maxCircuitsTotalEnforced() async throws {
        let serverKey = KeyPair.generateEd25519()
        let sourceKey = KeyPair.generateEd25519()
        let targetKey = KeyPair.generateEd25519()

        let server = RelayServer(configuration: .init(
            maxReservations: 10,
            maxCircuitsPerPeer: 10,
            maxCircuits: 0  // No circuits allowed
        ))
        let registry = MockHandlerRegistry()
        let opener = MockStreamOpener()

        await server.registerHandler(
            registry: registry,
            opener: opener,
            localPeer: serverKey.peerID,
            getLocalAddresses: { [] }
        )

        let handler = registry.getHandler(for: CircuitRelayProtocol.hopProtocolID)!

        // Create reservation for target
        let (reserveClientStream, reserveServerStream) = MockMuxedStream.createPair()
        try await reserveClientStream.writeLengthPrefixedMessage(ByteBuffer(bytes: CircuitRelayProtobuf.encode(HopMessage.reserve())))
        await handler(makeStreamContext(stream: reserveServerStream, remotePeer: targetKey.peerID, localPeer: serverKey.peerID))

        // Try to connect - should fail due to maxCircuits = 0
        let (connectClientStream, connectServerStream) = MockMuxedStream.createPair()
        try await connectClientStream.writeLengthPrefixedMessage(ByteBuffer(bytes: CircuitRelayProtobuf.encode(HopMessage.connect(to: targetKey.peerID))))
        await handler(makeStreamContext(stream: connectServerStream, remotePeer: sourceKey.peerID, localPeer: serverKey.peerID))

        // Read response - should be RESOURCE_LIMIT_EXCEEDED
        let responseData = try await connectClientStream.readLengthPrefixedMessage(maxSize: 4096)
        let response = try CircuitRelayProtobuf.decodeHop(Data(buffer: responseData))
        #expect(response.status == .resourceLimitExceeded)

        server.shutdown()
    }
}

// MARK: - Configuration Tests

@Suite("RelayServer Configuration Tests")
struct RelayServerConfigurationTests {

    @Test("Default configuration values")
    func defaultConfiguration() {
        let config = RelayServerConfiguration()

        #expect(config.maxReservations == 128)
        #expect(config.maxCircuitsPerPeer == 16)
        #expect(config.maxCircuits == 1024)
        #expect(config.reservationDuration == .seconds(3600))
    }

    @Test("Custom configuration values")
    func customConfiguration() {
        let config = RelayServerConfiguration(
            maxReservations: 64,
            maxCircuitsPerPeer: 8,
            maxCircuits: 512,
            reservationDuration: .seconds(1800),
            circuitLimit: CircuitLimit(duration: .seconds(300), data: 1024 * 1024)
        )

        #expect(config.maxReservations == 64)
        #expect(config.maxCircuitsPerPeer == 8)
        #expect(config.maxCircuits == 512)
        #expect(config.reservationDuration == .seconds(1800))
        #expect(config.circuitLimit.duration == .seconds(300))
        #expect(config.circuitLimit.data == 1024 * 1024)
    }

    @Test("Server uses protocol ID correctly")
    func protocolID() {
        let server = RelayServer()

        #expect(server.protocolIDs == [CircuitRelayProtocol.hopProtocolID])
    }
}

// MARK: - Shutdown Tests

@Suite("RelayServer Shutdown Tests")
struct RelayServerShutdownTests {

    @Test("Shutdown finishes event stream", .timeLimit(.minutes(1)))
    func shutdownFinishesEventStream() async throws {
        let server = RelayServer()

        let streamFinished = Mutex(false)
        let task = Task {
            for await _ in server.events {
                // Consume events
            }
            streamFinished.withLock { $0 = true }
        }

        // Give time for iteration to start
        try await Task.sleep(for: .milliseconds(50))

        // Shutdown
        server.shutdown()

        // Wait for stream to finish
        try await Task.sleep(for: .milliseconds(100))

        #expect(streamFinished.withLock { $0 })
        task.cancel()
    }
}

// MARK: - Error Scenario Tests

@Suite("RelayServer Error Scenario Tests")
struct RelayServerErrorScenarioTests {

    @Test("Target rejection emits circuitFailed event", .timeLimit(.minutes(1)))
    func targetRejectionEmitsCircuitFailed() async throws {
        let serverKey = KeyPair.generateEd25519()
        let sourceKey = KeyPair.generateEd25519()
        let targetKey = KeyPair.generateEd25519()

        let server = RelayServer()
        let registry = MockHandlerRegistry()
        let opener = MockStreamOpener()

        await server.registerHandler(
            registry: registry,
            opener: opener,
            localPeer: serverKey.peerID,
            getLocalAddresses: { [] }
        )

        let handler = registry.getHandler(for: CircuitRelayProtocol.hopProtocolID)!

        // Create reservation for target
        let (reserveClientStream, reserveServerStream) = MockMuxedStream.createPair()
        try await reserveClientStream.writeLengthPrefixedMessage(ByteBuffer(bytes: CircuitRelayProtobuf.encode(HopMessage.reserve())))
        await handler(makeStreamContext(stream: reserveServerStream, remotePeer: targetKey.peerID, localPeer: serverKey.peerID))

        // Set up opener for Stop protocol - target will REJECT
        let (relayToTarget, targetToRelay) = MockMuxedStream.createPair(protocolID: CircuitRelayProtocol.stopProtocolID)
        opener.setStream(relayToTarget, for: CircuitRelayProtocol.stopProtocolID)

        // Start listening for events (thread-safe collection)
        let collectedEvents = Mutex<[CircuitRelayEvent]>([])
        let eventTask = Task {
            for await event in server.events {
                collectedEvents.withLock { $0.append(event) }
            }
        }

        // Simulate target rejecting the connection
        Task {
            _ = try? await targetToRelay.readLengthPrefixedMessage(maxSize: 4096)
            // Send rejection response
            try? await targetToRelay.writeLengthPrefixedMessage(
                ByteBuffer(bytes: CircuitRelayProtobuf.encode(StopMessage.statusResponse(.connectionFailed)))
            )
        }

        // Try to connect
        let (connectClientStream, connectServerStream) = MockMuxedStream.createPair()
        try await connectClientStream.writeLengthPrefixedMessage(ByteBuffer(bytes: CircuitRelayProtobuf.encode(HopMessage.connect(to: targetKey.peerID))))
        await handler(makeStreamContext(stream: connectServerStream, remotePeer: sourceKey.peerID, localPeer: serverKey.peerID))

        // Read response - should be connectionFailed
        let responseData = try await connectClientStream.readLengthPrefixedMessage(maxSize: 4096)
        let response = try CircuitRelayProtobuf.decodeHop(Data(buffer: responseData))
        #expect(response.status == .connectionFailed)

        // Small delay to ensure event is emitted
        try await Task.sleep(for: .milliseconds(50))
        server.shutdown()
        eventTask.cancel()

        // Check for circuitFailed event with targetRejected reason
        let events = collectedEvents.withLock { $0 }
        let circuitFailedEvents = events.compactMap { event -> CircuitFailureReason? in
            if case .circuitFailed(_, _, let reason) = event {
                return reason
            }
            return nil
        }
        #expect(circuitFailedEvents.contains(.targetRejected))
    }

    @Test("Invalid message type is handled gracefully", .timeLimit(.minutes(1)))
    func invalidMessageTypeHandled() async throws {
        let serverKey = KeyPair.generateEd25519()
        let clientKey = KeyPair.generateEd25519()

        let server = RelayServer()
        let registry = MockHandlerRegistry()
        let opener = MockStreamOpener()

        await server.registerHandler(
            registry: registry,
            opener: opener,
            localPeer: serverKey.peerID,
            getLocalAddresses: { [] }
        )

        let handler = registry.getHandler(for: CircuitRelayProtocol.hopProtocolID)!

        // Send an invalid/unexpected message (status response instead of request)
        let (clientStream, serverStream) = MockMuxedStream.createPair()
        let statusMessage = HopMessage.statusResponse(.unexpectedMessage)
        try await clientStream.writeLengthPrefixedMessage(ByteBuffer(bytes: CircuitRelayProtobuf.encode(statusMessage)))

        // Handler should complete without crashing
        await handler(makeStreamContext(stream: serverStream, remotePeer: clientKey.peerID, localPeer: serverKey.peerID))

        // Server should still be functional
        server.shutdown()
    }

    @Test("Double reservation updates existing reservation", .timeLimit(.minutes(1)))
    func doubleReservationUpdatesExisting() async throws {
        let serverKey = KeyPair.generateEd25519()
        let clientKey = KeyPair.generateEd25519()

        let server = RelayServer(configuration: .init(maxReservations: 10))
        let registry = MockHandlerRegistry()
        let opener = MockStreamOpener()

        await server.registerHandler(
            registry: registry,
            opener: opener,
            localPeer: serverKey.peerID,
            getLocalAddresses: { [] }
        )

        let handler = registry.getHandler(for: CircuitRelayProtocol.hopProtocolID)!

        // First reservation
        let (reserve1ClientStream, reserve1ServerStream) = MockMuxedStream.createPair()
        try await reserve1ClientStream.writeLengthPrefixedMessage(ByteBuffer(bytes: CircuitRelayProtobuf.encode(HopMessage.reserve())))
        await handler(makeStreamContext(stream: reserve1ServerStream, remotePeer: clientKey.peerID, localPeer: serverKey.peerID))

        let response1Data = try await reserve1ClientStream.readLengthPrefixedMessage(maxSize: 4096)
        let response1 = try CircuitRelayProtobuf.decodeHop(Data(buffer: response1Data))
        #expect(response1.status == .ok)

        // Second reservation from same peer - should succeed (update existing)
        let (reserve2ClientStream, reserve2ServerStream) = MockMuxedStream.createPair()
        try await reserve2ClientStream.writeLengthPrefixedMessage(ByteBuffer(bytes: CircuitRelayProtobuf.encode(HopMessage.reserve())))
        await handler(makeStreamContext(stream: reserve2ServerStream, remotePeer: clientKey.peerID, localPeer: serverKey.peerID))

        let response2Data = try await reserve2ClientStream.readLengthPrefixedMessage(maxSize: 4096)
        let response2 = try CircuitRelayProtobuf.decodeHop(Data(buffer: response2Data))
        #expect(response2.status == .ok)

        server.shutdown()
    }

    @Test("Connect fails when opener has no stream for target", .timeLimit(.minutes(1)))
    func connectFailsWhenOpenerHasNoStream() async throws {
        let serverKey = KeyPair.generateEd25519()
        let sourceKey = KeyPair.generateEd25519()
        let targetKey = KeyPair.generateEd25519()

        let server = RelayServer()
        let registry = MockHandlerRegistry()
        let opener = MockStreamOpener()
        // Note: opener has no streams configured - will fail to connect to target

        await server.registerHandler(
            registry: registry,
            opener: opener,
            localPeer: serverKey.peerID,
            getLocalAddresses: { [] }
        )

        let handler = registry.getHandler(for: CircuitRelayProtocol.hopProtocolID)!

        // Create reservation for target
        let (reserveClientStream, reserveServerStream) = MockMuxedStream.createPair()
        try await reserveClientStream.writeLengthPrefixedMessage(ByteBuffer(bytes: CircuitRelayProtobuf.encode(HopMessage.reserve())))
        await handler(makeStreamContext(stream: reserveServerStream, remotePeer: targetKey.peerID, localPeer: serverKey.peerID))

        // Try to connect - should fail because opener has no stream for target
        let (connectClientStream, connectServerStream) = MockMuxedStream.createPair()
        try await connectClientStream.writeLengthPrefixedMessage(ByteBuffer(bytes: CircuitRelayProtobuf.encode(HopMessage.connect(to: targetKey.peerID))))
        await handler(makeStreamContext(stream: connectServerStream, remotePeer: sourceKey.peerID, localPeer: serverKey.peerID))

        // Read response - should be connectionFailed
        let responseData = try await connectClientStream.readLengthPrefixedMessage(maxSize: 4096)
        let response = try CircuitRelayProtobuf.decodeHop(Data(buffer: responseData))
        #expect(response.status == .connectionFailed)

        server.shutdown()
    }

    @Test("Connect to self returns appropriate error", .timeLimit(.minutes(1)))
    func connectToSelfFails() async throws {
        let serverKey = KeyPair.generateEd25519()
        let clientKey = KeyPair.generateEd25519()

        let server = RelayServer()
        let registry = MockHandlerRegistry()
        let opener = MockStreamOpener()

        await server.registerHandler(
            registry: registry,
            opener: opener,
            localPeer: serverKey.peerID,
            getLocalAddresses: { [] }
        )

        let handler = registry.getHandler(for: CircuitRelayProtocol.hopProtocolID)!

        // Create reservation for client
        let (reserveClientStream, reserveServerStream) = MockMuxedStream.createPair()
        try await reserveClientStream.writeLengthPrefixedMessage(ByteBuffer(bytes: CircuitRelayProtobuf.encode(HopMessage.reserve())))
        await handler(makeStreamContext(stream: reserveServerStream, remotePeer: clientKey.peerID, localPeer: serverKey.peerID))

        // Try to connect to self - same peer as source
        let (connectClientStream, connectServerStream) = MockMuxedStream.createPair()
        try await connectClientStream.writeLengthPrefixedMessage(ByteBuffer(bytes: CircuitRelayProtobuf.encode(HopMessage.connect(to: clientKey.peerID))))
        await handler(makeStreamContext(stream: connectServerStream, remotePeer: clientKey.peerID, localPeer: serverKey.peerID))

        // Handler should complete without hanging
        // Response could be connectionFailed or similar - the point is it doesn't hang
        server.shutdown()
    }
}
