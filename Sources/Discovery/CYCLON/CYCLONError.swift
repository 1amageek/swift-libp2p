/// Errors specific to the CYCLON protocol.

public enum CYCLONError: Error, Sendable {
    /// The partial view is empty; cannot perform shuffle.
    case emptyView
    /// Shuffle timed out waiting for a response.
    case shuffleTimeout
    /// Received an invalid protobuf message.
    case invalidMessage
    /// Protobuf decoding failed.
    case decodingFailed(String)
    /// The service is not started.
    case notStarted
    /// Stream communication error.
    case streamError(String)
}
