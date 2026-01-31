/// PlumtreeError - Error types for the Plumtree protocol
import Foundation

/// Errors that can occur during Plumtree operations.
public enum PlumtreeError: Error, Sendable {
    /// The service has not been started.
    case notStarted

    /// Message exceeds the configured maximum size.
    case messageTooLarge(size: Int, maxSize: Int)

    /// The received wire message is malformed.
    case invalidMessage

    /// Failed to decode a protobuf message.
    case decodingFailed(String)

    /// Not subscribed to the specified topic.
    case notSubscribed(String)

    /// Stream I/O error.
    case streamError(String)
}
