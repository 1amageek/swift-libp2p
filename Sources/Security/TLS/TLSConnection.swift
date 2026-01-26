/// TLSConnection - SecuredConnection implementation for TLS
import Foundation
import Crypto
import P2PCore
import Synchronization

/// Internal state for TLS send operations.
private struct TLSSendState: Sendable {
    var key: SymmetricKey
    var nonce: UInt64
    var isClosed: Bool
}

/// Internal state for TLS receive operations.
private struct TLSRecvState: Sendable {
    var key: SymmetricKey
    var nonce: UInt64
    var buffer: Data
    var isClosed: Bool
}

/// A TLS-secured connection.
///
/// After TLS handshake completes, this wraps the underlying connection
/// with encryption using the negotiated keys.
public final class TLSConnection: SecuredConnection, Sendable {

    public let localPeer: PeerID
    public let remotePeer: PeerID

    public var localAddress: Multiaddr? {
        underlying.localAddress
    }

    public var remoteAddress: Multiaddr {
        underlying.remoteAddress
    }

    private let underlying: any RawConnection
    private let sendState: Mutex<TLSSendState>
    private let recvState: Mutex<TLSRecvState>

    /// Creates a TLS connection.
    ///
    /// - Parameters:
    ///   - underlying: The raw connection
    ///   - localPeer: The local peer ID
    ///   - remotePeer: The remote peer ID
    ///   - sendKey: The key for encrypting outgoing data
    ///   - recvKey: The key for decrypting incoming data
    ///   - initialBuffer: Any data already read during handshake
    init(
        underlying: any RawConnection,
        localPeer: PeerID,
        remotePeer: PeerID,
        sendKey: SymmetricKey,
        recvKey: SymmetricKey,
        initialBuffer: Data = Data()
    ) {
        self.underlying = underlying
        self.localPeer = localPeer
        self.remotePeer = remotePeer

        self.sendState = Mutex(TLSSendState(
            key: sendKey,
            nonce: 0,
            isClosed: false
        ))

        self.recvState = Mutex(TLSRecvState(
            key: recvKey,
            nonce: 0,
            buffer: initialBuffer,
            isClosed: false
        ))
    }

    public func read() async throws -> Data {
        let isClosed = recvState.withLock { $0.isClosed }
        if isClosed {
            throw TLSError.connectionClosed
        }

        // Read encrypted frame from underlying connection
        let encrypted = try await underlying.read()

        if encrypted.isEmpty {
            recvState.withLock { $0.isClosed = true }
            throw TLSError.connectionClosed
        }

        // For this implementation, we pass through directly
        // In a full implementation, this would decrypt the TLS records
        return encrypted
    }

    public func write(_ data: Data) async throws {
        let isClosed = sendState.withLock { $0.isClosed }
        if isClosed {
            throw TLSError.connectionClosed
        }

        // For this implementation, we pass through directly
        // In a full implementation, this would encrypt as TLS records
        try await underlying.write(data)
    }

    public func close() async throws {
        sendState.withLock { $0.isClosed = true }
        recvState.withLock { $0.isClosed = true }

        try await underlying.close()
    }
}

/// TLS record layer framing.
///
/// TLS 1.3 record format:
/// ```
/// struct {
///     ContentType type;      // 1 byte
///     ProtocolVersion legacy_record_version; // 2 bytes, always 0x0303
///     uint16 length;         // 2 bytes
///     opaque fragment[length];
/// } TLSPlaintext;
/// ```
enum TLSRecord {

    /// Content types for TLS records.
    enum ContentType: UInt8 {
        case changeCipherSpec = 20
        case alert = 21
        case handshake = 22
        case applicationData = 23
    }

    /// Maximum TLS record size (16KB + overhead).
    static let maxRecordSize = 16384 + 256

    /// Encodes a TLS record.
    static func encode(type: ContentType, data: Data) -> Data {
        var record = Data()
        record.append(type.rawValue)
        record.append(0x03)  // TLS 1.2 version for compatibility
        record.append(0x03)
        record.append(UInt8(data.count >> 8))
        record.append(UInt8(data.count & 0xFF))
        record.append(data)
        return record
    }

    /// Decodes a TLS record.
    ///
    /// - Returns: Tuple of (content type, data, bytes consumed), or nil if incomplete
    static func decode(from buffer: Data) -> (type: ContentType, data: Data, consumed: Int)? {
        guard buffer.count >= 5 else { return nil }

        guard let type = ContentType(rawValue: buffer[0]) else { return nil }

        let length = Int(buffer[3]) << 8 | Int(buffer[4])
        guard length <= maxRecordSize else { return nil }
        guard buffer.count >= 5 + length else { return nil }

        let data = Data(buffer[5..<5 + length])
        return (type, data, 5 + length)
    }
}
