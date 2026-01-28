/// TLSSecuredConnection - SecuredConnection implementation using swift-tls
///
/// Wraps a raw TCP connection with TLS 1.3 record-layer encryption
/// via `TLSConnection`. After the TLS handshake completes
/// (driven by `TLSUpgrader`), this class handles encrypting outgoing
/// application data and decrypting incoming TLS records.
import Foundation
import P2PCore
import P2PSecurity
import Synchronization
import TLSRecord

/// A TLS 1.3 secured connection.
///
/// Uses swift-tls record layer for encryption/decryption of application data.
/// The handshake is already complete when this object is created.
public final class TLSSecuredConnection: SecuredConnection, Sendable {

    public let localPeer: PeerID
    public let remotePeer: PeerID

    public var localAddress: Multiaddr? {
        underlying.localAddress
    }

    public var remoteAddress: Multiaddr {
        underlying.remoteAddress
    }

    private let underlying: any RawConnection
    private let tlsConnection: TLSConnection
    private let state: Mutex<ConnectionState>

    private struct ConnectionState: Sendable {
        var applicationDataBuffer: Data
        var isClosed: Bool = false
    }

    /// Creates a TLS secured connection.
    ///
    /// - Parameters:
    ///   - underlying: The raw TCP connection
    ///   - tlsConnection: The swift-tls connection (handshake already complete)
    ///   - localPeer: The local peer ID
    ///   - remotePeer: The remote peer ID
    ///   - initialApplicationData: Application data received during the handshake
    ///     completion that must be delivered before reading new TCP data
    init(
        underlying: any RawConnection,
        tlsConnection: TLSConnection,
        localPeer: PeerID,
        remotePeer: PeerID,
        initialApplicationData: Data = Data()
    ) {
        self.underlying = underlying
        self.tlsConnection = tlsConnection
        self.localPeer = localPeer
        self.remotePeer = remotePeer
        self.state = Mutex(ConnectionState(applicationDataBuffer: initialApplicationData))
    }

    // MARK: - SecuredConnection

    public func read() async throws -> Data {
        // Drain buffered application data first (from handshake overlap)
        let buffered = state.withLock { state -> Data? in
            guard !state.isClosed else { return nil }
            guard !state.applicationDataBuffer.isEmpty else { return nil }
            let data = state.applicationDataBuffer
            state.applicationDataBuffer = Data()
            return data
        }

        if let buffered {
            return buffered
        }

        let isClosed = state.withLock { $0.isClosed }
        if isClosed { throw TLSError.connectionClosed }

        // Read from network until we get application data
        while true {
            let received = try await underlying.read()
            guard !received.isEmpty else {
                throw TLSError.connectionClosed
            }

            let output = try await tlsConnection.processReceivedData(received)

            // Send any post-handshake response data (e.g. NewSessionTicket ack)
            if !output.dataToSend.isEmpty {
                try await underlying.write(output.dataToSend)
            }

            if !output.applicationData.isEmpty {
                return output.applicationData
            }

            // No application data in this batch (e.g. post-handshake messages only),
            // continue reading.
        }
    }

    public func write(_ data: Data) async throws {
        let isClosed = state.withLock { $0.isClosed }
        guard !isClosed else { throw TLSError.connectionClosed }

        let encrypted = try tlsConnection.writeApplicationData(data)
        try await underlying.write(encrypted)
    }

    public func close() async throws {
        state.withLock { $0.isClosed = true }
        do {
            let closeData = try tlsConnection.close()
            try await underlying.write(closeData)
        } catch {
            // Best effort to send close_notify
        }
        try await underlying.close()
    }
}
