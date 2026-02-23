/// AutoRelayServiceError - Errors from AutoRelayService.

/// Errors emitted by `AutoRelayService`.
public enum AutoRelayServiceError: Error, Sendable {
    /// The service has been shut down.
    case serviceShutDown
}
