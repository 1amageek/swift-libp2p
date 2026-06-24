/// TLSSecuredConnection - SecuredConnection over the swift-tls Tier-1 `TLS` facade
///
/// Wraps a raw TCP connection with TLS 1.3 record-layer encryption via the
/// `TLSClient`/`TLSServer` facade. After the TLS handshake completes (driven by
/// `TLSUpgrader`), this class encrypts outgoing application data and decrypts
/// incoming TLS records.
import Foundation
import NIOCore
import P2PCore
import P2PSecurity
import Synchronization
import TLS

/// Unifies the role-specific facade endpoints (`TLSClient` / `TLSServer`) behind
/// a single `[UInt8]`-currency surface, mirroring swift-webrtc's `DTLSEndpoint`.
///
/// Both facade types are `Sendable` value-semantics wrappers whose methods are
/// `async`; this enum forwards to whichever role was negotiated.
enum TLSEndpoint: Sendable {
    case client(TLSClient)
    case server(TLSServer)

    /// Maps a facade `TLS.TLSError` to the libp2p `TLSError`. Centralised here so
    /// the upgrader/secured-connection bodies use plain `try` (no
    /// `catch ... as TLS.TLSError`, which crashes SILGen in this toolchain).
    private static func mapFacadeError(_ error: TLS.TLSError) -> TLSError {
        switch error {
        case .verificationFailed(let reason):
            return .facade(reason: "verification failed: \(reason)")
        case .connectionClosed:
            return .connectionClosed
        default:
            return .facade(reason: "\(error)")
        }
    }

    func startHandshake() async throws -> [UInt8] {
        do {
            switch self {
            case .client(let c): return try await c.startHandshake()
            case .server(let s): return try await s.startHandshake()
            }
        } catch {
            throw Self.mapFacadeError(error)
        }
    }

    func receive(_ bytes: [UInt8]) async throws -> TLSOutput {
        do {
            switch self {
            case .client(let c): return try await c.receive(bytes.span)
            case .server(let s): return try await s.receive(bytes.span)
            }
        } catch {
            throw Self.mapFacadeError(error)
        }
    }

    func send(_ application: [UInt8]) async throws -> [UInt8] {
        do {
            switch self {
            case .client(let c): return try await c.send(application.span)
            case .server(let s): return try await s.send(application.span)
            }
        } catch {
            throw Self.mapFacadeError(error)
        }
    }

    func close() async throws -> [UInt8] {
        do {
            switch self {
            case .client(let c): return try await c.close()
            case .server(let s): return try await s.close()
            }
        } catch {
            throw Self.mapFacadeError(error)
        }
    }

    var isEstablished: Bool {
        switch self {
        case .client(let c): return c.isEstablished
        case .server(let s): return s.isEstablished
        }
    }

    var negotiatedALPN: String? {
        switch self {
        case .client(let c): return c.negotiatedALPN
        case .server(let s): return s.negotiatedALPN
        }
    }

    var peerIdentity: PeerIdentity? {
        switch self {
        case .client(let c): return c.peerIdentity
        case .server(let s): return s.peerIdentity
        }
    }
}

/// A TLS 1.3 secured connection.
///
/// Uses the swift-tls `TLS` facade record layer for encryption/decryption of
/// application data. The handshake is already complete when this object is
/// created.
public final class TLSSecuredConnection: SecuredConnection, Sendable {

    /// Logger for connection-lifecycle diagnostics.
    private static let logger = Logger(label: "p2p.security.tls.connection")

    private static func makeByteBuffer(from bytes: [UInt8]) -> ByteBuffer {
        var buffer = ByteBuffer()
        buffer.writeBytes(bytes)
        return buffer
    }

    public let localPeer: PeerID
    public let remotePeer: PeerID

    public var localAddress: Multiaddr? {
        underlying.localAddress
    }

    public var remoteAddress: Multiaddr {
        underlying.remoteAddress
    }

    private let underlying: any RawConnection
    private let endpoint: TLSEndpoint
    private let state: Mutex<ConnectionState>

    private struct ConnectionState: Sendable {
        var applicationDataBuffer: ByteBuffer
        var isClosed: Bool = false
    }

    /// Creates a TLS secured connection.
    ///
    /// - Parameters:
    ///   - underlying: The raw TCP connection.
    ///   - endpoint: The swift-tls facade endpoint (handshake already complete).
    ///   - localPeer: The local peer ID.
    ///   - remotePeer: The verified remote peer ID.
    ///   - initialApplicationData: Application data received during the handshake
    ///     completion that must be delivered before reading new TCP data.
    init(
        underlying: any RawConnection,
        endpoint: TLSEndpoint,
        localPeer: PeerID,
        remotePeer: PeerID,
        initialApplicationData: ByteBuffer = ByteBuffer()
    ) {
        self.underlying = underlying
        self.endpoint = endpoint
        self.localPeer = localPeer
        self.remotePeer = remotePeer
        self.state = Mutex(ConnectionState(applicationDataBuffer: initialApplicationData))
    }

    // MARK: - SecuredConnection

    public func read() async throws -> ByteBuffer {
        // Drain buffered application data first (from handshake overlap)
        let buffered = state.withLock { state -> ByteBuffer? in
            guard !state.isClosed else { return nil }
            guard state.applicationDataBuffer.readableBytes > 0 else { return nil }
            let data = state.applicationDataBuffer
            state.applicationDataBuffer = ByteBuffer()
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
            guard received.readableBytes > 0 else {
                throw TLSError.connectionClosed
            }

            let output = try await endpoint.receive(Array(received.readableBytesView))

            // Send any post-handshake response data (e.g. NewSessionTicket ack)
            if !output.bytesToSend.isEmpty {
                try await underlying.write(Self.makeByteBuffer(from: output.bytesToSend))
            }

            if output.peerClosed {
                state.withLock { $0.isClosed = true }
                throw TLSError.connectionClosed
            }

            if !output.applicationData.isEmpty {
                return Self.makeByteBuffer(from: output.applicationData)
            }

            // No application data in this batch (e.g. post-handshake messages
            // only), continue reading.
        }
    }

    public func write(_ data: ByteBuffer) async throws {
        let isClosed = state.withLock { $0.isClosed }
        guard !isClosed else { throw TLSError.connectionClosed }

        let encrypted = try await endpoint.send(Array(data.readableBytesView))
        try await underlying.write(Self.makeByteBuffer(from: encrypted))
    }

    public func close() async throws {
        state.withLock { $0.isClosed = true }
        // Sending close_notify is best-effort: the peer may have already closed
        // the socket. We must NOT silently discard the failure, however — a
        // missing/failed close_notify is the signal a truncation-attack detector
        // relies on, so it is logged rather than swallowed.
        do {
            let closeData = try await endpoint.close()
            try await underlying.write(Self.makeByteBuffer(from: closeData))
        } catch {
            Self.logger.warning(
                "Failed to send TLS close_notify; peer cannot distinguish clean close from truncation",
                metadata: [
                    "remotePeer": "\(remotePeer)",
                    "error": "\(error)"
                ]
            )
        }
        try await underlying.close()
    }
}
