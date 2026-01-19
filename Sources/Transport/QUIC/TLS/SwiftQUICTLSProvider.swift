/// SwiftQUICTLSProvider - libp2p TLS provider using swift-quic's TLS13Handler
///
/// This provider wraps swift-quic's TLS13Handler to provide libp2p-specific
/// TLS functionality including:
/// - Self-signed certificates with libp2p extension (OID 1.3.6.1.4.1.53594.1.1)
/// - PeerID extraction from peer certificates
/// - ALPN "libp2p" negotiation

import Foundation
import Synchronization
import Crypto
import P2PCore
import QUICCore
import QUICCrypto

/// TLS 1.3 provider for libp2p using swift-quic's pure Swift implementation
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
public final class SwiftQUICTLSProvider: TLS13Provider, @unchecked Sendable {

    // MARK: - Properties

    /// The underlying TLS 1.3 handler from swift-quic
    private let tlsHandler: TLS13Handler

    /// The local libp2p key pair
    private let localKeyPair: KeyPair

    /// Internal state
    private let state: Mutex<ProviderState>

    private struct ProviderState: Sendable {
        var expectedRemotePeerID: PeerID?
        var remotePeerID: PeerID?
        var handshakeComplete: Bool = false
    }

    // MARK: - Initialization

    /// Creates a new libp2p TLS provider
    ///
    /// - Parameters:
    ///   - localKeyPair: The libp2p identity key pair
    ///   - expectedRemotePeerID: If set, the handshake will fail if the remote
    ///     peer's ID doesn't match (used for dial security)
    /// - Throws: `TLSCertificateError` if certificate generation fails
    public init(localKeyPair: KeyPair, expectedRemotePeerID: PeerID? = nil) throws {
        self.localKeyPair = localKeyPair

        // Generate libp2p certificate
        let (certificateDER, signingKey) = try LibP2PCertificateHelper.generateCertificate(
            keyPair: localKeyPair
        )

        // Configure TLS with libp2p settings
        var config = TLSConfiguration()
        config.signingKey = signingKey
        config.certificateChain = [certificateDER]
        config.alpnProtocols = ["libp2p"]
        config.verifyPeer = false  // We do our own verification via libp2p extension
        config.allowSelfSigned = true

        // Create the underlying TLS handler
        self.tlsHandler = TLS13Handler(configuration: config)
        self.state = Mutex(ProviderState(expectedRemotePeerID: expectedRemotePeerID))
    }

    // MARK: - Public Accessors

    /// The local PeerID
    public var localPeerID: PeerID {
        localKeyPair.peerID
    }

    /// The remote PeerID (available after handshake completes)
    public var remotePeerID: PeerID? {
        state.withLock { $0.remotePeerID }
    }

    // MARK: - TLS13Provider Protocol

    public func startHandshake(isClient: Bool) async throws -> [TLSOutput] {
        try await tlsHandler.startHandshake(isClient: isClient)
    }

    public func processHandshakeData(_ data: Data, at level: EncryptionLevel) async throws -> [TLSOutput] {
        let outputs = try await tlsHandler.processHandshakeData(data, at: level)

        // Check for handshake completion and extract PeerID
        for output in outputs {
            if case .handshakeComplete = output {
                try extractAndVerifyRemotePeerID()
                state.withLock { $0.handshakeComplete = true }
            }
        }

        return outputs
    }

    public func getLocalTransportParameters() -> Data {
        tlsHandler.getLocalTransportParameters()
    }

    public func setLocalTransportParameters(_ params: Data) throws {
        try tlsHandler.setLocalTransportParameters(params)
    }

    public func getPeerTransportParameters() -> Data? {
        tlsHandler.getPeerTransportParameters()
    }

    public var isHandshakeComplete: Bool {
        tlsHandler.isHandshakeComplete
    }

    public var isClient: Bool {
        tlsHandler.isClient
    }

    public var negotiatedALPN: String? {
        tlsHandler.negotiatedALPN
    }

    public func configureResumption(ticket: SessionTicketData, attemptEarlyData: Bool) throws {
        try tlsHandler.configureResumption(ticket: ticket, attemptEarlyData: attemptEarlyData)
    }

    public var is0RTTAccepted: Bool {
        tlsHandler.is0RTTAccepted
    }

    public var is0RTTAttempted: Bool {
        tlsHandler.is0RTTAttempted
    }

    public func requestKeyUpdate() async throws -> [TLSOutput] {
        try await tlsHandler.requestKeyUpdate()
    }

    public func exportKeyingMaterial(
        label: String,
        context: Data?,
        length: Int
    ) throws -> Data {
        try tlsHandler.exportKeyingMaterial(label: label, context: context, length: length)
    }

    // MARK: - Private Methods

    /// Extracts and verifies the remote PeerID from the peer's certificate
    private func extractAndVerifyRemotePeerID() throws {
        // Get peer certificate from TLS handler
        guard let peerCertificates = tlsHandler.peerCertificates,
              let leafCertDER = peerCertificates.first else {
            throw TLSCertificateError.missingLibp2pExtension
        }

        // Extract libp2p public key from certificate
        let (publicKeyBytes, signature) = try LibP2PCertificateHelper.extractLibP2PPublicKey(
            from: leafCertDER
        )

        // Parse the protobuf-encoded public key
        let libp2pPublicKey = try P2PCore.PublicKey(protobufEncoded: publicKeyBytes)

        // Verify the signature
        // Message = "libp2p-tls-handshake:" + DER(SubjectPublicKeyInfo)
        guard let peerCert = tlsHandler.peerCertificate else {
            throw TLSCertificateError.certificateParsingFailed(reason: "Could not parse peer certificate")
        }

        let spkiDER = peerCert.subjectPublicKeyInfoDER
        let message = Data("libp2p-tls-handshake:".utf8) + spkiDER

        guard try libp2pPublicKey.verify(signature: signature, for: message) else {
            throw TLSCertificateError.invalidExtensionSignature
        }

        // Derive PeerID
        let remotePeerID = libp2pPublicKey.peerID

        // Verify against expected PeerID if set
        if let expected = state.withLock({ $0.expectedRemotePeerID }) {
            guard expected == remotePeerID else {
                throw TLSCertificateError.peerIDMismatch(expected: expected, actual: remotePeerID)
            }
        }

        // Store the verified PeerID
        state.withLock { $0.remotePeerID = remotePeerID }
    }
}
