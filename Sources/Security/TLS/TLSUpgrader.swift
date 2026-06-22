/// TLSUpgrader - SecurityUpgrader implementation using swift-tls TLS 1.3
import Foundation
import Crypto
import NIOCore
import P2PCore
import P2PCertificate
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
/// - ALPN "libp2p" with optional early muxer negotiation
/// - PeerID extraction from the certificate's libp2p extension
public final class TLSUpgrader: SecurityUpgrader, EarlyMuxerNegotiating, Sendable {

    private static func makeByteBuffer<Bytes: DataProtocol>(from bytes: Bytes) -> ByteBuffer {
        var buffer = ByteBuffer()
        buffer.writeBytes(bytes)
        return buffer
    }

    public var protocolID: String { tlsProtocolID }

    private let configuration: TLSUpgraderConfiguration

    /// Per-identity cache of generated self-signed certificates. The libp2p-tls
    /// spec explicitly permits reusing a single certificate across multiple
    /// connections for the same identity, so we avoid regenerating the P-256
    /// keypair and self-signed certificate on every handshake.
    private struct CachedCertificate: Sendable {
        let certChain: [Data]
        let signingKey: TLSCore.SigningKey
    }
    private let certificateCache: Mutex<[PeerID: CachedCertificate]> = Mutex([:])

    /// Creates a TLS upgrader.
    public init(configuration: TLSUpgraderConfiguration = .default) {
        self.configuration = configuration
    }

    private func cachedCertificate(for keyPair: KeyPair) throws -> (certChain: [Data], signingKey: TLSCore.SigningKey) {
        let peerID = keyPair.peerID
        if let cached = certificateCache.withLock({ $0[peerID] }) {
            return (cached.certChain, cached.signingKey)
        }
        let fresh = try TLSCertificateHelper.generate(keyPair: keyPair)
        let finalEntry = certificateCache.withLock { storage -> CachedCertificate in
            if let existing = storage[peerID] {
                // Lost the race; keep the existing entry so every handshake
                // for this identity shares a single cert.
                return existing
            }
            let entry = CachedCertificate(
                certChain: fresh.certificateChain,
                signingKey: fresh.signingKey
            )
            storage[peerID] = entry
            return entry
        }
        return (finalEntry.certChain, finalEntry.signingKey)
    }

    public func secure(
        _ connection: any RawConnection,
        localKeyPair: KeyPair,
        as role: SecurityRole,
        expectedPeer: PeerID?
    ) async throws -> any SecuredConnection {
        let (conn, _) = try await performTimedHandshake(
            connection: connection,
            localKeyPair: localKeyPair,
            role: role,
            expectedPeer: expectedPeer,
            muxerProtocols: []
        )
        return conn
    }

    public func secureWithEarlyMuxer(
        _ connection: any RawConnection,
        localKeyPair: KeyPair,
        as role: SecurityRole,
        expectedPeer: PeerID?,
        muxerProtocols: [String]
    ) async throws -> (connection: any SecuredConnection, negotiatedMuxer: String?) {
        return try await performTimedHandshake(
            connection: connection,
            localKeyPair: localKeyPair,
            role: role,
            expectedPeer: expectedPeer,
            muxerProtocols: muxerProtocols
        )
    }

    // MARK: - Handshake

    private func performTimedHandshake(
        connection: any RawConnection,
        localKeyPair: KeyPair,
        role: SecurityRole,
        expectedPeer: PeerID?,
        muxerProtocols: [String]
    ) async throws -> (connection: any SecuredConnection, negotiatedMuxer: String?) {
        let timedOut = Mutex(false)

        let handshakeTask = Task {
            try await self.performHandshake(
                connection: connection,
                localKeyPair: localKeyPair,
                role: role,
                expectedPeer: expectedPeer,
                muxerProtocols: muxerProtocols
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

    private func performHandshake(
        connection: any RawConnection,
        localKeyPair: KeyPair,
        role: SecurityRole,
        expectedPeer: PeerID?,
        muxerProtocols: [String]
    ) async throws -> (connection: any SecuredConnection, negotiatedMuxer: String?) {
        // 1. Load (or generate and cache) self-signed certificate with libp2p extension
        let (certChain, signingKey) = try cachedCertificate(for: localKeyPair)

        // 2. Build ALPN list with optional muxer hints
        let alpnProtocols = Self.buildALPNProtocols(muxerProtocols: muxerProtocols)

        // 3. Configure TLS 1.3
        var tlsConfig = TLSCore.TLSConfiguration()
        tlsConfig.alpnProtocols = alpnProtocols
        tlsConfig.signingKey = signingKey
        tlsConfig.certificateChain = certChain
        tlsConfig.allowSelfSigned = true
        tlsConfig.verifyPeer = true
        tlsConfig.requireClientCertificate = true
        tlsConfig.certificateValidator = TLSCertificateHelper.makeCertificateValidator(
            expectedPeer: expectedPeer
        )

        // 4. Create TLS connection and perform handshake
        let tlsConn = TLSConnection(configuration: tlsConfig)
        let isClient = (role == .initiator)

        let initialData = try await tlsConn.startHandshake(isClient: isClient)
        if !initialData.isEmpty {
            try await connection.write(Self.makeByteBuffer(from: initialData))
        }

        var earlyApplicationData = ByteBuffer()

        while !tlsConn.isConnected {
            let received = try await connection.read()
            guard received.readableBytes > 0 else {
                throw TLSError.connectionClosed
            }

            let output = try await tlsConn.processReceivedData(received.readableBytesView)

            if output.alert != nil {
                throw TLSError.handshakeFailed(reason: "TLS alert received")
            }

            if !output.dataToSend.isEmpty {
                try await connection.write(Self.makeByteBuffer(from: output.dataToSend))
            }

            // Capture any application data that arrived alongside handshake messages.
            // This happens when the final handshake record and early application data
            // are delivered in the same TCP segment.
            if !output.applicationData.isEmpty {
                earlyApplicationData.writeBytes(output.applicationData)
            }
        }

        // 5. Extract PeerID from validated certificate
        guard let peerID = tlsConn.validatedPeerInfo as? PeerID else {
            throw TLSError.missingLibP2PExtension
        }

        // 5b. Post-handshake cross-check: independently re-derive the PeerID from
        // the certificate the peer ACTUALLY presented on this connection and
        // require it to match `peerID`. `validatedPeerInfo` is produced by the
        // swift-tls certificateValidator callback; this cross-check ensures we do
        // not trust a PeerID that could originate from a bypassed validator or
        // stale validator state — the bound identity must come from the leaf cert
        // on the wire. LibP2PCertificate.extractPeerID also re-verifies the
        // libp2p signature over the cert SPKI.
        guard let presentedLeaf = tlsConn.peerCertificates?.first else {
            throw TLSError.missingLibP2PExtension
        }
        let rederivedPeerID: PeerID
        do {
            rederivedPeerID = try LibP2PCertificate.extractPeerID(from: presentedLeaf)
        } catch {
            throw TLSError.invalidCertificateSignature
        }
        guard rederivedPeerID == peerID else {
            throw TLSError.peerIDMismatch(
                expected: peerID.description,
                actual: rederivedPeerID.description
            )
        }
        // If an expected peer was requested, the presented cert must match it too.
        if let expectedPeer, expectedPeer != rederivedPeerID {
            throw TLSError.peerIDMismatch(
                expected: expectedPeer.description,
                actual: rederivedPeerID.description
            )
        }

        // 6. Verify ALPN and extract early muxer negotiation result
        guard let negotiatedALPN = tlsConn.negotiatedALPN,
              negotiatedALPN.hasPrefix(earlyMuxerALPNPrefix) else {
            throw TLSError.alpnMismatch
        }

        let negotiatedMuxer = Self.extractMuxerProtocol(from: negotiatedALPN)

        // 7. Return secured connection with any early application data
        let securedConnection = TLSSecuredConnection(
            underlying: connection,
            tlsConnection: tlsConn,
            localPeer: localKeyPair.peerID,
            remotePeer: peerID,
            initialApplicationData: earlyApplicationData
        )

        return (connection: securedConnection, negotiatedMuxer: negotiatedMuxer)
    }

    // MARK: - ALPN Helpers

    /// Builds the ALPN protocol list for TLS handshake.
    ///
    /// Format: muxer-specific entries first (priority order), then `"libp2p"` as fallback.
    /// Example: `["libp2p/yamux/1.0.0", "libp2p/mplex/6.7.0", "libp2p"]`
    static func buildALPNProtocols(muxerProtocols: [String]) -> [String] {
        var alpn: [String] = []
        for muxer in muxerProtocols {
            alpn.append(earlyMuxerALPNPrefix + muxer)
        }
        alpn.append(earlyMuxerALPNPrefix)
        return alpn
    }

    /// Extracts the muxer protocol ID from a negotiated ALPN value.
    ///
    /// - Returns: The muxer protocol ID (e.g., `/yamux/1.0.0`), or nil if the ALPN
    ///   is the base `"libp2p"` token (no early muxer negotiation).
    static func extractMuxerProtocol(from alpn: String) -> String? {
        guard alpn.count > earlyMuxerALPNPrefix.count else { return nil }
        let muxerPart = String(alpn.dropFirst(earlyMuxerALPNPrefix.count))
        guard muxerPart.hasPrefix("/") else { return nil }
        return muxerPart
    }
}
