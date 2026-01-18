/// AutoNATMessages - Message types for AutoNAT protocol.

import Foundation
import P2PCore

/// Message type for AutoNAT protocol.
public enum AutoNATMessageType: UInt32, Sendable {
    /// Dial request from client.
    case dial = 0
    /// Dial response from server.
    case dialResponse = 1
}

/// Peer information in AutoNAT messages.
public struct AutoNATPeerInfo: Sendable, Equatable {
    /// The peer ID.
    public let id: PeerID?

    /// The peer's addresses.
    public let addresses: [Multiaddr]

    /// Creates peer info.
    public init(id: PeerID? = nil, addresses: [Multiaddr]) {
        self.id = id
        self.addresses = addresses
    }
}

/// Dial request message.
public struct AutoNATDial: Sendable, Equatable {
    /// Information about the requesting peer.
    public let peer: AutoNATPeerInfo

    /// Creates a dial request.
    public init(peer: AutoNATPeerInfo) {
        self.peer = peer
    }
}

/// Dial response message.
public struct AutoNATDialResponse: Sendable, Equatable {
    /// Response status.
    public let status: AutoNATResponseStatus

    /// Human-readable status text.
    public let statusText: String?

    /// Successfully dialed address (if status is OK).
    public let address: Multiaddr?

    /// Creates a dial response.
    public init(
        status: AutoNATResponseStatus,
        statusText: String? = nil,
        address: Multiaddr? = nil
    ) {
        self.status = status
        self.statusText = statusText
        self.address = address
    }

    /// Creates a successful response.
    public static func ok(address: Multiaddr) -> AutoNATDialResponse {
        AutoNATDialResponse(status: .ok, address: address)
    }

    /// Creates an error response.
    public static func error(_ status: AutoNATResponseStatus, text: String? = nil) -> AutoNATDialResponse {
        AutoNATDialResponse(status: status, statusText: text)
    }
}

/// AutoNAT message (wrapper for all message types).
public struct AutoNATMessage: Sendable {
    /// The message type.
    public let type: AutoNATMessageType

    /// Dial request (if type is .dial).
    public let dial: AutoNATDial?

    /// Dial response (if type is .dialResponse).
    public let dialResponse: AutoNATDialResponse?

    /// Creates a message.
    private init(
        type: AutoNATMessageType,
        dial: AutoNATDial? = nil,
        dialResponse: AutoNATDialResponse? = nil
    ) {
        self.type = type
        self.dial = dial
        self.dialResponse = dialResponse
    }

    /// Creates a dial request message.
    public static func dial(peer: AutoNATPeerInfo) -> AutoNATMessage {
        AutoNATMessage(type: .dial, dial: AutoNATDial(peer: peer))
    }

    /// Creates a dial request message with addresses only.
    public static func dial(addresses: [Multiaddr]) -> AutoNATMessage {
        AutoNATMessage(
            type: .dial,
            dial: AutoNATDial(peer: AutoNATPeerInfo(addresses: addresses))
        )
    }

    /// Creates a dial response message.
    public static func dialResponse(_ response: AutoNATDialResponse) -> AutoNATMessage {
        AutoNATMessage(type: .dialResponse, dialResponse: response)
    }
}
