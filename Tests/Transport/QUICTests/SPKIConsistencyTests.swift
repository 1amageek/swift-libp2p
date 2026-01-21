/// Tests to verify SPKI DER consistency between generation and verification.

import Testing
import Foundation
@testable import P2PTransportQUIC
@testable import P2PCore
import QUICCrypto

@Suite("SPKI Consistency Tests")
struct SPKIConsistencyTests {

    @Test("Generated certificate can be parsed by swift-certificates")
    func certificateParsable() throws {
        let keyPair = KeyPair.generateEd25519()

        // Generate certificate using LibP2PCertificateHelper
        let (certificateDER, _) = try LibP2PCertificateHelper.generateCertificate(keyPair: keyPair)

        // Parse with swift-certificates (via swift-quic's X509Certificate)
        let cert = try X509Certificate.parse(from: certificateDER)

        // Basic checks
        #expect(cert.isSelfSigned)
        #expect(!cert.subjectPublicKeyInfoDER.isEmpty)
    }

    @Test("SPKI DER matches between generation and parsing")
    func spkiDERConsistency() throws {
        let keyPair = KeyPair.generateEd25519()

        // Generate certificate
        let (certificateDER, signingKey) = try LibP2PCertificateHelper.generateCertificate(keyPair: keyPair)

        // Get SPKI from signing key using our encoder (same as what was used for signature)
        let generatedSPKI = try encodeSPKIForTest(publicKey: signingKey.publicKeyBytes)

        // Parse certificate with swift-certificates and get SPKI
        let cert = try X509Certificate.parse(from: certificateDER)
        let parsedSPKI = cert.subjectPublicKeyInfoDER

        // These MUST match for signature verification to work
        #expect(generatedSPKI == parsedSPKI, "SPKI DER mismatch: generated \(generatedSPKI.count) bytes, parsed \(parsedSPKI.count) bytes")

        if generatedSPKI != parsedSPKI {
            print("Generated SPKI: \(generatedSPKI.hexString)")
            print("Parsed SPKI: \(parsedSPKI.hexString)")
        }
    }

    @Test("End-to-end signature verification works")
    func endToEndSignatureVerification() throws {
        let keyPair = KeyPair.generateEd25519()

        // Generate certificate
        let (certificateDER, _) = try LibP2PCertificateHelper.generateCertificate(keyPair: keyPair)

        // Extract libp2p extension (this is what SwiftQUICTLSProvider does)
        let (publicKeyBytes, signature) = try LibP2PCertificateHelper.extractLibP2PPublicKey(from: certificateDER)

        // Parse public key
        let libp2pPublicKey = try P2PCore.PublicKey(protobufEncoded: publicKeyBytes)

        // Verify it's the same key
        #expect(libp2pPublicKey.peerID == keyPair.peerID)

        // Get SPKI from parsed certificate (what SwiftQUICTLSProvider does)
        let cert = try X509Certificate.parse(from: certificateDER)
        let spkiDER = cert.subjectPublicKeyInfoDER

        // Reconstruct signature message
        let message = Data("libp2p-tls-handshake:".utf8) + spkiDER

        // Verify signature - THIS IS THE CRITICAL TEST
        let isValid = try libp2pPublicKey.verify(signature: signature, for: message)
        #expect(isValid, "Signature verification failed - SPKI DER mismatch between generation and parsing")
    }

    // MARK: - Helper to reproduce LibP2PCertificateHelper's SPKI encoding

    private func encodeSPKIForTest(publicKey: Data) throws -> Data {
        // Reproduce LibP2PCertificateHelper.encodeSPKI() logic
        // ecPublicKey OID: 1.2.840.10045.2.1
        // secp256r1 OID: 1.2.840.10045.3.1.7
        let ecPublicKeyOID = encodeOID([1, 2, 840, 10045, 2, 1])
        let secp256r1OID = encodeOID([1, 2, 840, 10045, 3, 1, 7])
        let algorithmIdentifier = encodeSequence(ecPublicKeyOID + secp256r1OID)

        // BIT STRING encoding (0 unused bits + public key bytes)
        var bitString = Data([0x03])  // BIT STRING tag
        let bitStringContent = Data([0x00]) + publicKey  // 0 unused bits
        bitString.append(contentsOf: encodeLength(bitStringContent.count))
        bitString.append(bitStringContent)

        return encodeSequence(algorithmIdentifier + bitString)
    }

    private func encodeOID(_ components: [UInt]) -> Data {
        guard components.count >= 2 else {
            return Data([0x06, 0x00])
        }

        var result = Data([0x06])
        var content = Data()

        content.append(UInt8(components[0] * 40 + components[1]))

        for i in 2..<components.count {
            let comp = components[i]
            if comp < 128 {
                content.append(UInt8(comp))
            } else {
                var bytes: [UInt8] = []
                var val = comp
                bytes.append(UInt8(val & 0x7F))
                val >>= 7
                while val > 0 {
                    bytes.append(UInt8((val & 0x7F) | 0x80))
                    val >>= 7
                }
                content.append(contentsOf: bytes.reversed())
            }
        }

        result.append(contentsOf: encodeLength(content.count))
        result.append(content)
        return result
    }

    private func encodeSequence(_ contents: Data) -> Data {
        var result = Data([0x30])
        result.append(contentsOf: encodeLength(contents.count))
        result.append(contents)
        return result
    }

    private func encodeLength(_ length: Int) -> [UInt8] {
        if length < 128 {
            return [UInt8(length)]
        } else if length < 256 {
            return [0x81, UInt8(length)]
        } else if length < 65536 {
            return [0x82, UInt8(length >> 8), UInt8(length & 0xFF)]
        } else {
            return [0x83, UInt8(length >> 16), UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF)]
        }
    }
}

extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
