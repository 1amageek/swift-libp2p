/// RelayTransportTests - Tests for RelayTransport and RelayListener.

import Testing
import Foundation
import NIOCore
import Synchronization
@testable import P2PCore
@testable import P2PTransport
@testable import P2PCircuitRelay

// MARK: - RelayTransport Address Parsing Tests

@Suite("RelayTransport Address Parsing Tests")
struct RelayTransportAddressParsingTests {

    @Test("canDial returns true for p2p-circuit addresses")
    func canDialCircuitAddress() throws {
        let client = RelayClient()
        let transport = RelayTransport(client: client)

        let relayID = KeyPair.generateEd25519().peerID
        let targetID = KeyPair.generateEd25519().peerID

        let address = try Multiaddr("/ip4/127.0.0.1/tcp/4001/p2p/\(relayID.description)/p2p-circuit/p2p/\(targetID.description)")

        #expect(transport.canDial(address) == true)
    }

    @Test("canDial returns false for non-circuit addresses")
    func canDialNonCircuitAddress() throws {
        let client = RelayClient()
        let transport = RelayTransport(client: client)

        let peerID = KeyPair.generateEd25519().peerID

        // Regular address without p2p-circuit
        let address = try Multiaddr("/ip4/127.0.0.1/tcp/4001/p2p/\(peerID.description)")

        #expect(transport.canDial(address) == false)
    }

    @Test("canListen returns true for p2p-circuit addresses")
    func canListenCircuitAddress() throws {
        let client = RelayClient()
        let transport = RelayTransport(client: client)

        let relayID = KeyPair.generateEd25519().peerID

        let address = try Multiaddr("/p2p/\(relayID.description)/p2p-circuit")

        #expect(transport.canListen(address) == true)
    }

    @Test("dial throws when no opener configured")
    func dialWithoutOpenerThrows() async throws {
        let client = RelayClient()
        let transport = RelayTransport(client: client)  // No opener

        let relayID = KeyPair.generateEd25519().peerID
        let targetID = KeyPair.generateEd25519().peerID

        let address = try Multiaddr("/ip4/127.0.0.1/tcp/4001/p2p/\(relayID.description)/p2p-circuit/p2p/\(targetID.description)")

        do {
            _ = try await transport.dial(address)
            Issue.record("Expected dial to throw")
        } catch let error as TransportError {
            guard case .connectionFailed = error else {
                Issue.record("Expected connectionFailed error, got \(error)")
                return
            }
        }
    }

    @Test("listen throws when no opener configured")
    func listenWithoutOpenerThrows() async throws {
        let client = RelayClient()
        let transport = RelayTransport(client: client)  // No opener

        let relayID = KeyPair.generateEd25519().peerID

        let address = try Multiaddr("/p2p/\(relayID.description)/p2p-circuit")

        do {
            _ = try await transport.listen(address)
            Issue.record("Expected listen to throw")
        } catch let error as TransportError {
            guard case .connectionFailed = error else {
                Issue.record("Expected connectionFailed error, got \(error)")
                return
            }
        }
    }

    @Test("setOpener configures opener correctly")
    func setOpenerWorks() async throws {
        let client = RelayClient()
        let transport = RelayTransport(client: client)

        let opener = MockStreamOpener()
        transport.setOpener(opener)

        // After setting opener, dial should no longer throw "no opener" error
        // It will fail for other reasons (no stream configured) but that's expected
        let relayID = KeyPair.generateEd25519().peerID
        let targetID = KeyPair.generateEd25519().peerID

        let address = try Multiaddr("/ip4/127.0.0.1/tcp/4001/p2p/\(relayID.description)/p2p-circuit/p2p/\(targetID.description)")

        do {
            _ = try await transport.dial(address)
            Issue.record("Expected dial to fail")
        } catch let error as TransportError {
            // Should get a different error than "no opener configured"
            guard case .connectionFailed(let underlying) = error else {
                // Any other transport error is also acceptable
                return
            }
            #expect(!(underlying is RelayTransportError))
        } catch {
            // Other errors are fine - the point is it didn't fail due to no opener
        }
    }

    @Test("protocols returns p2p-circuit")
    func protocolsReturnsCircuit() {
        let client = RelayClient()
        let transport = RelayTransport(client: client)

        #expect(transport.protocols == [["p2p-circuit"]])
    }
}

// MARK: - RelayListener Unit Tests

@Suite("RelayListener Unit Tests")
struct RelayListenerUnitTests {

    @Test("accept returns queued connections", .timeLimit(.minutes(1)))
    func acceptReturnsQueuedConnections() async throws {
        let relayKey = KeyPair.generateEd25519()
        let sourceKey = KeyPair.generateEd25519()

        let client = RelayClient()
        let localAddress = try Multiaddr("/p2p/\(relayKey.peerID.description)/p2p-circuit")

        let reservation = Reservation(
            relay: relayKey.peerID,
            expiration: ContinuousClock.now + .seconds(60),
            addresses: [localAddress],
            voucher: nil
        )

        let listener = RelayListener(
            relay: relayKey.peerID,
            client: client,
            localAddress: localAddress,
            reservation: reservation
        )

        // Create a mock relayed connection
        let (clientStream, _) = MockMuxedStream.createPair()
        let connection = RelayedConnection(
            stream: clientStream,
            relay: relayKey.peerID,
            remotePeer: sourceKey.peerID,
            limit: .unlimited
        )

        // Enqueue the connection
        listener.enqueue(connection)

        // Accept should return immediately with the queued connection
        let acceptedConnection = try await listener.accept()

        #expect(acceptedConnection.remoteAddress == connection.remoteAddress)

        try await listener.close()
    }

    @Test("accept waits when queue is empty", .timeLimit(.minutes(1)))
    func acceptWaitsForConnection() async throws {
        let relayKey = KeyPair.generateEd25519()
        let sourceKey = KeyPair.generateEd25519()

        let client = RelayClient()
        let localAddress = try Multiaddr("/p2p/\(relayKey.peerID.description)/p2p-circuit")

        let reservation = Reservation(
            relay: relayKey.peerID,
            expiration: ContinuousClock.now + .seconds(60),
            addresses: [localAddress],
            voucher: nil
        )

        let listener = RelayListener(
            relay: relayKey.peerID,
            client: client,
            localAddress: localAddress,
            reservation: reservation
        )

        // Start accept in background
        let acceptTask = Task {
            try await listener.accept()
        }

        // Small delay to ensure accept is waiting
        try await Task.sleep(for: .milliseconds(50))

        // Enqueue a connection
        let (clientStream, _) = MockMuxedStream.createPair()
        let connection = RelayedConnection(
            stream: clientStream,
            relay: relayKey.peerID,
            remotePeer: sourceKey.peerID,
            limit: .unlimited
        )
        listener.enqueue(connection)

        // Accept should complete
        let acceptedConnection = try await acceptTask.value

        #expect(acceptedConnection.remoteAddress == connection.remoteAddress)

        try await listener.close()
    }

    @Test("close resumes waiting accept with error", .timeLimit(.minutes(1)))
    func closeResumesWaitingAccept() async throws {
        let relayKey = KeyPair.generateEd25519()

        let client = RelayClient()
        let localAddress = try Multiaddr("/p2p/\(relayKey.peerID.description)/p2p-circuit")

        let reservation = Reservation(
            relay: relayKey.peerID,
            expiration: ContinuousClock.now + .seconds(60),
            addresses: [localAddress],
            voucher: nil
        )

        let listener = RelayListener(
            relay: relayKey.peerID,
            client: client,
            localAddress: localAddress,
            reservation: reservation
        )

        // Start accept in background
        let acceptTask = Task {
            do {
                _ = try await listener.accept()
                return false  // Should not succeed
            } catch is TransportError {
                return true  // Expected
            } catch {
                return false
            }
        }

        // Small delay to ensure accept is waiting
        try await Task.sleep(for: .milliseconds(50))

        // Close the listener
        try await listener.close()

        // Accept should throw
        let gotExpectedError = await acceptTask.value
        #expect(gotExpectedError == true)
    }

    @Test("accept after close throws", .timeLimit(.minutes(1)))
    func acceptAfterCloseThrows() async throws {
        let relayKey = KeyPair.generateEd25519()

        let client = RelayClient()
        let localAddress = try Multiaddr("/p2p/\(relayKey.peerID.description)/p2p-circuit")

        let reservation = Reservation(
            relay: relayKey.peerID,
            expiration: ContinuousClock.now + .seconds(60),
            addresses: [localAddress],
            voucher: nil
        )

        let listener = RelayListener(
            relay: relayKey.peerID,
            client: client,
            localAddress: localAddress,
            reservation: reservation
        )

        // Close first
        try await listener.close()

        // Then try to accept
        do {
            _ = try await listener.accept()
            Issue.record("Expected accept to throw after close")
        } catch is TransportError {
            // Expected
        }
    }

    @Test("enqueue ignores connections when closed", .timeLimit(.minutes(1)))
    func enqueueIgnoresWhenClosed() async throws {
        let relayKey = KeyPair.generateEd25519()
        let sourceKey = KeyPair.generateEd25519()

        let client = RelayClient()
        let localAddress = try Multiaddr("/p2p/\(relayKey.peerID.description)/p2p-circuit")

        let reservation = Reservation(
            relay: relayKey.peerID,
            expiration: ContinuousClock.now + .seconds(60),
            addresses: [localAddress],
            voucher: nil
        )

        let listener = RelayListener(
            relay: relayKey.peerID,
            client: client,
            localAddress: localAddress,
            reservation: reservation
        )

        // Close the listener
        try await listener.close()

        // Try to enqueue - should be silently ignored
        let (clientStream, _) = MockMuxedStream.createPair()
        let connection = RelayedConnection(
            stream: clientStream,
            relay: relayKey.peerID,
            remotePeer: sourceKey.peerID,
            limit: .unlimited
        )
        listener.enqueue(connection)

        // No crash or error - test passes
    }

    @Test("localAddress is set correctly")
    func localAddressIsCorrect() throws {
        let relayKey = KeyPair.generateEd25519()

        let client = RelayClient()
        let localAddress = try Multiaddr("/p2p/\(relayKey.peerID.description)/p2p-circuit")

        let reservation = Reservation(
            relay: relayKey.peerID,
            expiration: ContinuousClock.now + .seconds(60),
            addresses: [localAddress],
            voucher: nil
        )

        let listener = RelayListener(
            relay: relayKey.peerID,
            client: client,
            localAddress: localAddress,
            reservation: reservation
        )

        #expect(listener.localAddress == localAddress)
        #expect(listener.relay == relayKey.peerID)
        #expect(listener.reservation.relay == relayKey.peerID)

        Task {
            try? await listener.close()
        }
    }
}

// MARK: - RelayedRawConnection Tests

@Suite("RelayedRawConnection Tests")
struct RelayedRawConnectionTests {

    @Test("remoteAddress returns connection's address")
    func remoteAddressIsCorrect() throws {
        let relayKey = KeyPair.generateEd25519()
        let sourceKey = KeyPair.generateEd25519()

        let (clientStream, _) = MockMuxedStream.createPair()
        let relayedConnection = RelayedConnection(
            stream: clientStream,
            relay: relayKey.peerID,
            remotePeer: sourceKey.peerID,
            limit: .unlimited
        )

        let rawConnection = RelayedRawConnection(relayedConnection: relayedConnection)

        #expect(rawConnection.remoteAddress == relayedConnection.remoteAddress)
        #expect(rawConnection.localAddress == nil)
    }

    @Test("read delegates to relayed connection", .timeLimit(.minutes(1)))
    func readDelegates() async throws {
        let relayKey = KeyPair.generateEd25519()
        let sourceKey = KeyPair.generateEd25519()

        let (clientStream, serverStream) = MockMuxedStream.createPair()
        let relayedConnection = RelayedConnection(
            stream: clientStream,
            relay: relayKey.peerID,
            remotePeer: sourceKey.peerID,
            limit: .unlimited
        )

        let rawConnection = RelayedRawConnection(relayedConnection: relayedConnection)

        // Write from server side
        let testData = ByteBuffer(bytes: Data("Hello from relay".utf8))
        try await serverStream.write(testData)

        // Read from raw connection
        let receivedData = try await rawConnection.read()

        #expect(receivedData == testData)
    }

    @Test("write delegates to relayed connection", .timeLimit(.minutes(1)))
    func writeDelegates() async throws {
        let relayKey = KeyPair.generateEd25519()
        let sourceKey = KeyPair.generateEd25519()

        let (clientStream, serverStream) = MockMuxedStream.createPair()
        let relayedConnection = RelayedConnection(
            stream: clientStream,
            relay: relayKey.peerID,
            remotePeer: sourceKey.peerID,
            limit: .unlimited
        )

        let rawConnection = RelayedRawConnection(relayedConnection: relayedConnection)

        // Write from raw connection
        let testData = ByteBuffer(bytes: Data("Hello to relay".utf8))
        try await rawConnection.write(testData)

        // Read from server side
        let receivedData = try await serverStream.read()

        #expect(receivedData == testData)
    }

    @Test("close delegates to relayed connection", .timeLimit(.minutes(1)))
    func closeDelegates() async throws {
        let relayKey = KeyPair.generateEd25519()
        let sourceKey = KeyPair.generateEd25519()

        let (clientStream, _) = MockMuxedStream.createPair()
        let relayedConnection = RelayedConnection(
            stream: clientStream,
            relay: relayKey.peerID,
            remotePeer: sourceKey.peerID,
            limit: .unlimited
        )

        let rawConnection = RelayedRawConnection(relayedConnection: relayedConnection)

        // Close should not throw
        try await rawConnection.close()
    }
}

// MARK: - RelayTransportError Tests

@Suite("RelayTransportError Tests")
struct RelayTransportErrorTests {

    @Test("Error cases are distinct")
    func errorCasesAreDistinct() {
        let noOpener = RelayTransportError.noOpenerConfigured
        let invalidAddr = RelayTransportError.invalidAddress("test")

        // Verify they're different
        switch noOpener {
        case .noOpenerConfigured:
            break  // Expected
        case .invalidAddress:
            Issue.record("Expected noOpenerConfigured")
        }

        switch invalidAddr {
        case .invalidAddress(let reason):
            #expect(reason == "test")
        case .noOpenerConfigured:
            Issue.record("Expected invalidAddress")
        }
    }
}
