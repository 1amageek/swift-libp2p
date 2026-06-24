/// TLSUpgrader - SecurityUpgrader implementation using the swift-tls `TLS` facade
import Foundation
import Crypto
import NIOCore
import P2PCore
import P2PCertificate
import P2PSecurity
import Synchronization
import TLS

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
///
/// ## Deferred peer-identity surfacing (fail-closed)
///
/// The Tier-1 `TLS` facade currently discards the `PeerIdentity` produced by the
/// certificate validator: `TLSClient.peerIdentity` / `TLSServer.peerIdentity`
/// return `nil` (a known swift-tls gap). The upgrader REQUIRES the verified
/// remote PeerID to build the `SecuredConnection`, so when the identity cannot be
/// read back, it throws `TLSError.peerIdentityUnavailable` rather than admit an
/// unidentified/unauthenticated peer. Completing libp2p-TLS authentication is
/// unblocked once the facade surfaces `peerIdentity`; see CONTEXT.md "Deferred".
public final class TLSUpgrader: SecurityUpgrader, EarlyMuxerNegotiating, Sendable {

    public var protocolID: String { tlsProtocolID }

    private let configuration: TLSUpgraderConfiguration

    /// Per-identity cache of generated self-signed certificates. The libp2p-tls
    /// spec explicitly permits reusing a single certificate across multiple
    /// connections for the same identity, so we avoid regenerating the P-256
    /// keypair and self-signed certificate on every handshake.
    private let identityCache: Mutex<[PeerID: TLSIdentity]> = Mutex([:])

    /// Creates a TLS upgrader.
    public init(configuration: TLSUpgraderConfiguration = .default) {
        self.configuration = configuration
    }

    private func cachedIdentity(for keyPair: KeyPair) throws -> TLSIdentity {
        let peerID = keyPair.peerID
        if let cached = identityCache.withLock({ $0[peerID] }) {
            return cached
        }
        let fresh = try TLSCertificateHelper.makeIdentity(keyPair: keyPair)
        return identityCache.withLock { storage -> TLSIdentity in
            if let existing = storage[peerID] {
                // Lost the race; keep the existing entry so every handshake
                // for this identity shares a single cert.
                return existing
            }
            storage[peerID] = fresh
            return fresh
        }
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
        // 1. Load (or generate and cache) the local libp2p TLS identity.
        let identity = try cachedIdentity(for: localKeyPair)

        // 2. Build ALPN list with optional muxer hints.
        let alpnProtocols = Self.buildALPNProtocols(muxerProtocols: muxerProtocols)

        // 3. Configure TLS 1.3 (mutual auth, custom libp2p certificate validator).
        //    Trust is established by the validator re-deriving the PeerID from the
        //    libp2p certificate extension; there is no X.509 CA chain to anchor.
        var tlsConfig = TLSConfiguration(
            alpnProtocols: alpnProtocols,
            verifyPeer: true,
            identity: identity,
            trustRoots: .none,
            requireClientCertificate: true,
            certificateValidator: TLSCertificateHelper.makeCertificateValidator(
                expectedPeer: expectedPeer
            )
        )
        tlsConfig.serverName = nil

        // 4. Create the role-specific facade endpoint and drive the handshake.
        //    `makeEndpoint` and the `TLSEndpoint` methods already map any facade
        //    `TLS.TLSError` to the libp2p `TLSError`, so the body below uses plain
        //    `try` (the validator throws on a bad/mismatched libp2p cert).
        let isClient = (role == .initiator)
        let endpoint = try Self.makeEndpoint(configuration: tlsConfig, isClient: isClient)

        var earlyApplicationData = ByteBuffer()
        let initialData = try await endpoint.startHandshake()
        if !initialData.isEmpty {
            try await connection.write(Self.makeByteBuffer(from: initialData))
        }

        while !endpoint.isEstablished {
            let received = try await connection.read()
            guard received.readableBytes > 0 else {
                throw TLSError.connectionClosed
            }

            let output = try await endpoint.receive(Array(received.readableBytesView))

            if !output.bytesToSend.isEmpty {
                try await connection.write(Self.makeByteBuffer(from: output.bytesToSend))
            }

            if output.peerClosed {
                throw TLSError.connectionClosed
            }

            // Capture any application data that arrived alongside handshake
            // messages (final handshake record + early app data in one TCP
            // segment).
            if !output.applicationData.isEmpty {
                earlyApplicationData.writeBytes(output.applicationData)
            }
        }

        // 5. Verify ALPN and extract early muxer negotiation result.
        guard let negotiatedALPN = endpoint.negotiatedALPN,
              negotiatedALPN.hasPrefix(earlyMuxerALPNPrefix) else {
            throw TLSError.alpnMismatch
        }
        let negotiatedMuxer = Self.extractMuxerProtocol(from: negotiatedALPN)

        // 6. Bind the verified remote PeerID from the validated certificate.
        //
        //    FAIL-CLOSED GATE: the libp2p certificate validator already ran during
        //    the handshake (rejecting a missing/invalid/mismatched libp2p
        //    extension, and `expectedPeer` mismatch). It produced a `PeerIdentity`
        //    carrying the peer's PeerID — but the `TLS` facade currently discards
        //    it (`peerIdentity` returns nil). Without the verified PeerID we cannot
        //    build a `SecuredConnection` bound to an authenticated peer, so we
        //    REJECT rather than admit an unidentified peer. This is the deferred
        //    swift-tls peer-identity surfacing gap (CONTEXT.md "Deferred"); once
        //    the facade surfaces `peerIdentity`, the branch below completes the
        //    handshake instead of throwing.
        guard let peerIdentity = endpoint.peerIdentity else {
            throw TLSError.peerIdentityUnavailable
        }
        let remotePeerID: PeerID
        do {
            remotePeerID = try PeerID(bytes: Data(peerIdentity.identifier))
        } catch {
            throw TLSError.peerIdentityUnavailable
        }
        // Defence in depth: if an expected peer was requested, the surfaced
        // identity must match it (the validator also enforces this, but the
        // upgrader must not depend solely on the validator).
        if let expectedPeer, expectedPeer != remotePeerID {
            throw TLSError.peerIDMismatch(
                expected: expectedPeer.description,
                actual: remotePeerID.description
            )
        }

        // 7. Return secured connection with any early application data.
        let securedConnection = TLSSecuredConnection(
            underlying: connection,
            endpoint: endpoint,
            localPeer: localKeyPair.peerID,
            remotePeer: remotePeerID,
            initialApplicationData: earlyApplicationData
        )

        return (connection: securedConnection, negotiatedMuxer: negotiatedMuxer)
    }

    private static func makeByteBuffer(from bytes: [UInt8]) -> ByteBuffer {
        var buffer = ByteBuffer()
        buffer.writeBytes(bytes)
        return buffer
    }

    /// Builds the role-specific facade endpoint, mapping a facade init error to
    /// the libp2p `TLSError`. A plain `catch` (no `as` pattern) is used because
    /// `catch ... as TLS.TLSError` crashes SILGen in this toolchain.
    private static func makeEndpoint(
        configuration: TLSConfiguration,
        isClient: Bool
    ) throws -> TLSEndpoint {
        do {
            if isClient {
                return .client(try TLSClient(configuration: configuration))
            } else {
                return .server(try TLSServer(configuration: configuration))
            }
        } catch {
            // `error` is the facade `TLS.TLSError` (the only thrown type here).
            throw TLSError.facade(reason: "\(error)")
        }
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
