/// CYCLON protocol wire messages.

/// Messages exchanged during a CYCLON shuffle operation.
public enum CYCLONMessage: Sendable {
    /// Initiator sends a subset of its partial view to the selected peer.
    case shuffleRequest(entries: [CYCLONEntry])

    /// Responder replies with a subset of its own partial view.
    case shuffleResponse(entries: [CYCLONEntry])
}
