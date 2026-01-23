/// IdentifyError - Error types for Identify protocol
import Foundation
import P2PCore

/// Errors that can occur during Identify protocol operations.
public enum IdentifyError: Error, Sendable {
    /// Invalid protobuf message format.
    case invalidProtobuf(String)

    /// Stream error during protocol exchange.
    case streamError(String)

    /// Operation timed out.
    case timeout

    /// Not connected to the peer.
    case notConnected

    /// Protocol not supported by peer.
    case unsupported

    /// Peer ID mismatch between connection and identify message.
    case peerIDMismatch(expected: PeerID, actual: PeerID)

    /// Message exceeds maximum allowed size.
    case messageTooLarge(size: Int, max: Int)

    /// Invalid signed peer record (signature verification failed).
    case invalidSignedPeerRecord(String)
}
