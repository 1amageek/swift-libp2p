/// AutoRelayServiceError - Errors from AutoRelayService.

import P2PCore

/// Errors emitted by `AutoRelayService`.
public enum AutoRelayServiceError: Error, Sendable {
    /// No candidate relays available.
    case noCandidates

    /// Reservation failed on a relay.
    case reservationFailed(String)

    /// A relay peer disconnected.
    case relayDisconnected(PeerID)

    /// The service has been shut down.
    case serviceShutDown
}
