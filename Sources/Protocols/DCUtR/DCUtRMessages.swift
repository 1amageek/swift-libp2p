/// Message types for DCUtR protocol.
///
/// DCUtR uses two message types for coordinating hole punching:
/// - CONNECT: Exchange of observed addresses
/// - SYNC: Timing synchronization for simultaneous dial

import Foundation
import P2PCore

/// Message types for DCUtR protocol.
public enum DCUtRMessageType: UInt64, Sendable {
    /// Address exchange message.
    case connect = 100

    /// Synchronization signal for hole punch timing.
    case sync = 300
}

/// A DCUtR protocol message.
public struct DCUtRMessage: Sendable {
    /// The message type.
    public let type: DCUtRMessageType

    /// Observed/predicted addresses for the peer.
    ///
    /// In CONNECT messages, these are the addresses the peer can try to dial directly.
    public let observedAddresses: [Multiaddr]

    /// Creates a new DCUtR message.
    public init(type: DCUtRMessageType, observedAddresses: [Multiaddr]) {
        self.type = type
        self.observedAddresses = observedAddresses
    }

    /// Creates a CONNECT message with the given addresses.
    public static func connect(addresses: [Multiaddr]) -> DCUtRMessage {
        DCUtRMessage(type: .connect, observedAddresses: addresses)
    }

    /// Creates a SYNC message (used to coordinate hole punch timing).
    public static func sync() -> DCUtRMessage {
        DCUtRMessage(type: .sync, observedAddresses: [])
    }
}
