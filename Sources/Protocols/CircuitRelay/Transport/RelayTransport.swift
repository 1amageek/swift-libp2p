/// RelayTransport - Transport that handles /p2p-circuit addresses through relays.
///
/// This transport wraps the RelayClient to provide a standard Transport interface
/// for connecting through Circuit Relay v2 relays.

import Foundation
import NIOCore
import Synchronization
import P2PCore
import P2PTransport
import P2PProtocols

/// Transport that handles `/p2p-circuit` addresses through relays.
///
/// ## Usage
///
/// ```swift
/// let relayClient = RelayClient()
/// let transport = RelayTransport(client: relayClient, opener: node)
///
/// // Dial through relay
/// let address = try Multiaddr(string: "/ip4/.../p2p/{relay}/p2p-circuit/p2p/{target}")
/// let connection = try await transport.dial(address)
///
/// // Listen via relay
/// let listenAddr = try Multiaddr(string: "/p2p/{relay}/p2p-circuit")
/// let listener = try await transport.listen(listenAddr)
/// ```
public final class RelayTransport: Transport, Sendable {

    // MARK: - Transport

    public var protocols: [[String]] {
        [["p2p-circuit"]]
    }

    // MARK: - Properties

    /// The relay client for making reservations and connections.
    public let client: RelayClient

    /// Stream opener for connecting to relays.
    private let openerRef: Mutex<(any StreamOpener)?>

    /// Current listeners indexed by relay peer.
    private let state: Mutex<TransportState>

    private struct TransportState: Sendable {
        var listeners: [PeerID: RelayListener] = [:]
    }

    // MARK: - Initialization

    /// Creates a new relay transport.
    ///
    /// - Parameters:
    ///   - client: The relay client to use.
    ///   - opener: The stream opener for connecting to relays.
    public init(client: RelayClient, opener: (any StreamOpener)? = nil) {
        self.client = client
        self.openerRef = Mutex(opener)
        self.state = Mutex(TransportState())
    }

    /// Sets the stream opener.
    ///
    /// This is useful when the opener (usually a Node) isn't available at init time.
    public func setOpener(_ opener: any StreamOpener) {
        openerRef.withLock { $0 = opener }
    }

    // MARK: - Transport Protocol

    public func dial(_ address: Multiaddr) async throws -> any RawConnection {
        guard let opener = openerRef.withLock({ $0 }) else {
            throw TransportError.connectionFailed(underlying: RelayTransportError.noOpenerConfigured)
        }

        // Parse address: /...../p2p/{relay}/p2p-circuit/p2p/{target}
        let (relay, target) = try parseCircuitAddress(address)

        // Connect through relay
        let relayedConnection = try await client.connectThrough(
            relay: relay,
            to: target,
            using: opener
        )

        // Wrap in RawConnection adapter
        return RelayedRawConnection(relayedConnection: relayedConnection)
    }

    public func listen(_ address: Multiaddr) async throws -> any Listener {
        guard let opener = openerRef.withLock({ $0 }) else {
            throw TransportError.connectionFailed(underlying: RelayTransportError.noOpenerConfigured)
        }

        // Parse address to find relay
        let relay = try parseListenAddress(address)

        // Make reservation on relay
        let reservation = try await client.reserve(on: relay, using: opener)

        // Create listener
        let listener = RelayListener(
            relay: relay,
            client: client,
            localAddress: address,
            reservation: reservation
        )

        state.withLock { s in
            s.listeners[relay] = listener
        }

        return listener
    }

    public func canDial(_ address: Multiaddr) -> Bool {
        // Check if address contains p2p-circuit
        address.protocols.contains { proto in
            if case .p2pCircuit = proto { return true }
            return false
        }
    }

    public func canListen(_ address: Multiaddr) -> Bool {
        canDial(address)
    }

    // MARK: - Address Parsing

    /// Parses a circuit address to extract relay and target peer IDs.
    ///
    /// Expected format: `/...../p2p/{relay}/p2p-circuit/p2p/{target}`
    private func parseCircuitAddress(_ address: Multiaddr) throws -> (relay: PeerID, target: PeerID) {
        var relay: PeerID?
        var target: PeerID?
        var foundCircuit = false

        for proto in address.protocols {
            switch proto {
            case .p2p(let peerID):
                if foundCircuit {
                    target = peerID
                } else {
                    relay = peerID
                }
            case .p2pCircuit:
                foundCircuit = true
            default:
                continue
            }
        }

        guard let r = relay, let t = target else {
            throw TransportError.unsupportedAddress(address)
        }

        return (r, t)
    }

    /// Parses a listen address to extract the relay peer ID.
    ///
    /// Expected format: `/p2p/{relay}/p2p-circuit` or similar
    private func parseListenAddress(_ address: Multiaddr) throws -> PeerID {
        // Find the p2p component before p2p-circuit
        var lastPeerID: PeerID?

        for proto in address.protocols {
            switch proto {
            case .p2p(let peerID):
                lastPeerID = peerID
            case .p2pCircuit:
                // The peer ID before p2p-circuit is the relay
                if let relay = lastPeerID {
                    return relay
                }
            default:
                continue
            }
        }

        // If no p2p-circuit found, use the last peer ID
        if let relay = lastPeerID {
            return relay
        }

        throw TransportError.unsupportedAddress(address)
    }
}

// MARK: - Errors

/// Errors specific to RelayTransport.
public enum RelayTransportError: Error, Sendable {
    /// No stream opener has been configured.
    case noOpenerConfigured

    /// Invalid relay address format.
    case invalidAddress(String)
}

// MARK: - RawConnection Adapter

/// Adapter that wraps a RelayedConnection as a RawConnection.
final class RelayedRawConnection: RawConnection, Sendable {
    private let relayedConnection: RelayedConnection

    var localAddress: Multiaddr? { nil }
    var remoteAddress: Multiaddr { relayedConnection.remoteAddress }

    init(relayedConnection: RelayedConnection) {
        self.relayedConnection = relayedConnection
    }

    func read() async throws -> ByteBuffer {
        try await relayedConnection.read()
    }

    func write(_ data: ByteBuffer) async throws {
        try await relayedConnection.write(data)
    }

    func close() async throws {
        try await relayedConnection.close()
    }
}
