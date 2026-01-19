/// Tests for SwiftQUICTLSProvider and LibP2PCertificateHelper.

import Testing
import Foundation
@testable import P2PTransportQUIC
@testable import P2PCore

@Suite("SwiftQUIC TLS Provider Tests")
struct SwiftQUICTLSProviderTests {

    // MARK: - Initialization Tests

    @Test("Provider initializes successfully")
    func initializesSuccessfully() throws {
        let keyPair = KeyPair.generateEd25519()
        let provider = try SwiftQUICTLSProvider(localKeyPair: keyPair)

        #expect(provider.localPeerID == keyPair.peerID)
        #expect(provider.remotePeerID == nil)
        #expect(!provider.isHandshakeComplete)
    }

    @Test("Provider with expected remote PeerID")
    func withExpectedRemotePeerID() throws {
        let localKeyPair = KeyPair.generateEd25519()
        let expectedPeerID = KeyPair.generateEd25519().peerID

        let provider = try SwiftQUICTLSProvider(
            localKeyPair: localKeyPair,
            expectedRemotePeerID: expectedPeerID
        )

        #expect(provider.localPeerID == localKeyPair.peerID)
    }
}

@Suite("LibP2PCertificateHelper Tests")
struct LibP2PCertificateHelperTests {

    // MARK: - Certificate Generation Tests

    @Test("Generates certificate with Ed25519 key")
    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
    func generatesCertificateEd25519() throws {
        let keyPair = KeyPair.generateEd25519()

        let (certificateDER, signingKey) = try LibP2PCertificateHelper.generateCertificate(
            keyPair: keyPair
        )

        #expect(!certificateDER.isEmpty)
        #expect(!signingKey.publicKeyBytes.isEmpty)
    }

    // MARK: - SignedKey Encoding Tests

    @Test("Encodes and parses SignedKey")
    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
    func encodesAndParsesSignedKey() throws {
        let publicKey = Data([0x01, 0x02, 0x03, 0x04])
        let signature = Data([0x05, 0x06, 0x07, 0x08])

        // Encode
        let der = try LibP2PCertificateHelper.encodeSignedKey(
            publicKey: publicKey,
            signature: signature
        )

        // Parse
        let (parsedPublicKey, parsedSignature) = try LibP2PCertificateHelper.parseSignedKey(from: der)

        #expect(parsedPublicKey == publicKey)
        #expect(parsedSignature == signature)
    }

    @Test("Empty data encodes correctly")
    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
    func emptyDataEncoding() throws {
        let der = try LibP2PCertificateHelper.encodeSignedKey(
            publicKey: Data(),
            signature: Data()
        )

        let (parsedPublicKey, parsedSignature) = try LibP2PCertificateHelper.parseSignedKey(from: der)

        #expect(parsedPublicKey.isEmpty)
        #expect(parsedSignature.isEmpty)
    }

    @Test("Large data encodes correctly")
    @available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
    func largeDataEncoding() throws {
        let publicKey = Data(repeating: 0xAB, count: 1000)
        let signature = Data(repeating: 0xCD, count: 500)

        let der = try LibP2PCertificateHelper.encodeSignedKey(
            publicKey: publicKey,
            signature: signature
        )

        let (parsedPublicKey, parsedSignature) = try LibP2PCertificateHelper.parseSignedKey(from: der)

        #expect(parsedPublicKey == publicKey)
        #expect(parsedSignature == signature)
    }
}

@Suite("QUICTransport TLS Mode Tests")
struct QUICTransportTLSModeTests {

    @Test("QUICTransport defaults to swiftQUIC mode")
    func defaultsToSwiftQUICMode() {
        let transport = QUICTransport()
        #expect(transport.canDial(try! Multiaddr("/ip4/127.0.0.1/udp/4001/quic-v1")))
    }

    @Test("QUICTransport with explicit swiftQUIC mode")
    func explicitSwiftQUICMode() {
        let transport = QUICTransport(tlsProviderMode: .swiftQUIC)
        #expect(transport.canDial(try! Multiaddr("/ip4/127.0.0.1/udp/4001/quic-v1")))
    }
}
