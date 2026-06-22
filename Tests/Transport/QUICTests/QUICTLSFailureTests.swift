/// QUICTLSFailureTests - TLS provider creation-failure handling (Finding 5).
///
/// The QUIC transport validates TLS provider construction up front in
/// `dialSecured`/`listenSecured`, so certificate-generation failures propagate
/// from the call site instead of being deferred into the handshake via a
/// `FailingTLSProvider` that silently returns empty transport parameters.
///
/// Forcing certificate generation to fail for a valid Ed25519 key pair is not
/// possible from the public API, so these tests assert the deterministic,
/// observable contract of the fix:
///  - a valid key pair passes the up-front validation (dial/listen proceed),
///  - the `FailingTLSProvider` (the deferral path) surfaces failure at the
///    first handshake step rather than silently succeeding.
import Testing
import Foundation
import QUIC
@testable import P2PTransportQUIC
@testable import P2PCore

@Suite("QUIC TLS Failure Tests")
struct QUICTLSFailureTests {

    @Test("Valid key pair passes up-front TLS provider validation")
    func validKeyPairConstructsProvider() throws {
        // dialSecured/listenSecured construct this provider up front; if it
        // throws, the error propagates from the call site (fail fast).
        let keyPair = KeyPair.generateEd25519()
        let provider = try SwiftQUICTLSProvider(localKeyPair: keyPair)
        #expect(provider.localPeerID == keyPair.peerID)
    }

    @Test("FailingTLSProvider surfaces failure at handshake start, not silently")
    func failingProviderThrowsAtHandshake() async throws {
        let provider = FailingTLSProvider(error: TestTLSError.creationFailed)

        // The handshake start (first call in the handshake) must throw, so the
        // failure is surfaced rather than deferred behind empty transport
        // parameters.
        await #expect(throws: (any Error).self) {
            _ = try await provider.startHandshake(isClient: true)
        }
    }

    @Test("FailingTLSProvider reports incomplete handshake state")
    func failingProviderNotComplete() {
        let provider = FailingTLSProvider(error: TestTLSError.creationFailed)
        #expect(provider.isHandshakeComplete == false)
    }
}

private enum TestTLSError: Error {
    case creationFailed
}
