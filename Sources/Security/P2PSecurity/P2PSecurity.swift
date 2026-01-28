/// P2PSecurity - Security protocol definitions
///
/// This module defines security abstractions only.
/// Implementations are in separate modules (P2PSecurityNoise, P2PSecurityPlaintext, etc.)

import P2PCore

/// A security protocol that upgrades raw connections.
public protocol SecurityUpgrader: Sendable {
    /// The protocol ID (e.g., "/noise").
    var protocolID: String { get }

    /// Upgrades a raw connection to a secured connection.
    ///
    /// - Parameters:
    ///   - connection: The raw connection to upgrade
    ///   - localKeyPair: The local key pair for authentication
    ///   - role: Whether we initiated or are responding
    ///   - expectedPeer: The expected remote peer ID (optional)
    /// - Returns: A secured connection
    func secure(
        _ connection: any RawConnection,
        localKeyPair: KeyPair,
        as role: SecurityRole,
        expectedPeer: PeerID?
    ) async throws -> any SecuredConnection
}

/// A security upgrader that can negotiate the muxer protocol during the security handshake.
///
/// TLS implementations can include muxer hints in the ALPN extension,
/// avoiding a separate multistream-select round trip for muxer negotiation.
public protocol EarlyMuxerNegotiating: SecurityUpgrader {
    /// Upgrades a raw connection with early muxer negotiation.
    ///
    /// - Parameters:
    ///   - connection: The raw connection
    ///   - localKeyPair: The local key pair
    ///   - role: Initiator or responder
    ///   - expectedPeer: Expected remote peer
    ///   - muxerProtocols: Available muxer protocols in priority order
    /// - Returns: The secured connection and the negotiated muxer protocol (nil if not negotiated)
    func secureWithEarlyMuxer(
        _ connection: any RawConnection,
        localKeyPair: KeyPair,
        as role: SecurityRole,
        expectedPeer: PeerID?,
        muxerProtocols: [String]
    ) async throws -> (connection: any SecuredConnection, negotiatedMuxer: String?)
}

/// The ALPN prefix for libp2p early muxer negotiation.
///
/// ALPN tokens for muxer hints use the format: `"libp2p" + muxerProtocolID`.
/// For example: `"libp2p/yamux/1.0.0"`, `"libp2p/mplex/6.7.0"`.
/// The base token `"libp2p"` is always included as a fallback.
public let earlyMuxerALPNPrefix = "libp2p"

/// Errors that can occur during security handshake.
public enum SecurityError: Error, Sendable {
    case handshakeFailed(underlying: Error)
    case peerMismatch(expected: PeerID, actual: PeerID)
    case invalidKey
    case timeout
}
