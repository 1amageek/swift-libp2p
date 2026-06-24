/// LibP2PCertificateHelperDERTests - asserts the libp2p-over-QUIC certificate
/// path now goes through the Embedded-clean P2PCoreDER codec, and that the
/// SignedKey-verify / PeerID-derivation boundary stays fail-closed.
///
/// This mirrors `LibP2PCertificateDERTests` (the swift-certificates RPK path)
/// for the QUIC transport: we build a libp2p self-signed leaf cert directly with
/// the P2PCoreDER primitives — the same primitives
/// `LibP2PCertificateHelper.generateCertificate` now uses — and assert that a
/// *legitimately* signed cert is accepted (binding the right PeerID) while a
/// *tampered SignedKey signature* is rejected (the QUIC peer-auth boundary must
/// never accept a forged identity).

import Testing
import Foundation
import Crypto
import P2PCore
import P2PCoreDER
@testable import P2PTransportQUIC

@Suite("LibP2PCertificateHelper P2PCoreDER path")
struct LibP2PCertificateHelperDERTests {

    /// Builds a libp2p self-signed leaf cert using the P2PCoreDER primitives,
    /// embedding a caller-supplied (possibly forged) SignedKey signature over a
    /// fresh ephemeral TLS key's SPKI. Mirrors
    /// `LibP2PCertificateHelper.generateCertificate` except the SignedKey
    /// signature is injected, so we can supply a tampered one.
    private func buildCert(
        identityKeyPair: KeyPair,
        signedKeySignature: Data
    ) throws -> Data {
        let tlsKey = P256.Signing.PrivateKey()
        let spkiDER = try SubjectPublicKeyInfoDER.encodeP256(
            uncompressedPoint65: [UInt8](tlsKey.publicKey.x963Representation)
        )
        let ext = LibP2PSignedKeyDER.encode(
            protobufPubKey: [UInt8](identityKeyPair.publicKey.protobufEncoded),
            signature: [UInt8](signedKeySignature)
        )
        var serial = [UInt8](repeating: 0x11, count: 16)
        serial[0] &= 0x7F
        let now = Int64(Date().timeIntervalSince1970)
        let cert = try LibP2PCertificateDER.buildSelfSignedCert(
            spkiDER: spkiDER,
            signedKeyExtension: ext,
            serial16: serial,
            notBefore: now - 3600,
            notAfter: now + 86_400,
            signFn: { (tbs: [UInt8]) throws(CertHelperTestSignError) -> [UInt8] in
                do {
                    return Array(try tlsKey.signature(for: Data(tbs)).derRepresentation)
                } catch {
                    throw CertHelperTestSignError.failed
                }
            }
        )
        return Data(cert)
    }

    /// Builds a cert carrying a VALID SignedKey signature over its own SPKI,
    /// identical to what `generateCertificate` produces.
    private func buildValidlySignedCert(
        identityKeyPair: KeyPair
    ) throws -> (cert: Data, peerID: PeerID) {
        let tlsKey = P256.Signing.PrivateKey()
        let spkiDER = try SubjectPublicKeyInfoDER.encodeP256(
            uncompressedPoint65: [UInt8](tlsKey.publicKey.x963Representation)
        )
        let message = LibP2PIdentity.signatureMessage(spkiDER: spkiDER)
        let signature = try identityKeyPair.sign(Data(message))
        let ext = LibP2PSignedKeyDER.encode(
            protobufPubKey: [UInt8](identityKeyPair.publicKey.protobufEncoded),
            signature: [UInt8](signature)
        )
        var serial = [UInt8](repeating: 0x22, count: 16)
        serial[0] &= 0x7F
        let now = Int64(Date().timeIntervalSince1970)
        let cert = try LibP2PCertificateDER.buildSelfSignedCert(
            spkiDER: spkiDER,
            signedKeyExtension: ext,
            serial16: serial,
            notBefore: now - 3600,
            notAfter: now + 86_400,
            signFn: { (tbs: [UInt8]) throws(CertHelperTestSignError) -> [UInt8] in
                do {
                    return Array(try tlsKey.signature(for: Data(tbs)).derRepresentation)
                } catch {
                    throw CertHelperTestSignError.failed
                }
            }
        )
        return (Data(cert), identityKeyPair.peerID)
    }

    @Test("generateCertificate output validates to the right PeerID")
    func generatedCertValidates() throws {
        let keyPair = KeyPair.generateEd25519()
        let (certDER, _) = try LibP2PCertificateHelper.generateCertificate(keyPair: keyPair)

        let peerID = try LibP2PCertificateHelper.validatePeerID(
            from: certDER,
            expectedPeerID: nil
        )
        #expect(peerID == keyPair.peerID)
    }

    @Test("P2PCoreDER-built cert with a valid SignedKey is accepted and binds the right PeerID")
    func p2pCoreDERBuiltCertAccepted() throws {
        let keyPair = KeyPair.generateEd25519()
        let (cert, expectedPeerID) = try buildValidlySignedCert(identityKeyPair: keyPair)

        let peerID = try LibP2PCertificateHelper.validatePeerID(
            from: cert,
            expectedPeerID: expectedPeerID
        )
        #expect(peerID == expectedPeerID)
    }

    @Test("Tampered SignedKey signature is rejected (fail-closed)")
    func tamperedSignedKeySignatureRejected() throws {
        let keyPair = KeyPair.generateEd25519()

        // A 64-byte all-zero signature has a structurally valid Ed25519 length
        // but is NOT a valid signature over the message: verification must fail
        // and validatePeerID must throw, never accept.
        let forgedSignature = Data(repeating: 0x00, count: 64)
        let cert = try buildCert(identityKeyPair: keyPair, signedKeySignature: forgedSignature)

        #expect(throws: TLSCertificateError.self) {
            _ = try LibP2PCertificateHelper.validatePeerID(from: cert, expectedPeerID: nil)
        }
    }

    @Test("SignedKey signature from the WRONG identity is rejected (fail-closed)")
    func wrongIdentitySignatureRejected() throws {
        let realIdentity = KeyPair.generateEd25519()
        let attacker = KeyPair.generateEd25519()

        // The extension claims `realIdentity`'s public key, but the signature is
        // produced by `attacker`. Because the embedded public key does not match
        // the signing key, verification must fail closed.
        let tlsKey = P256.Signing.PrivateKey()
        let spkiDER = try SubjectPublicKeyInfoDER.encodeP256(
            uncompressedPoint65: [UInt8](tlsKey.publicKey.x963Representation)
        )
        let message = LibP2PIdentity.signatureMessage(spkiDER: spkiDER)
        let attackerSignature = try attacker.sign(Data(message))
        let ext = LibP2PSignedKeyDER.encode(
            protobufPubKey: [UInt8](realIdentity.publicKey.protobufEncoded),
            signature: [UInt8](attackerSignature)
        )
        var serial = [UInt8](repeating: 0x33, count: 16)
        serial[0] &= 0x7F
        let now = Int64(Date().timeIntervalSince1970)
        let cert = Data(try LibP2PCertificateDER.buildSelfSignedCert(
            spkiDER: spkiDER,
            signedKeyExtension: ext,
            serial16: serial,
            notBefore: now - 3600,
            notAfter: now + 86_400,
            signFn: { (tbs: [UInt8]) throws(CertHelperTestSignError) -> [UInt8] in
                do {
                    return Array(try tlsKey.signature(for: Data(tbs)).derRepresentation)
                } catch {
                    throw CertHelperTestSignError.failed
                }
            }
        ))

        #expect(throws: TLSCertificateError.self) {
            _ = try LibP2PCertificateHelper.validatePeerID(from: cert, expectedPeerID: nil)
        }
    }

    @Test("Certificate with a non-SignedKey extension is rejected (fail-closed)")
    func nonSignedKeyExtensionRejected() throws {
        // The extension value is not a SignedKey SEQUENCE: SignedKey parsing must
        // fail closed.
        let bogusExt: [UInt8] = [0x04, 0x01, 0x00]  // OCTET STRING, not a SEQUENCE
        let tlsKey = P256.Signing.PrivateKey()
        let spkiDER = try SubjectPublicKeyInfoDER.encodeP256(
            uncompressedPoint65: [UInt8](tlsKey.publicKey.x963Representation)
        )
        var serial = [UInt8](repeating: 0x44, count: 16)
        serial[0] &= 0x7F
        let now = Int64(Date().timeIntervalSince1970)
        let cert = Data(try LibP2PCertificateDER.buildSelfSignedCert(
            spkiDER: spkiDER,
            signedKeyExtension: bogusExt,
            serial16: serial,
            notBefore: now - 3600,
            notAfter: now + 86_400,
            signFn: { (tbs: [UInt8]) throws(CertHelperTestSignError) -> [UInt8] in
                do {
                    return Array(try tlsKey.signature(for: Data(tbs)).derRepresentation)
                } catch {
                    throw CertHelperTestSignError.failed
                }
            }
        ))

        #expect(throws: TLSCertificateError.self) {
            _ = try LibP2PCertificateHelper.validatePeerID(from: cert, expectedPeerID: nil)
        }
    }

    @Test("PeerID mismatch against an expected PeerID is rejected (fail-closed)")
    func peerIDMismatchRejected() throws {
        let keyPair = KeyPair.generateEd25519()
        let (certDER, _) = try LibP2PCertificateHelper.generateCertificate(keyPair: keyPair)
        let wrongPeerID = KeyPair.generateEd25519().peerID

        #expect(throws: TLSCertificateError.self) {
            _ = try LibP2PCertificateHelper.validatePeerID(
                from: certDER,
                expectedPeerID: wrongPeerID
            )
        }
    }
}

private enum CertHelperTestSignError: Error {
    case failed
}
