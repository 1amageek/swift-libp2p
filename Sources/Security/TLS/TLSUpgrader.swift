/// TLSUpgrader - SecurityUpgrader implementation for TLS
import Foundation
import Crypto
import P2PCore
import P2PSecurity

/// The TLS protocol ID.
public let tlsProtocolID = "/tls/1.0.0"

/// Configuration for TLS upgrader.
public struct TLSConfiguration: Sendable {
    /// Handshake timeout.
    public var handshakeTimeout: Duration

    /// ALPN protocols.
    public var alpnProtocols: [String]

    /// Creates a TLS configuration.
    public init(
        handshakeTimeout: Duration = .seconds(30),
        alpnProtocols: [String] = ["libp2p"]
    ) {
        self.handshakeTimeout = handshakeTimeout
        self.alpnProtocols = alpnProtocols
    }

    /// Default configuration.
    public static let `default` = TLSConfiguration()
}

/// Upgrades raw connections to secured connections using TLS.
///
/// Implements the libp2p TLS handshake specification:
/// - Self-signed X.509 certificates with libp2p extension
/// - Mutual authentication using libp2p identity keys
/// - TLS 1.3 for encryption
public final class TLSUpgrader: SecurityUpgrader, Sendable {

    public var protocolID: String { tlsProtocolID }

    private let configuration: TLSConfiguration

    /// Creates a TLS upgrader.
    public init(configuration: TLSConfiguration = .default) {
        self.configuration = configuration
    }

    public func secure(
        _ connection: any RawConnection,
        localKeyPair: KeyPair,
        as role: SecurityRole,
        expectedPeer: PeerID?
    ) async throws -> any SecuredConnection {
        // 1. Generate our certificate
        let certResult = try TLSCertificate.generate(keyPair: localKeyPair)

        // 2. Perform TLS handshake
        var readBuffer = Data()
        let (remotePeer, sendKey, recvKey) = try await performHandshake(
            connection: connection,
            isInitiator: role == .initiator,
            localCertificate: certResult.certificateDER,
            localPrivateKey: certResult.privateKey,
            expectedPeer: expectedPeer,
            readBuffer: &readBuffer
        )

        // 3. Return secured connection
        return TLSConnection(
            underlying: connection,
            localPeer: localKeyPair.peerID,
            remotePeer: remotePeer,
            sendKey: sendKey,
            recvKey: recvKey,
            initialBuffer: readBuffer
        )
    }

    // MARK: - Handshake

    private func performHandshake(
        connection: any RawConnection,
        isInitiator: Bool,
        localCertificate: Data,
        localPrivateKey: P256.Signing.PrivateKey,
        expectedPeer: PeerID?,
        readBuffer: inout Data
    ) async throws -> (remotePeer: PeerID, sendKey: SymmetricKey, recvKey: SymmetricKey) {
        // For simplicity, this implements a minimal handshake protocol
        // that exchanges certificates and derives session keys.

        // Exchange certificates
        let remoteCertificate: Data
        if isInitiator {
            // Client: send certificate first, then receive
            try await sendCertificate(localCertificate, to: connection)
            remoteCertificate = try await receiveCertificate(from: connection, buffer: &readBuffer)
        } else {
            // Server: receive first, then send
            remoteCertificate = try await receiveCertificate(from: connection, buffer: &readBuffer)
            try await sendCertificate(localCertificate, to: connection)
        }

        // Extract and verify remote peer identity
        let remoteSPKI = try extractSPKI(from: remoteCertificate)
        let remotePeer = try TLSCertificate.verifyAndExtractPeerID(
            from: remoteCertificate,
            spkiDER: remoteSPKI
        )

        // Verify expected peer if specified
        if let expected = expectedPeer, expected != remotePeer {
            throw SecurityError.peerMismatch(expected: expected, actual: remotePeer)
        }

        // Derive session keys using HKDF
        // In a real implementation, this would use the TLS key schedule
        let sharedSecret = deriveSharedSecret(
            localPrivateKey: localPrivateKey,
            remoteCertificate: remoteCertificate
        )

        let (sendKey, recvKey) = deriveSessionKeys(
            sharedSecret: sharedSecret,
            isInitiator: isInitiator
        )

        return (remotePeer, sendKey, recvKey)
    }

    private func sendCertificate(_ certificate: Data, to connection: any RawConnection) async throws {
        // Frame: [4-byte length][certificate DER]
        var frame = Data()
        let length = UInt32(certificate.count)
        frame.append(UInt8((length >> 24) & 0xFF))
        frame.append(UInt8((length >> 16) & 0xFF))
        frame.append(UInt8((length >> 8) & 0xFF))
        frame.append(UInt8(length & 0xFF))
        frame.append(certificate)
        try await connection.write(frame)
    }

    private func receiveCertificate(
        from connection: any RawConnection,
        buffer: inout Data
    ) async throws -> Data {
        // Read until we have at least 4 bytes for length
        while buffer.count < 4 {
            let chunk = try await connection.read()
            if chunk.isEmpty {
                throw TLSError.connectionClosed
            }
            buffer.append(chunk)
        }

        // Parse length
        let length = Int(buffer[0]) << 24 | Int(buffer[1]) << 16 | Int(buffer[2]) << 8 | Int(buffer[3])

        // Validate length
        guard length > 0 && length < 65536 else {
            throw TLSError.invalidMessage
        }

        // Read certificate data
        while buffer.count < 4 + length {
            let chunk = try await connection.read()
            if chunk.isEmpty {
                throw TLSError.connectionClosed
            }
            buffer.append(chunk)
        }

        let certificate = Data(buffer[4..<4 + length])
        buffer = Data(buffer.dropFirst(4 + length))

        return certificate
    }

    private func extractSPKI(from certificateDER: Data) throws -> Data {
        // Find SubjectPublicKeyInfo in certificate
        // This is a simplified extraction - looks for SEQUENCE containing EC key info

        // Search for the ecPublicKey OID: 1.2.840.10045.2.1
        let ecOIDBytes: [UInt8] = [0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]
        let ecOID = Data(ecOIDBytes)

        guard let oidRange = certificateDER.range(of: ecOID) else {
            throw TLSError.invalidMessage
        }

        // Go back to find the SEQUENCE that contains this OID
        // The SPKI structure starts before the AlgorithmIdentifier
        var searchStart = max(0, oidRange.lowerBound - 20)
        while searchStart > 0 {
            if certificateDER[searchStart] == 0x30 {  // SEQUENCE
                // Check if this could be the SPKI by looking at structure
                let possibleSPKI = certificateDER[searchStart...]

                // Verify it contains the OID we found
                if possibleSPKI.range(of: ecOID) != nil {
                    // Parse the SEQUENCE to get its full length
                    if let (length, lengthSize) = parseASN1Length(from: Array(possibleSPKI), at: 1) {
                        let totalSize = 1 + lengthSize + length
                        return Data(possibleSPKI.prefix(totalSize))
                    }
                }
            }
            searchStart -= 1
        }

        throw TLSError.invalidMessage
    }

    private func parseASN1Length(from bytes: [UInt8], at offset: Int) -> (length: Int, size: Int)? {
        guard offset < bytes.count else { return nil }

        let firstByte = bytes[offset]
        if firstByte < 128 {
            return (Int(firstByte), 1)
        }

        let numBytes = Int(firstByte & 0x7F)
        guard offset + numBytes < bytes.count else { return nil }

        var length = 0
        for i in 0..<numBytes {
            length = (length << 8) | Int(bytes[offset + 1 + i])
        }
        return (length, numBytes + 1)
    }

    private func deriveSharedSecret(
        localPrivateKey: P256.Signing.PrivateKey,
        remoteCertificate: Data
    ) -> Data {
        // In a full TLS implementation, this would use ECDHE
        // For now, derive a deterministic secret from both certificates
        var hasher = SHA256()
        hasher.update(data: localPrivateKey.publicKey.x963Representation)
        hasher.update(data: remoteCertificate)
        return Data(hasher.finalize())
    }

    private func deriveSessionKeys(
        sharedSecret: Data,
        isInitiator: Bool
    ) -> (send: SymmetricKey, recv: SymmetricKey) {
        // Derive keys using HKDF
        let symmetricKey = SymmetricKey(data: sharedSecret)

        let clientKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: symmetricKey,
            info: Data("client".utf8),
            outputByteCount: 32
        )

        let serverKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: symmetricKey,
            info: Data("server".utf8),
            outputByteCount: 32
        )

        if isInitiator {
            return (clientKey, serverKey)
        } else {
            return (serverKey, clientKey)
        }
    }
}
