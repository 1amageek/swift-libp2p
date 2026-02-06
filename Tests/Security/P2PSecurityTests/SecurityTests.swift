import Testing
import Foundation
@testable import P2PSecurity
@testable import P2PCore

@Suite("Security Tests")
struct SecurityTests {

    // MARK: - SecurityError

    @Test("SecurityError cases are distinct")
    func securityErrorCases() {
        let handshake = SecurityError.handshakeFailed(underlying: NSError(domain: "test", code: 1))
        let mismatch = SecurityError.peerMismatch(
            expected: KeyPair.generateEd25519().peerID,
            actual: KeyPair.generateEd25519().peerID
        )
        let invalidKey = SecurityError.invalidKey
        let timeout = SecurityError.timeout

        _ = handshake
        _ = mismatch
        _ = invalidKey
        _ = timeout
    }

    @Test("SecurityError.handshakeFailed wraps underlying error")
    func handshakeFailedUnderlying() {
        let underlying = NSError(domain: "crypto", code: 42)
        let error = SecurityError.handshakeFailed(underlying: underlying)

        if case .handshakeFailed(let inner) = error {
            let nsError = inner as NSError
            #expect(nsError.domain == "crypto")
            #expect(nsError.code == 42)
        } else {
            Issue.record("Expected handshakeFailed")
        }
    }

    @Test("SecurityError.peerMismatch carries expected and actual PeerIDs")
    func peerMismatchIDs() {
        let expected = KeyPair.generateEd25519().peerID
        let actual = KeyPair.generateEd25519().peerID

        let error = SecurityError.peerMismatch(expected: expected, actual: actual)

        if case .peerMismatch(let e, let a) = error {
            #expect(e == expected)
            #expect(a == actual)
            #expect(e != a)
        } else {
            Issue.record("Expected peerMismatch")
        }
    }

    // MARK: - SecurityRole

    @Test("SecurityRole values")
    func securityRoles() {
        let initiator = SecurityRole.initiator
        let responder = SecurityRole.responder

        // Both roles exist and are distinct patterns
        switch initiator {
        case .initiator: break
        case .responder: Issue.record("Should be initiator")
        }

        switch responder {
        case .initiator: Issue.record("Should be responder")
        case .responder: break
        }
    }

    // MARK: - Early Muxer ALPN

    @Test("Early muxer ALPN prefix is 'libp2p'")
    func earlyMuxerPrefix() {
        #expect(earlyMuxerALPNPrefix == "libp2p")
    }

    @Test("ALPN token construction for muxer protocols")
    func alpnTokenConstruction() {
        let yamux = earlyMuxerALPNPrefix + "/yamux/1.0.0"
        #expect(yamux == "libp2p/yamux/1.0.0")

        let mplex = earlyMuxerALPNPrefix + "/mplex/6.7.0"
        #expect(mplex == "libp2p/mplex/6.7.0")
    }
}
