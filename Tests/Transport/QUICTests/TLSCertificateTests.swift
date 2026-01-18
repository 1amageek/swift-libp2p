/// Tests for libp2p TLS certificate generation and parsing.

import Testing
import Foundation
import P2PCore
@testable import P2PTransportQUIC

@Suite("TLSCertificate Tests")
struct TLSCertificateTests {

    // MARK: - SignedKey Tests

    @Suite("SignedKey ASN.1")
    struct SignedKeyTests {

        @Test("Round-trip encoding preserves data")
        func roundTripEncoding() throws {
            let publicKey = Data([0x01, 0x02, 0x03, 0x04])
            let signature = Data([0x05, 0x06, 0x07, 0x08])

            let original = SignedKey(publicKey: publicKey, signature: signature)

            // Serialize
            let der = try original.serialize()

            // Parse
            let parsed = try SignedKey.parse(der)

            #expect(parsed.publicKeyData == publicKey)
            #expect(parsed.signatureData == signature)
        }

        @Test("Empty data encodes correctly")
        func emptyDataEncoding() throws {
            let original = SignedKey(publicKey: Data(), signature: Data())

            let der = try original.serialize()
            let parsed = try SignedKey.parse(der)

            #expect(parsed.publicKeyData.isEmpty)
            #expect(parsed.signatureData.isEmpty)
        }

        @Test("Large data encodes correctly")
        func largeDataEncoding() throws {
            let publicKey = Data(repeating: 0xAA, count: 1024)
            let signature = Data(repeating: 0xBB, count: 512)

            let original = SignedKey(publicKey: publicKey, signature: signature)

            let der = try original.serialize()
            let parsed = try SignedKey.parse(der)

            #expect(parsed.publicKeyData == publicKey)
            #expect(parsed.signatureData == signature)
        }

        @Test("OID constant is correct")
        func oidConstant() {
            // OID: 1.3.6.1.4.1.53594.1.1
            let oidString = String(describing: libp2pExtensionOID)
            #expect(oidString.contains("1.3.6.1.4.1.53594.1.1"))
        }

        @Test("Signature prefix is correct")
        func signaturePrefixConstant() {
            #expect(libp2pTLSSignaturePrefix == "libp2p-tls-handshake:")
        }
    }

    // MARK: - Certificate Generation Tests

    @Suite("Certificate Generation")
    struct CertificateGenerationTests {

        @Test("Generate certificate with Ed25519 key")
        func generateWithEd25519() throws {
            let keyPair = KeyPair.generateEd25519()

            let cert = try TLSCertificate.generate(hostKeyPair: keyPair)

            // Verify the certificate contains the correct PeerID
            #expect(cert.peerID == keyPair.peerID)

            // Verify the certificate has a TLS private key
            #expect(cert.tlsPrivateKey != nil)

            // Verify the DER is non-empty
            #expect(!cert.certificateDER.isEmpty)

            // Verify the libp2p public key matches
            #expect(cert.libp2pPublicKey.keyType == .ed25519)
            #expect(cert.libp2pPublicKey.rawBytes == keyPair.publicKey.rawBytes)
        }

        @Test("Generated certificate is self-signed")
        func generatedCertificateIsSelfSigned() throws {
            let keyPair = KeyPair.generateEd25519()
            let cert = try TLSCertificate.generate(hostKeyPair: keyPair)

            // Issuer and subject should be the same (self-signed)
            #expect(cert.certificate.issuer == cert.certificate.subject)
        }

        @Test("Generated certificate has valid time range")
        func generatedCertificateValidTimeRange() throws {
            let keyPair = KeyPair.generateEd25519()
            let cert = try TLSCertificate.generate(hostKeyPair: keyPair)

            let now = Date()

            // Certificate should be valid now
            #expect(cert.certificate.notValidBefore < now)
            #expect(cert.certificate.notValidAfter > now)

            // Valid for approximately 1 year
            let validDuration = cert.certificate.notValidAfter.timeIntervalSince(cert.certificate.notValidBefore)
            let oneYear: TimeInterval = 365 * 24 * 3600 + 3600  // 1 year + 1 hour clock skew
            #expect(abs(validDuration - oneYear) < 60)  // Within 1 minute tolerance
        }

        @Test("Generated certificate uses v3")
        func generatedCertificateUsesV3() throws {
            let keyPair = KeyPair.generateEd25519()
            let cert = try TLSCertificate.generate(hostKeyPair: keyPair)

            #expect(cert.certificate.version == .v3)
        }

        @Test("Different key pairs produce different certificates")
        func differentKeyPairsDifferentCertificates() throws {
            let keyPair1 = KeyPair.generateEd25519()
            let keyPair2 = KeyPair.generateEd25519()

            let cert1 = try TLSCertificate.generate(hostKeyPair: keyPair1)
            let cert2 = try TLSCertificate.generate(hostKeyPair: keyPair2)

            #expect(cert1.peerID != cert2.peerID)
            #expect(cert1.certificateDER != cert2.certificateDER)
        }
    }

    // MARK: - Certificate Parsing Tests

    @Suite("Certificate Parsing")
    struct CertificateParsingTests {

        @Test("Parse generated certificate")
        func parseGeneratedCertificate() throws {
            let keyPair = KeyPair.generateEd25519()
            let generated = try TLSCertificate.generate(hostKeyPair: keyPair)

            // Parse the DER
            let parsed = try TLSCertificate.parse(generated.certificateDER)

            // Should have the same PeerID
            #expect(parsed.peerID == generated.peerID)

            // Should have the same libp2p public key
            #expect(parsed.libp2pPublicKey.rawBytes == generated.libp2pPublicKey.rawBytes)

            // Parsed certificate should not have the private key
            #expect(parsed.tlsPrivateKey == nil)
        }

        @Test("Round-trip certificate preserves PeerID")
        func roundTripCertificate() throws {
            let keyPair = KeyPair.generateEd25519()
            let original = try TLSCertificate.generate(hostKeyPair: keyPair)

            // Serialize and parse multiple times
            var current = original
            for _ in 0..<3 {
                let parsed = try TLSCertificate.parse(current.certificateDER)
                #expect(parsed.peerID == keyPair.peerID)
                current = parsed
            }
        }

        @Test("Invalid DER throws error")
        func invalidDERThrowsError() throws {
            let invalidDER = Data([0x00, 0x01, 0x02, 0x03])

            #expect(throws: TLSCertificateError.self) {
                try TLSCertificate.parse(invalidDER)
            }
        }
    }

    // MARK: - Certificate Verification Tests

    @Suite("Certificate Verification")
    struct CertificateVerificationTests {

        @Test("Verify generated certificate")
        func verifyGeneratedCertificate() throws {
            let keyPair = KeyPair.generateEd25519()
            let cert = try TLSCertificate.generate(hostKeyPair: keyPair)

            let isValid = try cert.verify()
            #expect(isValid)
        }

        @Test("Verify parsed certificate")
        func verifyParsedCertificate() throws {
            let keyPair = KeyPair.generateEd25519()
            let generated = try TLSCertificate.generate(hostKeyPair: keyPair)
            let parsed = try TLSCertificate.parse(generated.certificateDER)

            let isValid = try parsed.verify()
            #expect(isValid)
        }
    }

    // MARK: - PEM Encoding Tests

    @Suite("PEM Encoding")
    struct PEMEncodingTests {

        @Test("PEM encoding produces valid format")
        func pemEncodingValidFormat() throws {
            let keyPair = KeyPair.generateEd25519()
            let cert = try TLSCertificate.generate(hostKeyPair: keyPair)

            let pem = cert.pemEncoded

            #expect(pem.hasPrefix("-----BEGIN CERTIFICATE-----"))
            #expect(pem.hasSuffix("-----END CERTIFICATE-----\n") || pem.hasSuffix("-----END CERTIFICATE-----"))
        }

        @Test("PEM encoding is base64")
        func pemEncodingIsBase64() throws {
            let keyPair = KeyPair.generateEd25519()
            let cert = try TLSCertificate.generate(hostKeyPair: keyPair)

            let pem = cert.pemEncoded

            // Extract the base64 content
            let lines = pem.components(separatedBy: .newlines)
            let base64Lines = lines.filter { !$0.hasPrefix("-----") && !$0.isEmpty }
            let base64String = base64Lines.joined()

            // Should be valid base64
            let decoded = Data(base64Encoded: base64String)
            #expect(decoded != nil)
            #expect(decoded == cert.certificateDER)
        }
    }

    // MARK: - ALPN Tests

    @Suite("ALPN")
    struct ALPNTests {

        @Test("ALPN protocol is 'libp2p'")
        func alpnProtocolIsLibp2p() {
            #expect(TLSCertificate.alpnProtocol == "libp2p")
        }
    }
}
