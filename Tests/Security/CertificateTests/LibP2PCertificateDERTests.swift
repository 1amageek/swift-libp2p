/// LibP2PCertificateDERTests - M6b: asserts the libp2p RPK certificate path now
/// goes through the Embedded-clean P2PCoreDER codec, and that the
/// SignedKey-verify / PeerID-derivation boundary stays fail-closed.
///
/// These complement the existing `LibP2PCertificateTests` (which already prove a
/// generated cert round-trips to the correct PeerID): here we additionally build
/// a cert directly with the P2PCoreDER primitives — the same primitives
/// `LibP2PCertificate.generate` now uses — and assert that a *legitimately*
/// signed cert is accepted while a *tampered SignedKey signature* is rejected.
import Testing
import Foundation
import Crypto
import P2PCore
import P2PCoreDER
@testable import P2PCertificate

@Suite("LibP2PCertificate P2PCoreDER path")
struct LibP2PCertificateDERTests {

    /// Builds a libp2p self-signed leaf cert using the P2PCoreDER primitives,
    /// embedding an arbitrary (possibly forged) SignedKey signature. This mirrors
    /// `LibP2PCertificate.generate` exactly except the SignedKey signature is
    /// supplied by the caller, so we can inject a tampered one.
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
            signFn: { (tbs: [UInt8]) throws(CertTestSignError) -> [UInt8] in
                do {
                    return Array(try tlsKey.signature(for: Data(tbs)).derRepresentation)
                } catch {
                    throw CertTestSignError.failed
                }
            }
        )
        return Data(cert)
    }

    /// Re-derives the libp2p signature over "libp2p-tls-handshake:" || SPKI for a
    /// given cert + identity key, so the cert carries a VALID SignedKey signature.
    private func buildValidlySignedCert(identityKeyPair: KeyPair) throws -> (cert: Data, peerID: PeerID) {
        // Build once with a placeholder to discover the SPKI is not exposed, so
        // instead build the SPKI/signature ourselves (identical to generate()).
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
            signFn: { (tbs: [UInt8]) throws(CertTestSignError) -> [UInt8] in
                do {
                    return Array(try tlsKey.signature(for: Data(tbs)).derRepresentation)
                } catch {
                    throw CertTestSignError.failed
                }
            }
        )
        return (Data(cert), identityKeyPair.peerID)
    }

    @Test("P2PCoreDER-built cert with a valid SignedKey is accepted and binds the right PeerID")
    func p2pCoreDERBuiltCertAccepted() throws {
        let keyPair = KeyPair.generateEd25519()
        let (cert, expectedPeerID) = try buildValidlySignedCert(identityKeyPair: keyPair)

        let peerID = try LibP2PCertificate.extractPeerID(from: cert)
        #expect(peerID == expectedPeerID)
    }

    @Test("Tampered SignedKey signature is rejected (fail-closed)")
    func tamperedSignedKeySignatureRejected() throws {
        let keyPair = KeyPair.generateEd25519()

        // A 64-byte all-zero signature is structurally a valid Ed25519 signature
        // length but is NOT a valid signature over the message: verification must
        // fail and extractPeerID must throw, never accept.
        let forgedSignature = Data(repeating: 0x00, count: 64)
        let cert = try buildCert(identityKeyPair: keyPair, signedKeySignature: forgedSignature)

        #expect(throws: LibP2PCertificateError.self) {
            _ = try LibP2PCertificate.extractPeerID(from: cert)
        }
    }

    @Test("SignedKey signature from the WRONG identity is rejected (fail-closed)")
    func wrongIdentitySignatureRejected() throws {
        let realIdentity = KeyPair.generateEd25519()
        let attacker = KeyPair.generateEd25519()

        // The extension claims `realIdentity`'s public key, but the signature is
        // produced by `attacker` over the same message. Because the embedded
        // public key does not match the signing key, verification must fail.
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
            signFn: { (tbs: [UInt8]) throws(CertTestSignError) -> [UInt8] in
                do {
                    return Array(try tlsKey.signature(for: Data(tbs)).derRepresentation)
                } catch {
                    throw CertTestSignError.failed
                }
            }
        ))

        #expect(throws: LibP2PCertificateError.self) {
            _ = try LibP2PCertificate.extractPeerID(from: cert)
        }
    }

    @Test("Certificate with no libp2p extension is rejected (fail-closed)")
    func missingExtensionRejected() throws {
        // Build a leaf cert via P2PCoreDER but with an empty/invalid extension
        // value: parseLeaf returns the extension value, but SignedKey parsing or
        // signature verification must fail closed.
        let keyPair = KeyPair.generateEd25519()
        // An extension value that is not a SignedKey SEQUENCE.
        let bogusExt: [UInt8] = [0x04, 0x01, 0x00]  // OCTET STRING, not a SEQUENCE
        let tlsKey = P256.Signing.PrivateKey()
        let spkiDER = try SubjectPublicKeyInfoDER.encodeP256(
            uncompressedPoint65: [UInt8](tlsKey.publicKey.x963Representation)
        )
        _ = keyPair
        var serial = [UInt8](repeating: 0x44, count: 16)
        serial[0] &= 0x7F
        let now = Int64(Date().timeIntervalSince1970)
        let cert = Data(try LibP2PCertificateDER.buildSelfSignedCert(
            spkiDER: spkiDER,
            signedKeyExtension: bogusExt,
            serial16: serial,
            notBefore: now - 3600,
            notAfter: now + 86_400,
            signFn: { (tbs: [UInt8]) throws(CertTestSignError) -> [UInt8] in
                do {
                    return Array(try tlsKey.signature(for: Data(tbs)).derRepresentation)
                } catch {
                    throw CertTestSignError.failed
                }
            }
        ))

        #expect(throws: LibP2PCertificateError.self) {
            _ = try LibP2PCertificate.extractPeerID(from: cert)
        }
    }
}

private enum CertTestSignError: Error {
    case failed
}
