/// TLSHandshakeE2ETests - End-to-end libp2p-TLS mutual-auth handshake.
///
/// Drives a full libp2p TLS 1.3 handshake between two `TLSUpgrader` endpoints over
/// an in-memory `RawConnection` pipe (no network). With the swift-tls facade now
/// surfacing `peerIdentity`, the handshake COMPLETES and both sides bind the
/// verified remote PeerID — the authentication that was previously fail-closed
/// blocked by the missing peer-identity accessor.
import Testing
import Foundation
import NIOCore
import Synchronization
import P2PCore
import P2PCertificate
import P2PSecurity
@testable import P2PSecurityTLS

@Suite("TLS Handshake E2E Tests", .serialized)
struct TLSHandshakeE2ETests {

    @Test("Mutual-auth handshake completes and binds the verified remote PeerID", .timeLimit(.minutes(1)))
    func mutualAuthHandshakeBindsPeerID() async throws {
        let clientKeyPair = KeyPair.generateEd25519()
        let serverKeyPair = KeyPair.generateEd25519()

        let (clientConn, serverConn) = E2EInMemoryPair.make()
        let upgrader = TLSUpgrader(
            configuration: TLSUpgraderConfiguration(handshakeTimeout: .seconds(10))
        )

        let result = try await withThrowingTaskGroup(
            of: (role: String, remote: PeerID).self
        ) { group in
            group.addTask {
                let secured = try await upgrader.secure(
                    clientConn,
                    localKeyPair: clientKeyPair,
                    as: .initiator,
                    expectedPeer: serverKeyPair.peerID
                )
                return ("client", secured.remotePeer)
            }
            group.addTask {
                let secured = try await upgrader.secure(
                    serverConn,
                    localKeyPair: serverKeyPair,
                    as: .responder,
                    expectedPeer: nil
                )
                return ("server", secured.remotePeer)
            }

            var byRole: [String: PeerID] = [:]
            for try await outcome in group {
                byRole[outcome.role] = outcome.remote
            }
            return byRole
        }

        // The client authenticated the server's PeerID; the server authenticated
        // the client's. Each side binds the OTHER side's verified identity.
        #expect(result["client"] == serverKeyPair.peerID)
        #expect(result["server"] == clientKeyPair.peerID)
    }

    @Test("Handshake fails closed on an expected-peer mismatch", .timeLimit(.minutes(1)))
    func handshakeFailsClosedOnExpectedPeerMismatch() async throws {
        let clientKeyPair = KeyPair.generateEd25519()
        let serverKeyPair = KeyPair.generateEd25519()
        let wrongExpected = KeyPair.generateEd25519().peerID

        let (clientConn, serverConn) = E2EInMemoryPair.make()
        let upgrader = TLSUpgrader(
            configuration: TLSUpgraderConfiguration(handshakeTimeout: .seconds(10))
        )

        let outcomes: [Bool] = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    // The client expects a peer that the server is NOT — the
                    // validator/upgrader must reject, never admit the mismatch.
                    _ = try await upgrader.secure(
                        clientConn,
                        localKeyPair: clientKeyPair,
                        as: .initiator,
                        expectedPeer: wrongExpected
                    )
                    return true  // accepted — a security failure
                } catch {
                    return false  // rejected — the required fail-closed outcome
                }
            }
            group.addTask {
                do {
                    _ = try await upgrader.secure(
                        serverConn,
                        localKeyPair: serverKeyPair,
                        as: .responder,
                        expectedPeer: nil
                    )
                    return true
                } catch {
                    return false
                }
            }
            var results: [Bool] = []
            for await accepted in group {
                results.append(accepted)
            }
            return results
        }

        // The client side MUST have rejected the mismatched peer.
        #expect(outcomes.contains(false))
    }
}

// MARK: - In-Memory RawConnection Pipe

private final class E2EPipeQueue: Sendable {
    struct State {
        var inbound: [ByteBuffer] = []
        var waiter: CheckedContinuation<ByteBuffer, any Error>?
        var isClosed = false
    }
    let state = Mutex(State())
}

private final class E2EInMemoryPair: RawConnection, Sendable {

    private let incoming: E2EPipeQueue
    private let outgoing: E2EPipeQueue

    private init(incoming: E2EPipeQueue, outgoing: E2EPipeQueue) {
        self.incoming = incoming
        self.outgoing = outgoing
    }

    static func make() -> (E2EInMemoryPair, E2EInMemoryPair) {
        let aToB = E2EPipeQueue()
        let bToA = E2EPipeQueue()
        let left = E2EInMemoryPair(incoming: bToA, outgoing: aToB)
        let right = E2EInMemoryPair(incoming: aToB, outgoing: bToA)
        return (left, right)
    }

    var localAddress: Multiaddr? { nil }
    var remoteAddress: Multiaddr { Multiaddr.memory(id: "inmemory-e2e") }

    private enum ReadAction {
        case deliver(ByteBuffer)
        case closed
        case park
    }

    func read() async throws -> ByteBuffer {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let action: ReadAction = incoming.state.withLock { state in
                    if !state.inbound.isEmpty {
                        return .deliver(state.inbound.removeFirst())
                    }
                    if state.isClosed { return .closed }
                    if Task.isCancelled { return .closed }
                    state.waiter = continuation
                    return .park
                }
                switch action {
                case .deliver(let buffer):
                    continuation.resume(returning: buffer)
                case .closed:
                    continuation.resume(throwing: CancellationError())
                case .park:
                    break
                }
            }
        } onCancel: {
            let waiter: CheckedContinuation<ByteBuffer, any Error>? = incoming.state.withLock { state in
                let waiter = state.waiter
                state.waiter = nil
                return waiter
            }
            waiter?.resume(throwing: CancellationError())
        }
    }

    func write(_ data: ByteBuffer) async throws {
        let waiter: CheckedContinuation<ByteBuffer, any Error>? = outgoing.state.withLock { state in
            guard !state.isClosed else { return nil }
            if let waiter = state.waiter {
                state.waiter = nil
                return waiter
            }
            state.inbound.append(data)
            return nil
        }
        waiter?.resume(returning: data)
    }

    func close() async throws {
        for queue in [incoming, outgoing] {
            let waiter: CheckedContinuation<ByteBuffer, any Error>? = queue.state.withLock { state in
                state.isClosed = true
                let waiter = state.waiter
                state.waiter = nil
                return waiter
            }
            waiter?.resume(throwing: TLSError.connectionClosed)
        }
    }
}
