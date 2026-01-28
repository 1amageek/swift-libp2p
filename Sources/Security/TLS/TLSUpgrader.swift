/// TLSUpgrader - SecurityUpgrader implementation using swift-tls TLS 1.3
import Foundation
import Crypto
import P2PCore
import P2PSecurity
import Synchronization
import TLSCore
import TLSRecord

/// The TLS protocol ID.
public let tlsProtocolID = "/tls/1.0.0"

/// Configuration for TLS upgrader.
public struct TLSUpgraderConfiguration: Sendable {
    /// Handshake timeout.
    public var handshakeTimeout: Duration

    /// Creates a TLS upgrader configuration.
    public init(
        handshakeTimeout: Duration = .seconds(30)
    ) {
        self.handshakeTimeout = handshakeTimeout
    }

    /// Default configuration.
    public static let `default` = TLSUpgraderConfiguration()
}

/// Upgrades raw connections to secured connections using TLS 1.3.
///
/// Implements the libp2p TLS handshake specification:
/// - Self-signed X.509 certificates with libp2p extension (OID 1.3.6.1.4.1.53594.1.1)
/// - Mutual TLS authentication (both sides send certificates)
/// - ALPN "libp2p"
/// - PeerID extraction from the certificate's libp2p extension
public final class TLSUpgrader: SecurityUpgrader, Sendable {

    public var protocolID: String { tlsProtocolID }

    private let configuration: TLSUpgraderConfiguration

    /// Creates a TLS upgrader.
    public init(configuration: TLSUpgraderConfiguration = .default) {
        self.configuration = configuration
    }

    public func secure(
        _ connection: any RawConnection,
        localKeyPair: KeyPair,
        as role: SecurityRole,
        expectedPeer: PeerID?
    ) async throws -> any SecuredConnection {
        let timedOut = Mutex(false)

        let handshakeTask = Task {
            try await self.performHandshake(
                connection: connection,
                localKeyPair: localKeyPair,
                role: role,
                expectedPeer: expectedPeer
            )
        }

        let timeoutTask = Task {
            try await Task.sleep(for: configuration.handshakeTimeout)
            timedOut.withLock { $0 = true }
            handshakeTask.cancel()
        }

        do {
            let result = try await handshakeTask.value
            timeoutTask.cancel()
            return result
        } catch is CancellationError {
            timeoutTask.cancel()
            if timedOut.withLock({ $0 }) {
                throw TLSError.timeout
            }
            throw CancellationError()
        } catch {
            timeoutTask.cancel()
            throw error
        }
    }

    // MARK: - Handshake

    private func performHandshake(
        connection: any RawConnection,
        localKeyPair: KeyPair,
        role: SecurityRole,
        expectedPeer: PeerID?
    ) async throws -> any SecuredConnection {
        // 1. Generate self-signed certificate with libp2p extension
        let (certChain, signingKey) = try LibP2PCertificate.generate(keyPair: localKeyPair)

        // 2. Configure TLS 1.3
        var tlsConfig = TLSCore.TLSConfiguration()
        tlsConfig.alpnProtocols = ["libp2p"]
        tlsConfig.signingKey = signingKey
        tlsConfig.certificateChain = certChain
        tlsConfig.allowSelfSigned = true
        tlsConfig.verifyPeer = true
        tlsConfig.requireClientCertificate = true
        tlsConfig.certificateValidator = LibP2PCertificate.makeCertificateValidator(
            expectedPeer: expectedPeer
        )

        // 3. Create TLS connection and perform handshake
        let tlsConn = TLSConnection(configuration: tlsConfig)
        let isClient = (role == .initiator)

        let initialData = try await tlsConn.startHandshake(isClient: isClient)
        if !initialData.isEmpty {
            try await connection.write(initialData)
        }

        var earlyApplicationData = Data()

        while !tlsConn.isConnected {
            let received = try await connection.read()
            guard !received.isEmpty else {
                throw TLSError.connectionClosed
            }

            let output = try await tlsConn.processReceivedData(received)

            if output.alert != nil {
                throw TLSError.handshakeFailed(reason: "TLS alert received")
            }

            if !output.dataToSend.isEmpty {
                try await connection.write(output.dataToSend)
            }

            // Capture any application data that arrived alongside handshake messages.
            // This happens when the final handshake record and early application data
            // are delivered in the same TCP segment.
            if !output.applicationData.isEmpty {
                earlyApplicationData.append(output.applicationData)
            }
        }

        // 4. Extract PeerID from validated certificate
        guard let peerID = tlsConn.validatedPeerInfo as? PeerID else {
            throw TLSError.missingLibP2PExtension
        }

        // 5. Verify ALPN
        guard tlsConn.negotiatedALPN == "libp2p" else {
            throw TLSError.alpnMismatch
        }

        // 6. Return secured connection with any early application data
        return TLSSecuredConnection(
            underlying: connection,
            tlsConnection: tlsConn,
            localPeer: localKeyPair.peerID,
            remotePeer: peerID,
            initialApplicationData: earlyApplicationData
        )
    }
}
