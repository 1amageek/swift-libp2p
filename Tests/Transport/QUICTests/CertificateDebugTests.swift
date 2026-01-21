/// Debug tests to isolate certificate generation and extraction issues.
///
/// Run with: swift test --filter CertificateDebugTests

import Testing
import Foundation
@testable import P2PTransportQUIC
@testable import P2PCore
import QUICCrypto
import QUICCore

@Suite("Certificate Debug Tests")
struct CertificateDebugTests {

    // MARK: - Step 1: Basic Certificate Generation

    @Test("Certificate can be generated")
    func certificateGeneration() throws {
        let keyPair = KeyPair.generateEd25519()

        let (certDER, signingKey) = try LibP2PCertificateHelper.generateCertificate(keyPair: keyPair)

        #expect(!certDER.isEmpty, "Certificate should not be empty")
        #expect(!signingKey.publicKeyBytes.isEmpty, "Signing key should have public bytes")

        print("Certificate generated: \(certDER.count) bytes")
        print("Signing key public bytes: \(signingKey.publicKeyBytes.count) bytes")
    }

    // MARK: - Step 2: Certificate Parsing

    @Test("Certificate can be parsed by X509Certificate")
    func certificateParsing() throws {
        let keyPair = KeyPair.generateEd25519()
        let (certDER, _) = try LibP2PCertificateHelper.generateCertificate(keyPair: keyPair)

        // Parse with swift-quic's X509Certificate (uses swift-certificates)
        let cert = try X509Certificate.parse(from: certDER)

        #expect(cert.isSelfSigned, "Should be self-signed")
        #expect(!cert.subjectPublicKeyInfoDER.isEmpty, "Should have SPKI")

        print("Certificate parsed successfully")
        print("SPKI DER: \(cert.subjectPublicKeyInfoDER.count) bytes")
    }

    // MARK: - Step 3: Extension Extraction (THE KEY TEST)

    @Test("libp2p extension can be extracted from certificate")
    func extensionExtraction() throws {
        let keyPair = KeyPair.generateEd25519()
        let (certDER, _) = try LibP2PCertificateHelper.generateCertificate(keyPair: keyPair)

        // Parse certificate
        let cert = try X509Certificate.parse(from: certDER)

        // Try to get extension value
        let extensionValue = cert.libp2pExtensionValue

        // This is the critical check
        #expect(extensionValue != nil, "libp2p extension should be present in certificate")

        if let extValue = extensionValue {
            print("libp2p extension found: \(extValue.count) bytes")
            print("Extension hex: \(extValue.prefix(32).map { String(format: "%02x", $0) }.joined())")
        } else {
            // Debug: list all extensions
            print("ERROR: libp2p extension not found!")
            print("Listing all extensions in certificate:")
            for ext in cert.certificate.extensions {
                print("  OID: \(ext.oid), critical: \(ext.critical)")
            }
        }
    }

    // MARK: - Step 4: Full Extraction Flow

    @Test("extractLibP2PPublicKey works end-to-end")
    func fullExtractionFlow() throws {
        let keyPair = KeyPair.generateEd25519()
        let (certDER, _) = try LibP2PCertificateHelper.generateCertificate(keyPair: keyPair)

        // This is what SwiftQUICTLSProvider.validateLibP2PCertificate does
        let (publicKeyBytes, signature) = try LibP2PCertificateHelper.extractLibP2PPublicKey(from: certDER)

        #expect(!publicKeyBytes.isEmpty, "Should extract public key")
        #expect(!signature.isEmpty, "Should extract signature")

        // Parse and verify
        let libp2pPublicKey = try P2PCore.PublicKey(protobufEncoded: publicKeyBytes)
        #expect(libp2pPublicKey.peerID == keyPair.peerID, "PeerID should match")

        print("Public key extracted: \(publicKeyBytes.count) bytes")
        print("Signature extracted: \(signature.count) bytes")
        print("PeerID matches: \(libp2pPublicKey.peerID == keyPair.peerID)")
    }

    // MARK: - Step 5: Signature Verification

    @Test("Signature verification works")
    func signatureVerification() throws {
        let keyPair = KeyPair.generateEd25519()
        let (certDER, _) = try LibP2PCertificateHelper.generateCertificate(keyPair: keyPair)

        // Extract components
        let (publicKeyBytes, signature) = try LibP2PCertificateHelper.extractLibP2PPublicKey(from: certDER)
        let libp2pPublicKey = try P2PCore.PublicKey(protobufEncoded: publicKeyBytes)

        // Get SPKI from parsed certificate
        let cert = try X509Certificate.parse(from: certDER)
        let spkiDER = cert.subjectPublicKeyInfoDER

        // Reconstruct message
        let message = Data("libp2p-tls-handshake:".utf8) + spkiDER

        // Verify
        let isValid = try libp2pPublicKey.verify(signature: signature, for: message)
        #expect(isValid, "Signature should be valid")

        print("Signature verification: \(isValid ? "PASS" : "FAIL")")
    }

    // MARK: - Step 6: Simulate certificateValidator

    @Test("certificateValidator callback works correctly")
    func certificateValidatorSimulation() throws {
        let keyPair = KeyPair.generateEd25519()
        let (certDER, _) = try LibP2PCertificateHelper.generateCertificate(keyPair: keyPair)

        // Simulate what swift-quic's TLS layer does
        let certChain = [certDER]

        // This is the actual validator function from SwiftQUICTLSProvider
        func validateLibP2PCertificate(certChain: [Data], expectedPeerID: PeerID?) throws -> PeerID {
            guard let leafCertDER = certChain.first else {
                throw TLSCertificateError.missingLibp2pExtension
            }

            let (publicKeyBytes, signature) = try LibP2PCertificateHelper.extractLibP2PPublicKey(from: leafCertDER)
            let libp2pPublicKey = try P2PCore.PublicKey(protobufEncoded: publicKeyBytes)

            let peerCert = try X509Certificate.parse(from: leafCertDER)
            let spkiDER = peerCert.subjectPublicKeyInfoDER
            let message = Data("libp2p-tls-handshake:".utf8) + spkiDER

            guard try libp2pPublicKey.verify(signature: signature, for: message) else {
                throw TLSCertificateError.invalidExtensionSignature
            }

            let peerID = libp2pPublicKey.peerID

            if let expected = expectedPeerID {
                guard expected == peerID else {
                    throw TLSCertificateError.peerIDMismatch(expected: expected, actual: peerID)
                }
            }

            return peerID
        }

        // Test the validator
        let validatedPeerID = try validateLibP2PCertificate(certChain: certChain, expectedPeerID: nil)
        #expect(validatedPeerID == keyPair.peerID)

        print("Certificate validator simulation: PASS")
        print("Validated PeerID: \(validatedPeerID)")
    }

    // MARK: - Step 7a: Certificate Message Encoding/Decoding

    @Test("Certificate message encoding roundtrip preserves data")
    func certificateMessageRoundtrip() throws {
        let keyPair = KeyPair.generateEd25519()
        let (certDER, _) = try LibP2PCertificateHelper.generateCertificate(keyPair: keyPair)

        print("Original cert DER: \(certDER.count) bytes")
        print("Original cert hex (first 50): \(certDER.prefix(50).map { String(format: "%02x", $0) }.joined())")

        // Verify original has libp2p extension
        let originalCert = try X509Certificate.parse(from: certDER)
        #expect(originalCert.libp2pExtensionValue != nil, "Original should have extension")

        // Encode as TLS Certificate message
        let certificateMsg = Certificate(
            certificateRequestContext: Data(),
            certificates: [certDER]
        )
        let encodedMsg = certificateMsg.encode()
        print("Encoded Certificate message: \(encodedMsg.count) bytes")

        // Decode back
        let decodedCertificate = try Certificate.decode(from: encodedMsg)
        #expect(decodedCertificate.certificates.count == 1, "Should have 1 certificate")

        let recoveredDER = decodedCertificate.certificates[0]
        print("Recovered cert DER: \(recoveredDER.count) bytes")
        print("Recovered cert hex (first 50): \(recoveredDER.prefix(50).map { String(format: "%02x", $0) }.joined())")

        // Verify the data is identical
        #expect(recoveredDER == certDER, "Certificate DER should be preserved exactly")

        // Verify recovered cert still has libp2p extension
        let recoveredCert = try X509Certificate.parse(from: recoveredDER)
        let recoveredExtension = recoveredCert.libp2pExtensionValue
        #expect(recoveredExtension != nil, "Recovered cert should still have libp2p extension")

        print("Certificate message roundtrip: PASS")
    }

    // MARK: - Step 7b: Full Handshake Message Encoding

    @Test("Full TLS handshake message encoding preserves certificate")
    func handshakeMessageEncoding() throws {
        let keyPair = KeyPair.generateEd25519()
        let (certDER, _) = try LibP2PCertificateHelper.generateCertificate(keyPair: keyPair)

        // Encode as complete handshake message (with header)
        let certificateMsg = Certificate(
            certificateRequestContext: Data(),
            certificates: [certDER]
        )
        let fullMessage = certificateMsg.encodeAsHandshake()
        print("Full handshake message: \(fullMessage.count) bytes")
        print("Message hex: \(fullMessage.map { String(format: "%02x", $0) }.joined())")

        // Parse the header
        let (msgType, contentLength) = try HandshakeCodec.decodeHeader(from: fullMessage)
        print("Message type: \(msgType), content length: \(contentLength)")
        #expect(msgType == .certificate, "Should be certificate message")

        // Extract content (skip 4-byte header)
        let content = fullMessage.subdata(in: 4..<fullMessage.count)

        // Decode certificate from content
        let decoded = try Certificate.decode(from: content)
        let recoveredDER = decoded.certificates.first!

        // Verify
        let recoveredCert = try X509Certificate.parse(from: recoveredDER)
        #expect(recoveredCert.libp2pExtensionValue != nil, "Should still have extension after full roundtrip")

        print("Full handshake message encoding: PASS")
    }

    // MARK: - Step 7: OID Encoding Verification

    @Test("OID encoding is correct")
    func oidEncodingVerification() throws {
        // libp2p OID: 1.3.6.1.4.1.53594.1.1
        // Expected encoding:
        // First byte: 1*40 + 3 = 43 = 0x2B
        // Then: 6=0x06, 1=0x01, 4=0x04, 1=0x01
        // 53594 in base128 encoding: 0x83, 0xA2, 0x5A
        // Then: 1=0x01, 1=0x01

        let expectedOIDBytes: [UInt8] = [
            0x2B,       // 1.3
            0x06,       // 6
            0x01,       // 1
            0x04,       // 4
            0x01,       // 1
            0x83, 0xA2, 0x5A,  // 53594
            0x01,       // 1
            0x01        // 1
        ]

        // Encode using LibP2PCertificateHelper's logic
        let encodedOID = encodeTestOID([1, 3, 6, 1, 4, 1, 53594, 1, 1])

        // Skip tag (0x06) and length byte
        let oidContent = Array(encodedOID.dropFirst(2))

        #expect(oidContent == expectedOIDBytes, "OID encoding should match expected bytes")

        print("OID content: \(oidContent.map { String(format: "%02x", $0) }.joined(separator: " "))")
        print("Expected:    \(expectedOIDBytes.map { String(format: "%02x", $0) }.joined(separator: " "))")
    }

    // MARK: - Step 8: TLS Handshake Simulation (Without QUIC)

    @Test("TLS handshake messages flow correctly")
    func tlsHandshakeFlow() async throws {
        let serverKeyPair = KeyPair.generateEd25519()
        let clientKeyPair = KeyPair.generateEd25519()

        // Verify both certificates can be generated and extracted
        let (serverCertDER, _) = try LibP2PCertificateHelper.generateCertificate(keyPair: serverKeyPair)
        let (clientCertDER, _) = try LibP2PCertificateHelper.generateCertificate(keyPair: clientKeyPair)

        // Verify both certs have libp2p extension
        let serverCert = try X509Certificate.parse(from: serverCertDER)
        let clientCert = try X509Certificate.parse(from: clientCertDER)
        #expect(serverCert.libp2pExtensionValue != nil, "Server cert should have libp2p extension")
        #expect(clientCert.libp2pExtensionValue != nil, "Client cert should have libp2p extension")

        // Create TLS providers
        let serverProvider = try SwiftQUICTLSProvider(
            localKeyPair: serverKeyPair,
            expectedRemotePeerID: nil
        )
        let clientProvider = try SwiftQUICTLSProvider(
            localKeyPair: clientKeyPair,
            expectedRemotePeerID: nil
        )

        // Set transport parameters (required for QUIC TLS)
        let dummyParams = Data([0x00, 0x00])
        try serverProvider.setLocalTransportParameters(dummyParams)
        try clientProvider.setLocalTransportParameters(dummyParams)

        // CLIENT: Start handshake (send ClientHello)
        let clientHelloOutputs = try await clientProvider.startHandshake(isClient: true)
        var clientToServer: [(Data, EncryptionLevel)] = []
        for output in clientHelloOutputs {
            if case .handshakeData(let data, let level) = output {
                clientToServer.append((data, level))
            }
        }

        // SERVER: Start handshake
        _ = try await serverProvider.startHandshake(isClient: false)

        // SERVER: Process ClientHello -> sends ServerHello, EncryptedExtensions, CertificateRequest, Certificate, CertificateVerify, Finished
        var serverToClient: [(Data, EncryptionLevel)] = []
        for (data, level) in clientToServer {
            let outputs = try await serverProvider.processHandshakeData(data, at: level)
            for output in outputs {
                if case .handshakeData(let respData, let respLevel) = output {
                    serverToClient.append((respData, respLevel))
                }
            }
        }

        // CLIENT: Process server messages -> validates server cert, sends Certificate, CertificateVerify, Finished
        clientToServer = []
        for (data, level) in serverToClient {
            let outputs = try await clientProvider.processHandshakeData(data, at: level)
            for output in outputs {
                if case .handshakeData(let respData, let respLevel) = output {
                    clientToServer.append((respData, respLevel))
                }
            }
        }

        // SERVER: Process client Certificate/CertificateVerify/Finished -> validates client cert
        for (data, level) in clientToServer {
            _ = try await serverProvider.processHandshakeData(data, at: level)
        }

        // Verify handshake completion
        #expect(serverProvider.isHandshakeComplete, "Server handshake should be complete")
        #expect(clientProvider.isHandshakeComplete, "Client handshake should be complete")

        // Verify PeerIDs (the key test for mTLS)
        #expect(serverProvider.remotePeerID == clientKeyPair.peerID, "Server should see client's PeerID")
        #expect(clientProvider.remotePeerID == serverKeyPair.peerID, "Client should see server's PeerID")
    }

    private func encodeTestOID(_ components: [UInt]) -> Data {
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

        if content.count < 128 {
            result.append(UInt8(content.count))
        } else {
            result.append(0x81)
            result.append(UInt8(content.count))
        }
        result.append(content)
        return result
    }
}
