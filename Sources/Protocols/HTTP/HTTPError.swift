/// HTTPError - Error types for HTTP over libp2p.

/// Errors that can occur during HTTP operations over libp2p streams.
public enum HTTPError: Error, Sendable, Equatable {
    /// The request or response headers exceed the maximum allowed size.
    case headersTooLarge(Int)

    /// The request or response body exceeds the maximum allowed size.
    case bodyTooLarge(Int)

    /// The HTTP message could not be parsed.
    case malformedMessage(String)

    /// The HTTP method is not recognized.
    case unsupportedMethod(String)

    /// No route matched the request method and path.
    case noRouteFound(String, String)

    /// The stream was closed before the operation completed.
    case streamClosed

    /// The operation timed out.
    case timeout

    /// The handler threw an error while processing the request.
    case handlerError(String)

    /// Could not open a stream to the remote peer.
    case connectionFailed(String)

    /// The Content-Length header is invalid (non-numeric, negative, overflows,
    /// exceeds the maximum body size, or is duplicated with conflicting values).
    case invalidContentLength(String)

    /// The framing requested by the message cannot be honored (e.g.
    /// `Transfer-Encoding: chunked`, which is not supported).
    case unsupportedFraming(String)
}
