import Testing
import Foundation
@testable import P2PSecurityPlaintext
@testable import P2PSecurity
@testable import P2PCore
import Synchronization

@Suite("Plaintext Exchange Tests")
struct PlaintextExchangeTests {

    // MARK: - Exchange Encode/Decode Tests

    @Test("Exchange encode/decode round trip")
    func exchangeRoundTrip() throws {
        let keyPair = KeyPair.generateEd25519()
        let original = Exchange(peerID: keyPair.peerID, publicKey: keyPair.publicKey)

        let encoded = original.encode()
        let decoded = try Exchange.decode(from: encoded)

        #expect(decoded.peerID == original.peerID)
        #expect(decoded.publicKey == original.publicKey)
    }

    @Test("Exchange encoding includes length prefix")
    func exchangeEncodingHasLengthPrefix() throws {
        let keyPair = KeyPair.generateEd25519()
        let exchange = Exchange(peerID: keyPair.peerID, publicKey: keyPair.publicKey)

        let encoded = exchange.encode()

        // First bytes should be varint length prefix
        let (length, lengthBytes) = try Varint.decode(encoded)
        #expect(encoded.count == lengthBytes + Int(length))
    }

    @Test("Exchange decode with insufficient data throws error")
    func exchangeDecodeInsufficientData() {
        // Only varint prefix, no actual data
        let data = Data([0x10])  // Length = 16, but no content

        #expect(throws: PlaintextError.insufficientData) {
            _ = try Exchange.decode(from: data)
        }
    }

    @Test("Exchange decode with missing fields throws error")
    func exchangeDecodeMissingFields() throws {
        // Empty protobuf with length prefix
        var data = Data()
        data.append(contentsOf: Varint.encode(UInt64(0)))

        #expect(throws: PlaintextError.invalidExchange) {
            _ = try Exchange.decode(from: data)
        }
    }
}

@Suite("Plaintext Handshake Tests", .serialized)
struct PlaintextHandshakeTests {

    @Test("Successful handshake between two peers")
    func successfulHandshake() async throws {
        let aliceKeyPair = KeyPair.generateEd25519()
        let bobKeyPair = KeyPair.generateEd25519()

        let (aliceConn, bobConn) = MockConnectionPair.create()

        let aliceUpgrader = PlaintextUpgrader()
        let bobUpgrader = PlaintextUpgrader()

        async let aliceSecured = aliceUpgrader.secure(
            aliceConn,
            localKeyPair: aliceKeyPair,
            as: .initiator,
            expectedPeer: nil
        )

        async let bobSecured = bobUpgrader.secure(
            bobConn,
            localKeyPair: bobKeyPair,
            as: .responder,
            expectedPeer: nil
        )

        let (alice, bob) = try await (aliceSecured, bobSecured)

        #expect(alice.remotePeer == bobKeyPair.peerID)
        #expect(bob.remotePeer == aliceKeyPair.peerID)
        #expect(alice.localPeer == aliceKeyPair.peerID)
        #expect(bob.localPeer == bobKeyPair.peerID)
    }

    @Test("Handshake with expected peer succeeds")
    func handshakeWithExpectedPeer() async throws {
        let aliceKeyPair = KeyPair.generateEd25519()
        let bobKeyPair = KeyPair.generateEd25519()

        let (aliceConn, bobConn) = MockConnectionPair.create()

        let aliceUpgrader = PlaintextUpgrader()
        let bobUpgrader = PlaintextUpgrader()

        // Alice expects Bob
        async let aliceSecured = aliceUpgrader.secure(
            aliceConn,
            localKeyPair: aliceKeyPair,
            as: .initiator,
            expectedPeer: bobKeyPair.peerID
        )

        async let bobSecured = bobUpgrader.secure(
            bobConn,
            localKeyPair: bobKeyPair,
            as: .responder,
            expectedPeer: nil
        )

        let (alice, bob) = try await (aliceSecured, bobSecured)

        #expect(alice.remotePeer == bobKeyPair.peerID)
        #expect(bob.remotePeer == aliceKeyPair.peerID)
    }

    @Test("Handshake with wrong expected peer fails")
    func handshakeWithWrongExpectedPeer() async throws {
        let aliceKeyPair = KeyPair.generateEd25519()
        let bobKeyPair = KeyPair.generateEd25519()
        let charlieKeyPair = KeyPair.generateEd25519()

        let (aliceConn, bobConn) = MockConnectionPair.create()

        let aliceUpgrader = PlaintextUpgrader()
        let bobUpgrader = PlaintextUpgrader()

        // Alice expects Charlie but connects to Bob
        async let aliceResult: Result<any SecuredConnection, Error> = {
            do {
                let conn = try await aliceUpgrader.secure(
                    aliceConn,
                    localKeyPair: aliceKeyPair,
                    as: .initiator,
                    expectedPeer: charlieKeyPair.peerID  // Wrong peer!
                )
                return .success(conn)
            } catch {
                return .failure(error)
            }
        }()

        async let bobResult: Result<any SecuredConnection, Error> = {
            do {
                let conn = try await bobUpgrader.secure(
                    bobConn,
                    localKeyPair: bobKeyPair,
                    as: .responder,
                    expectedPeer: nil
                )
                return .success(conn)
            } catch {
                return .failure(error)
            }
        }()

        let (alice, _) = await (aliceResult, bobResult)

        // Alice should fail with peer mismatch
        switch alice {
        case .success:
            Issue.record("Expected handshake to fail with peer mismatch")
        case .failure(let error):
            guard case SecurityError.peerMismatch(let expected, let actual) = error else {
                Issue.record("Expected SecurityError.peerMismatch, got \(error)")
                return
            }
            #expect(expected == charlieKeyPair.peerID)
            #expect(actual == bobKeyPair.peerID)
        }
    }

    @Test("Protocol ID is correct")
    func protocolID() {
        let upgrader = PlaintextUpgrader()
        #expect(upgrader.protocolID == "/plaintext/2.0.0")
    }
}

@Suite("Plaintext Connection Tests", .serialized)
struct PlaintextConnectionTests {

    @Test("Data exchange through plaintext connection")
    func dataExchange() async throws {
        let aliceKeyPair = KeyPair.generateEd25519()
        let bobKeyPair = KeyPair.generateEd25519()

        let (aliceConn, bobConn) = MockConnectionPair.create()

        let aliceUpgrader = PlaintextUpgrader()
        let bobUpgrader = PlaintextUpgrader()

        async let aliceSecured = aliceUpgrader.secure(
            aliceConn,
            localKeyPair: aliceKeyPair,
            as: .initiator,
            expectedPeer: nil
        )

        async let bobSecured = bobUpgrader.secure(
            bobConn,
            localKeyPair: bobKeyPair,
            as: .responder,
            expectedPeer: nil
        )

        let (alice, bob) = try await (aliceSecured, bobSecured)

        // Send data from Alice to Bob
        let testData = Data("Hello, Bob!".utf8)
        try await alice.write(testData)

        let received = try await bob.read()
        #expect(received == testData)

        // Send data from Bob to Alice
        let response = Data("Hello, Alice!".utf8)
        try await bob.write(response)

        let aliceReceived = try await alice.read()
        #expect(aliceReceived == response)
    }
}

// MARK: - Mock Connection Pair

/// A pair of connected mock connections for testing bidirectional communication.
final class MockConnectionPair {
    /// Creates a pair of connected mock connections.
    static func create() -> (MockConnection, MockConnection) {
        let aToB = AsyncStream<Data>.makeStream()
        let bToA = AsyncStream<Data>.makeStream()

        let a = MockConnection(
            readStream: bToA.stream,
            writeContinuation: aToB.continuation
        )
        let b = MockConnection(
            readStream: aToB.stream,
            writeContinuation: bToA.continuation
        )

        return (a, b)
    }
}

/// A mock connection for testing.
final class MockConnection: RawConnection, Sendable {
    var localAddress: Multiaddr? { nil }
    var remoteAddress: Multiaddr {
        Multiaddr.tcp(host: "127.0.0.1", port: 0)
    }

    private let state: Mutex<ConnectionState>
    private let writeContinuation: AsyncStream<Data>.Continuation
    private let readStream: AsyncStream<Data>
    private nonisolated(unsafe) var readIterator: AsyncStream<Data>.Iterator?

    private struct ConnectionState {
        var isClosed: Bool = false
    }

    init(readStream: AsyncStream<Data>, writeContinuation: AsyncStream<Data>.Continuation) {
        self.readStream = readStream
        self.readIterator = readStream.makeAsyncIterator()
        self.state = Mutex(ConnectionState())
        self.writeContinuation = writeContinuation
    }

    func read() async throws -> Data {
        let isClosed = state.withLock { $0.isClosed }
        if isClosed {
            throw MockConnectionError.connectionClosed
        }
        guard let data = await readIterator?.next() else {
            throw MockConnectionError.connectionClosed
        }
        return data
    }

    func write(_ data: Data) async throws {
        let isClosed = state.withLock { $0.isClosed }
        if isClosed {
            throw MockConnectionError.connectionClosed
        }
        writeContinuation.yield(data)
    }

    func close() async throws {
        state.withLock { $0.isClosed = true }
        writeContinuation.finish()
    }
}

enum MockConnectionError: Error {
    case connectionClosed
}
