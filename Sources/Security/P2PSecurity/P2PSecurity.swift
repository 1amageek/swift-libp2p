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

/// Errors that can occur during security handshake.
public enum SecurityError: Error, Sendable {
    case handshakeFailed(underlying: Error)
    case peerMismatch(expected: PeerID, actual: PeerID)
    case invalidKey
    case timeout
}
