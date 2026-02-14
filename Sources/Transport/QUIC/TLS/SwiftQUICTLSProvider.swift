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
public final class SwiftQUICTLSProvider: TLS13Provider, Sendable {

    // MARK: - Certificate Material

    /// TLS certificate material used by the QUIC TLS provider.
    ///
    /// This is used by transports that need stable certificate hashes
    /// (for example WebTransport `/certhash` verification) and by
    /// certificate rotation logic.
    public struct CertificateMaterial: Sendable {
        public let certificateDER: Data
        public let signingKey: SigningKey

        public init(certificateDER: Data, signingKey: SigningKey) {
            self.certificateDER = certificateDER
            self.signingKey = signingKey
        }
    }

    // MARK: - Properties

    /// The underlying TLS 1.3 handler from swift-quic
    private let tlsHandler: TLS13Handler

    /// The local libp2p key pair
    private let localKeyPair: KeyPair

    /// Internal state
    private let state: Mutex<ProviderState>

    private struct ProviderState: Sendable {
        var expectedRemotePeerID: PeerID?
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
    public convenience init(localKeyPair: KeyPair, expectedRemotePeerID: PeerID? = nil) throws {
        try self.init(
            localKeyPair: localKeyPair,
            expectedRemotePeerID: expectedRemotePeerID,
            alpnProtocols: ["libp2p"],
            certificateMaterial: nil
        )
    }

    /// Creates a new libp2p TLS provider with custom ALPN and certificate material.
    ///
    /// - Parameters:
    ///   - localKeyPair: The libp2p identity key pair
    ///   - expectedRemotePeerID: Optional expected remote peer ID
    ///   - alpnProtocols: ALPN protocols to advertise (default is `["libp2p"]`)
    ///   - certificateMaterial: Optional pre-generated certificate material
    /// - Throws: `TLSCertificateError` if certificate generation or setup fails
    public init(
        localKeyPair: KeyPair,
        expectedRemotePeerID: PeerID? = nil,
        alpnProtocols: [String] = ["libp2p"],
        certificateMaterial: CertificateMaterial? = nil
    ) throws {
        self.localKeyPair = localKeyPair

        let material: CertificateMaterial
        if let provided = certificateMaterial {
            material = provided
        } else {
            material = try Self.generateCertificateMaterial(for: localKeyPair)
        }

        // Configure TLS with libp2p settings
        var config = TLSConfiguration()
        config.signingKey = material.signingKey
        config.certificateChain = [material.certificateDER]
        config.alpnProtocols = alpnProtocols
        config.verifyPeer = false  // We do our own verification via libp2p extension
        config.allowSelfSigned = true

        // Enable mutual TLS - libp2p requires both peers to authenticate
        // RFC: https://github.com/libp2p/specs/blob/master/tls/tls.md
        config.requireClientCertificate = true

        // Set up libp2p-specific certificate validator
        // This is called by swift-quic's TLS layer after TLS signature verification
        let expectedPeerID = expectedRemotePeerID
        config.certificateValidator = { certChain in
            try Self.validateLibP2PCertificate(
                certChain: certChain,
                expectedPeerID: expectedPeerID
            )
        }

        // Create the underlying TLS handler
        self.tlsHandler = TLS13Handler(configuration: config)
        self.state = Mutex(ProviderState(expectedRemotePeerID: expectedRemotePeerID))
    }

    /// Generates certificate material suitable for `SwiftQUICTLSProvider`.
    ///
    /// - Parameters:
    ///   - keyPair: The libp2p identity key pair.
    ///   - validityDays: Certificate validity period in days (default: 365).
    /// - Returns: TLS certificate material.
    /// - Throws: `TLSCertificateError` if generation fails.
    public static func generateCertificateMaterial(
        for keyPair: KeyPair,
        validityDays: Int = 365
    ) throws -> CertificateMaterial {
        let (certificateDER, signingKey) = try LibP2PCertificateHelper.generateCertificate(
            keyPair: keyPair,
            validityDays: validityDays
        )
        return CertificateMaterial(certificateDER: certificateDER, signingKey: signingKey)
    }

    // MARK: - libp2p Certificate Validation

    /// Validates a libp2p certificate chain and extracts the PeerID
    ///
    /// This function:
    /// 1. Extracts the libp2p extension (OID 1.3.6.1.4.1.53594.1.1)
    /// 2. Parses the protobuf-encoded public key
    /// 3. Verifies the signature over the TLS public key
    /// 4. Derives and returns the PeerID
    ///
    /// - Parameters:
    ///   - certChain: The peer's certificate chain (DER encoded)
    ///   - expectedPeerID: If set, validation fails if PeerID doesn't match
    /// - Returns: The validated PeerID
    /// - Throws: `TLSCertificateError` on validation failure
    private static func validateLibP2PCertificate(
        certChain: [Data],
        expectedPeerID: PeerID?
    ) throws -> PeerID {
        guard let leafCertDER = certChain.first else {
            throw TLSCertificateError.missingLibp2pExtension
        }

        // Extract libp2p public key from certificate extension
        let (publicKeyBytes, signature) = try LibP2PCertificateHelper.extractLibP2PPublicKey(
            from: leafCertDER
        )

        // Parse the protobuf-encoded public key
        let libp2pPublicKey = try P2PCore.PublicKey(protobufEncoded: publicKeyBytes)

        // Parse the certificate to get SPKI for signature verification
        let peerCert = try X509Certificate.parse(from: leafCertDER)

        // Verify the signature
        // Message = "libp2p-tls-handshake:" + DER(SubjectPublicKeyInfo)
        let spkiDER = peerCert.subjectPublicKeyInfoDER
        let message = Data("libp2p-tls-handshake:".utf8) + spkiDER

        guard try libp2pPublicKey.verify(signature: signature, for: message) else {
            throw TLSCertificateError.invalidExtensionSignature
        }

        // Derive PeerID
        let peerID = libp2pPublicKey.peerID

        // Verify against expected PeerID if set
        if let expected = expectedPeerID {
            guard expected == peerID else {
                throw TLSCertificateError.peerIDMismatch(expected: expected, actual: peerID)
            }
        }

        return peerID
    }

    // MARK: - Public Accessors

    /// The local PeerID
    public var localPeerID: PeerID {
        localKeyPair.peerID
    }

    /// The remote PeerID (available after handshake completes)
    ///
    /// This is extracted from the peer's certificate during the TLS handshake
    /// via the certificateValidator callback. For the server, this is the client's
    /// PeerID. For the client, this is the server's PeerID.
    public var remotePeerID: PeerID? {
        // Single source of truth: certificate validator callback result
        tlsHandler.validatedPeerInfo as? PeerID
    }

    /// The remote peer certificate chain (DER), available after certificate message processing.
    public var peerCertificates: [Data]? {
        tlsHandler.peerCertificates
    }

    // MARK: - TLS13Provider Protocol

    public func startHandshake(isClient: Bool) async throws -> [TLSOutput] {
        try await tlsHandler.startHandshake(isClient: isClient)
    }

    public func processHandshakeData(_ data: Data, at level: EncryptionLevel) async throws -> [TLSOutput] {
        let outputs = try await tlsHandler.processHandshakeData(data, at: level)

        // Check for handshake completion
        // Note: PeerID extraction is handled by the certificate validator callback
        // and stored in tlsHandler.validatedPeerInfo
        for output in outputs {
            if case .handshakeComplete = output {
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
}
