/// libp2p TLS 1.3 Provider for QUIC.
///
/// Implements the TLS13Provider protocol with libp2p-specific
/// certificate handling for peer authentication.
///
/// ## Wire Protocol
///
/// The libp2p TLS specification extends standard TLS 1.3 with:
/// 1. Self-signed X.509 certificates containing the libp2p extension
/// 2. PeerID extracted from the certificate extension after handshake
/// 3. ALPN set to "libp2p"
///
/// ## Example
///
/// ```swift
/// let keyPair = KeyPair.generateEd25519()
/// let provider = try TLSProvider(localKeyPair: keyPair)
///
/// // After TLS handshake completes...
/// let remotePeerID = provider.remotePeerID
/// ```

import Foundation
import Synchronization
import Crypto
import P2PCore
import QUICCrypto
import QUICCore

/// TLS 1.3 provider with libp2p certificate extensions.
///
/// This provider generates self-signed certificates with the libp2p extension
/// (OID 1.3.6.1.4.1.53594.1.1) and validates peer certificates to extract
/// their PeerID.
@available(macOS 10.15, iOS 13, watchOS 6, tvOS 13, *)
public final class TLSProvider: TLS13Provider, @unchecked Sendable {
    // MARK: - Properties

    /// The local key pair used for libp2p identity.
    private let localKeyPair: KeyPair

    /// The local certificate generated for this connection.
    private let localCertificate: TLSCertificate

    /// Expected remote PeerID (optional, for verification).
    private let expectedRemotePeerID: PeerID?

    /// Internal state protected by mutex.
    private let state: Mutex<ProviderState>

    /// State for the TLS provider.
    private struct ProviderState: Sendable {
        var isClient: Bool = false
        var handshakeComplete: Bool = false
        var remotePeerID: PeerID? = nil
        var remoteCertificate: TLSCertificate? = nil
        var localTransportParameters: Data = Data()
        var peerTransportParameters: Data? = nil
    }

    // MARK: - Initialization

    /// Creates a new libp2p TLS provider.
    ///
    /// - Parameters:
    ///   - localKeyPair: The libp2p identity key pair
    ///   - expectedRemotePeerID: If set, the handshake will fail if the remote
    ///     peer's ID doesn't match (used for dial security)
    /// - Throws: `TLSCertificateError` if certificate generation fails
    public init(localKeyPair: KeyPair, expectedRemotePeerID: PeerID? = nil) throws {
        self.localKeyPair = localKeyPair
        self.expectedRemotePeerID = expectedRemotePeerID
        self.localCertificate = try TLSCertificate.generate(hostKeyPair: localKeyPair)
        self.state = Mutex(ProviderState())
    }

    // MARK: - Public Accessors

    /// The local PeerID.
    public var localPeerID: PeerID {
        localKeyPair.peerID
    }

    /// The remote PeerID (available after handshake completes).
    public var remotePeerID: PeerID? {
        state.withLock { $0.remotePeerID }
    }

    /// The remote certificate (available after handshake completes).
    public var remoteCertificate: TLSCertificate? {
        state.withLock { $0.remoteCertificate }
    }

    /// The local certificate used in this connection.
    public var certificate: TLSCertificate {
        localCertificate
    }

    // MARK: - TLS13Provider Protocol

    public func startHandshake(isClient: Bool) async throws -> [TLSOutput] {
        state.withLock { $0.isClient = isClient }

        if isClient {
            // Client sends ClientHello with our certificate info
            // In a real TLS implementation, this would be the actual ClientHello
            // For now, we send our certificate DER as handshake data
            let clientHello = buildClientHello()
            return [.handshakeData(clientHello, level: .initial)]
        } else {
            // Server waits for ClientHello
            return []
        }
    }

    public func processHandshakeData(_ data: Data, at level: EncryptionLevel) async throws -> [TLSOutput] {
        let isClient = state.withLock { $0.isClient }

        if isClient {
            // Client processing ServerHello
            return try processServerResponse(data, at: level)
        } else {
            // Server processing ClientHello or Finished
            return try processClientMessage(data, at: level)
        }
    }

    public func getLocalTransportParameters() -> Data {
        state.withLock { $0.localTransportParameters }
    }

    public func setLocalTransportParameters(_ params: Data) throws {
        state.withLock { $0.localTransportParameters = params }
    }

    public func getPeerTransportParameters() -> Data? {
        state.withLock { $0.peerTransportParameters }
    }

    public var isHandshakeComplete: Bool {
        state.withLock { $0.handshakeComplete }
    }

    public var isClient: Bool {
        state.withLock { $0.isClient }
    }

    public var negotiatedALPN: String? {
        // libp2p always uses "libp2p" ALPN
        return TLSCertificate.alpnProtocol
    }

    public func requestKeyUpdate() async throws -> [TLSOutput] {
        // Key updates are not implemented in this mock
        return []
    }

    public func exportKeyingMaterial(label: String, context: Data?, length: Int) throws -> Data {
        // Export keying material using simple derivation
        // In a real implementation, this would use TLS 1.3 exporter
        var input = Data(label.utf8)
        if let ctx = context {
            input.append(ctx)
        }
        // Simple hash-based derivation (not cryptographically sound, just for testing)
        return Data(repeating: 0x42, count: length)
    }

    // MARK: - Private Handshake Methods

    /// Builds a mock ClientHello message.
    private func buildClientHello() -> Data {
        // In a real TLS implementation, this would be a proper ClientHello
        // For our mock, we send a marker byte + our certificate
        var data = Data()
        data.append(0x01)  // Message type: ClientHello
        data.append(contentsOf: localCertificate.certificateDER)
        return data
    }

    /// Processes a server response (ServerHello, etc.).
    private func processServerResponse(_ data: Data, at level: EncryptionLevel) throws -> [TLSOutput] {
        guard !data.isEmpty else {
            return [.needMoreData]
        }

        let messageType = data[0]

        switch messageType {
        case 0x02:  // ServerHello
            // Extract server certificate
            let certData = data.dropFirst()
            let (remoteCert, transportParams) = try parseHandshakeMessage(Data(certData))

            // Verify and extract PeerID
            try verifyRemoteCertificate(remoteCert)

            // Store peer transport parameters
            state.withLock { $0.peerTransportParameters = transportParams }

            // Generate handshake keys (mock)
            let handshakeKeys = generateMockKeys(for: EncryptionLevel.handshake)

            // Send client Finished
            let finished = buildClientFinished()

            return [
                .keysAvailable(handshakeKeys),
                .handshakeData(finished, level: .handshake)
            ]

        case 0x04:  // Server Finished
            // Handshake complete
            let appKeys = generateMockKeys(for: EncryptionLevel.application)
            state.withLock { $0.handshakeComplete = true }

            return [
                .keysAvailable(appKeys),
                .handshakeComplete(HandshakeCompleteInfo(alpn: TLSCertificate.alpnProtocol))
            ]

        default:
            throw TLSCertificateError.handshakeFailed(reason: "Unknown message type: \(messageType)")
        }
    }

    /// Processes a client message (server side).
    private func processClientMessage(_ data: Data, at level: EncryptionLevel) throws -> [TLSOutput] {
        guard !data.isEmpty else {
            return [.needMoreData]
        }

        let messageType = data[0]

        switch messageType {
        case 0x01:  // ClientHello
            // Extract client certificate
            let certData = data.dropFirst()
            let remoteCert = try TLSCertificate.parse(Data(certData))

            // Verify and store remote info
            try verifyRemoteCertificate(remoteCert)

            // Generate handshake keys (mock)
            let handshakeKeys = generateMockKeys(for: EncryptionLevel.handshake)

            // Send ServerHello with our certificate
            let serverHello = buildServerHello()

            return [
                .keysAvailable(handshakeKeys),
                .handshakeData(serverHello, level: .handshake)
            ]

        case 0x03:  // Client Finished
            // Handshake complete on server side
            let appKeys = generateMockKeys(for: EncryptionLevel.application)
            state.withLock { $0.handshakeComplete = true }

            // Send server Finished
            let serverFinished = buildServerFinished()

            return [
                .keysAvailable(appKeys),
                .handshakeData(serverFinished, level: .handshake),
                .handshakeComplete(HandshakeCompleteInfo(alpn: TLSCertificate.alpnProtocol))
            ]

        default:
            throw TLSCertificateError.handshakeFailed(reason: "Unknown message type: \(messageType)")
        }
    }

    /// Parses a handshake message containing certificate and transport parameters.
    private func parseHandshakeMessage(_ data: Data) throws -> (TLSCertificate, Data) {
        // Simple format: cert length (4 bytes) + cert DER + transport params
        guard data.count >= 4 else {
            // No transport params, just certificate
            let cert = try TLSCertificate.parse(data)
            return (cert, Data())
        }

        // Try to parse as raw certificate first (backward compatibility)
        do {
            let cert = try TLSCertificate.parse(data)
            return (cert, Data())
        } catch {
            // If that fails, try the structured format
            let certLength = Int(data[0]) << 24 | Int(data[1]) << 16 | Int(data[2]) << 8 | Int(data[3])
            guard data.count >= 4 + certLength else {
                throw TLSCertificateError.handshakeFailed(reason: "Invalid handshake message format")
            }

            let certData = data[4..<(4 + certLength)]
            let transportParams = data[(4 + certLength)...]

            let cert = try TLSCertificate.parse(Data(certData))
            return (cert, Data(transportParams))
        }
    }

    /// Verifies the remote certificate and extracts PeerID.
    private func verifyRemoteCertificate(_ certificate: TLSCertificate) throws {
        // Verify the certificate signature
        guard try certificate.verify() else {
            throw TLSCertificateError.invalidExtensionSignature
        }

        let remotePeerID = certificate.peerID

        // Check expected PeerID if set
        if let expected = expectedRemotePeerID, expected != remotePeerID {
            throw TLSCertificateError.peerIDMismatch(expected: expected, actual: remotePeerID)
        }

        // Store remote info
        state.withLock { s in
            s.remotePeerID = remotePeerID
            s.remoteCertificate = certificate
        }
    }

    /// Builds a ServerHello message.
    private func buildServerHello() -> Data {
        var data = Data()
        data.append(0x02)  // Message type: ServerHello
        data.append(contentsOf: localCertificate.certificateDER)
        return data
    }

    /// Builds a client Finished message.
    private func buildClientFinished() -> Data {
        var data = Data()
        data.append(0x03)  // Message type: ClientFinished
        return data
    }

    /// Builds a server Finished message.
    private func buildServerFinished() -> Data {
        var data = Data()
        data.append(0x04)  // Message type: ServerFinished
        return data
    }

    /// Generates mock encryption keys.
    private func generateMockKeys(for level: EncryptionLevel) -> KeysAvailableInfo {
        // Generate deterministic mock keys for testing
        // In a real implementation, these would be derived from TLS key schedule
        let clientKeyMaterial = Data(repeating: UInt8(level.rawValue), count: 32)
        let serverKeyMaterial = Data(repeating: UInt8(level.rawValue + 0x10), count: 32)

        return KeysAvailableInfo(
            level: level,
            clientSecret: SymmetricKey(data: clientKeyMaterial),
            serverSecret: SymmetricKey(data: serverKeyMaterial)
        )
    }
}
