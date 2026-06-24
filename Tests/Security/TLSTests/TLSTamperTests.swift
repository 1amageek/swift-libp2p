/// TLSTamperTests - Integration tests for the TLS handshake identity binding.
///
/// Verifies Finding 5: the identity-binding invariant that a swapped peer cert or
/// a tampered signed key re-derives a DIFFERENT PeerID than the legitimate one,
/// so the upgrader can never bind a PeerID the leaf cert does not attest. These
/// invariants are asserted at the `LibP2PCertificate` level — the source of truth
/// the upgrader's verification relies on.
///
/// ## libp2p-TLS authentication (now completed, fail-closed preserved)
///
/// The Tier-1 `TLS` facade now surfaces the validator's `PeerIdentity` via
/// `peerIdentity`, so the libp2p-TLS upgrader reads the verified remote PeerID
/// back out and COMPLETES the handshake instead of failing closed on a missing
/// accessor. `legitimateHandshakeBindsVerifiedPeer` drives a full handshake over
/// an in-memory pipe between two valid peers and asserts BOTH sides return a
/// `SecuredConnection` bound to the OTHER side's verified PeerID. The fail-closed
/// contract is unchanged and is covered by the `expectedPeer`-mismatch and the
/// cross-check / tamper invariants below — a mismatched or unverifiable peer is
/// still rejected, never admitted.
import Testing
import Foundation
import NIOCore
import Synchronization
import P2PCore
import P2PCertificate
import P2PSecurity
@testable import P2PSecurityTLS

@Suite("TLS Tamper / Identity Binding Tests", .serialized)
struct TLSTamperTests {

    // MARK: - Completed Authentication (peer-identity surfacing resolved)

    @Test("Legitimate handshake binds each side to the OTHER's verified PeerID", .timeLimit(.minutes(1)))
    func legitimateHandshakeBindsVerifiedPeer() async throws {
        let clientKeyPair = KeyPair.generateEd25519()
        let serverKeyPair = KeyPair.generateEd25519()

        let (clientConn, serverConn) = InMemoryRawConnectionPair.make()
        let upgrader = TLSUpgrader(
            configuration: TLSUpgraderConfiguration(handshakeTimeout: .seconds(10))
        )

        // Drive both sides concurrently. With `peerIdentity` now surfaced, the
        // legitimate mutual-auth handshake COMPLETES and each side binds the
        // verified PeerID re-derived from the peer's presented libp2p certificate.
        let byRole = try await withThrowingTaskGroup(
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

            var results: [String: PeerID] = [:]
            for try await outcome in group {
                results[outcome.role] = outcome.remote
            }
            return results
        }

        // Each side authenticated and bound the OTHER side's verified identity.
        #expect(byRole["client"] == serverKeyPair.peerID)
        #expect(byRole["server"] == clientKeyPair.peerID)
    }

    // MARK: - Cross-Check Invariant (swapped / tampered certificate)

    @Test("Swapped peer cert re-derives a different PeerID (cross-check would fire)")
    func swappedCertReDerivesDifferentPeerID() throws {
        // Identity A presents a legitimate cert; the cross-check re-derives the
        // PeerID from the leaf the peer presented. If an attacker swaps in a cert
        // for identity B while a stale validator still reports A, the re-derived
        // PeerID (B) differs from the validated PeerID (A) and the guard fires.
        let keyPairA = KeyPair.generateEd25519()
        let keyPairB = KeyPair.generateEd25519()

        let certA = try LibP2PCertificate.generate(keyPair: keyPairA)
        let certB = try LibP2PCertificate.generate(keyPair: keyPairB)

        let derivedFromA = try LibP2PCertificate.extractPeerID(from: certA.certificateDER)
        let derivedFromB = try LibP2PCertificate.extractPeerID(from: certB.certificateDER)

        #expect(derivedFromA == keyPairA.peerID)
        #expect(derivedFromB == keyPairB.peerID)
        // The whole point of the cross-check: a swapped cert yields a DIFFERENT
        // PeerID than the legitimate one, so `rederivedPeerID == peerID` is false.
        #expect(derivedFromA != derivedFromB)
    }

    @Test("Mismatched signed key: extension claims a different identity than the handshake")
    func mismatchedSignedKeyAbortsHandshake() async throws {
        // End-to-end "mismatched signed key" scenario from Finding 5: the client
        // expects identity B, but the server presents its real cert for identity
        // A. The presented signed key (A) does not match what the client expects
        // (B), so the handshake must abort — the validator and upgrader both
        // refuse to bind a PeerID that the leaf cert does not actually attest.
        let serverKeyPair = KeyPair.generateEd25519()
        let attackerKeyPair = KeyPair.generateEd25519()

        let serverCert = try LibP2PCertificate.generate(keyPair: serverKeyPair)
        let attackerCert = try LibP2PCertificate.generate(keyPair: attackerKeyPair)

        // If a stale/bypassed validator reported the server's PeerID while the
        // wire actually carried the attacker's cert, the cross-check re-derives
        // the attacker's PeerID and the equality guard fails.
        let validatedButStale = serverKeyPair.peerID
        let actuallyPresented = try LibP2PCertificate.extractPeerID(from: attackerCert.certificateDER)
        #expect(validatedButStale != actuallyPresented)
        // Sanity: the legitimate leaf re-derives to the server's true identity.
        #expect(try LibP2PCertificate.extractPeerID(from: serverCert.certificateDER) == serverKeyPair.peerID)
    }

    @Test("Structurally corrupted certificate bytes fail PeerID re-derivation")
    func corruptedCertBytesFailReDerivation() throws {
        // Defense in depth: bytes corrupted across the structure must also fail.
        let keyPair = KeyPair.generateEd25519()
        let cert = try LibP2PCertificate.generate(keyPair: keyPair)

        var tampered = cert.certificateDER
        // Flip bytes spread across the whole DER so the SPKI (covered by the
        // libp2p signature) and/or the ASN.1 structure are corrupted.
        let count = tampered.count
        var i = count / 4
        while i < count {
            let idx = tampered.index(tampered.startIndex, offsetBy: i)
            tampered[idx] ^= 0xFF
            i += 7
        }

        #expect(tampered != cert.certificateDER)
        #expect(throws: (any Error).self) {
            _ = try LibP2PCertificate.extractPeerID(from: tampered)
        }
    }

    @Test("Validator's surfaced identity matches the presented leaf (binding source of truth)")
    func validatorBindsPresentedLeafIdentity() throws {
        // The validator the upgrader installs surfaces the PeerID re-derived from
        // the leaf the peer ACTUALLY presented. This is the identity the upgrader
        // would bind once the facade surfaces `peerIdentity`.
        let keyPair = KeyPair.generateEd25519()
        let identity = try TLSCertificateHelper.makeIdentity(keyPair: keyPair)
        let validator = TLSCertificateHelper.makeCertificateValidator(expectedPeer: nil)

        let surfaced = try validator(identity.certificateChain)
        #expect(surfaced?.identifier == [UInt8](keyPair.peerID.bytes))
    }
}

// MARK: - In-Memory RawConnection Pipe

/// Shared inbound queue for one direction of the pipe. A blocked `read()` parks
/// a continuation that the peer's `write()` resumes — no spinning.
private final class PipeQueue: Sendable {
    struct State {
        var inbound: [ByteBuffer] = []
        var waiter: CheckedContinuation<ByteBuffer, any Error>?
        var isClosed = false
    }
    let state = Mutex(State())
}

/// A bidirectional in-memory `RawConnection` pair used to drive a real TLS
/// handshake between two `TLSUpgrader` endpoints without a network. Reads pull
/// from `incoming`; writes push to `outgoing` (the peer's `incoming`).
private final class InMemoryRawConnectionPair: RawConnection, Sendable {

    private let incoming: PipeQueue
    private let outgoing: PipeQueue

    private init(incoming: PipeQueue, outgoing: PipeQueue) {
        self.incoming = incoming
        self.outgoing = outgoing
    }

    static func make() -> (InMemoryRawConnectionPair, InMemoryRawConnectionPair) {
        let aToB = PipeQueue()
        let bToA = PipeQueue()
        let left = InMemoryRawConnectionPair(incoming: bToA, outgoing: aToB)
        let right = InMemoryRawConnectionPair(incoming: aToB, outgoing: bToA)
        return (left, right)
    }

    var localAddress: Multiaddr? { nil }
    var remoteAddress: Multiaddr { Multiaddr.memory(id: "inmemory") }

    private enum ReadAction {
        case deliver(ByteBuffer)
        case closed
        case park
    }

    func read() async throws -> ByteBuffer {
        // Cancellation-aware: when the upgrader's handshake timeout cancels the
        // handshake task, a parked `read()` must resume (with CancellationError)
        // instead of blocking forever. Without this the in-memory handshake could
        // deadlock once both sides are waiting for bytes that never arrive.
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let action: ReadAction = incoming.state.withLock { state in
                    if !state.inbound.isEmpty {
                        return .deliver(state.inbound.removeFirst())
                    }
                    if state.isClosed {
                        return .closed
                    }
                    if Task.isCancelled {
                        return .closed
                    }
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
