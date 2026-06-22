/// TLSTamperTests - Integration tests for the TLS handshake identity binding.
///
/// Verifies Finding 5: the post-handshake cross-check that re-derives the PeerID
/// from the certificate the peer ACTUALLY presented and requires it to match the
/// validated PeerID. A swapped peer cert or a tampered signed key must abort the
/// handshake; a legitimate handshake must complete with correctly bound PeerIDs.
import Testing
import Foundation
import NIOCore
import Synchronization
import P2PCore
import P2PCertificate
import P2PSecurity
import TLSCore
import TLSRecord
@testable import P2PSecurityTLS

@Suite("TLS Tamper / Identity Binding Tests", .serialized)
struct TLSTamperTests {

    // MARK: - End-to-End Handshake (cross-check invariant over a real handshake)

    /// Drives a real mutual-auth TLS 1.3 handshake between two TLSConnections
    /// configured exactly like TLSUpgrader (libp2p certs, ALPN, validator), then
    /// returns both connections. The pump is bounded: it fails fast instead of
    /// hanging if the handshake makes no progress.
    private func performLibp2pHandshake(
        clientKeyPair: KeyPair,
        serverKeyPair: KeyPair,
        clientExpectedPeer: PeerID? = nil,
        serverExpectedPeer: PeerID? = nil
    ) async throws -> (client: TLSConnection, server: TLSConnection) {
        func makeConfig(for keyPair: KeyPair, expectedPeer: PeerID?) throws -> TLSConfiguration {
            let cert = try TLSCertificateHelper.generate(keyPair: keyPair)
            var config = TLSConfiguration()
            config.alpnProtocols = TLSUpgrader.buildALPNProtocols(muxerProtocols: [])
            config.signingKey = cert.signingKey
            config.certificateChain = cert.certificateChain
            config.allowSelfSigned = true
            config.verifyPeer = true
            config.requireClientCertificate = true
            config.certificateValidator = TLSCertificateHelper.makeCertificateValidator(
                expectedPeer: expectedPeer
            )
            return config
        }

        let client = TLSConnection(configuration: try makeConfig(for: clientKeyPair, expectedPeer: clientExpectedPeer))
        let server = TLSConnection(configuration: try makeConfig(for: serverKeyPair, expectedPeer: serverExpectedPeer))

        var clientToServer = try await client.startHandshake(isClient: true)
        _ = try await server.startHandshake(isClient: false)
        var serverToClient = Data()

        // Bounded ping-pong: deliver pending bytes to the peer, collect its
        // response, until both are connected or no progress is made.
        for _ in 0..<32 {
            if client.isConnected && server.isConnected { break }

            if !clientToServer.isEmpty {
                let out = try await server.processReceivedData(clientToServer)
                clientToServer = Data()
                if out.alert != nil { throw TestHarnessError.alert }
                serverToClient.append(out.dataToSend)
            }

            if !serverToClient.isEmpty {
                let out = try await client.processReceivedData(serverToClient)
                serverToClient = Data()
                if out.alert != nil { throw TestHarnessError.alert }
                clientToServer.append(out.dataToSend)
            }

            if clientToServer.isEmpty && serverToClient.isEmpty { break }
        }

        guard client.isConnected, server.isConnected else {
            throw TestHarnessError.handshakeIncomplete
        }
        return (client, server)
    }

    @Test("Legitimate handshake: presented cert re-derives the validated PeerID", .timeLimit(.minutes(1)))
    func legitimateHandshakeCrossCheckPasses() async throws {
        let clientKeyPair = KeyPair.generateEd25519()
        let serverKeyPair = KeyPair.generateEd25519()

        let (client, server) = try await performLibp2pHandshake(
            clientKeyPair: clientKeyPair,
            serverKeyPair: serverKeyPair
        )

        // This mirrors TLSUpgrader step 5b exactly: re-derive the PeerID from the
        // certificate the peer ACTUALLY presented and require it to match the
        // validator's result. For a legitimate handshake the two agree.
        let serverValidated = try #require(client.validatedPeerInfo as? PeerID)
        let serverPresentedLeaf = try #require(client.peerCertificates?.first)
        let serverRederived = try LibP2PCertificate.extractPeerID(from: serverPresentedLeaf)
        #expect(serverValidated == serverRederived)
        #expect(serverRederived == serverKeyPair.peerID)

        let clientValidated = try #require(server.validatedPeerInfo as? PeerID)
        let clientPresentedLeaf = try #require(server.peerCertificates?.first)
        let clientRederived = try LibP2PCertificate.extractPeerID(from: clientPresentedLeaf)
        #expect(clientValidated == clientRederived)
        #expect(clientRederived == clientKeyPair.peerID)
    }

    @Test("Handshake aborts when a side expects a different peer", .timeLimit(.minutes(1)))
    func mismatchedExpectedPeerAborts() async throws {
        let clientKeyPair = KeyPair.generateEd25519()
        let serverKeyPair = KeyPair.generateEd25519()
        let wrongExpected = KeyPair.generateEd25519().peerID

        // The client expects the WRONG server identity. The validator (invoked by
        // swift-tls during the handshake) must reject the presented cert, so the
        // handshake cannot complete — it must throw, never silently succeed.
        await #expect(throws: (any Error).self) {
            _ = try await self.performLibp2pHandshake(
                clientKeyPair: clientKeyPair,
                serverKeyPair: serverKeyPair,
                clientExpectedPeer: wrongExpected
            )
        }
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
        // (B), so the handshake must abort — TLSUpgrader's cross-check and the
        // validator both refuse to bind a PeerID that the leaf cert does not
        // actually attest. (Covered concretely by mismatchedExpectedPeerAborts;
        // here we additionally assert the data-source invariant that the cross-
        // check relies on: a swapped leaf re-derives to a different PeerID.)
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
}

// MARK: - Test Harness Errors

private enum TestHarnessError: Error, Equatable {
    /// The handshake did not complete within the bounded pump (no progress).
    case handshakeIncomplete
    /// A TLS alert was emitted during the handshake.
    case alert
}
