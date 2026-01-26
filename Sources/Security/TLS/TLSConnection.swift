/// TLSConnection - SecuredConnection implementation for TLS
import Foundation
import Crypto
import P2PCore
import Synchronization

// MARK: - Separated State Structures

/// Send-only state for write operations.
private struct TLSSendState: Sendable {
    var cipher: TLSCipherState
}

/// Receive-only state for read operations.
private struct TLSRecvState: Sendable {
    var cipher: TLSCipherState
    var buffer: Data = Data()
}

/// Shared state accessed by both read and write.
private struct TLSSharedState: Sendable {
    var isClosed: Bool = false
}

// MARK: - TLSConnection

/// A TLS-secured connection.
///
/// After TLS handshake completes, this wraps the underlying connection
/// with AES-GCM encryption using the negotiated keys.
///
/// Uses separate locks for send and receive operations to enable
/// full-duplex communication without lock contention.
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

    /// Send state - only accessed by write()
    private let sendState: Mutex<TLSSendState>

    /// Receive state - only accessed by read()
    private let recvState: Mutex<TLSRecvState>

    /// Shared state - lightweight, accessed by both
    private let sharedState: Mutex<TLSSharedState>

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
            cipher: TLSCipherState(key: sendKey)
        ))

        self.recvState = Mutex(TLSRecvState(
            cipher: TLSCipherState(key: recvKey),
            buffer: initialBuffer
        ))

        self.sharedState = Mutex(TLSSharedState())
    }

    // MARK: - SecuredConnection

    public func read() async throws -> Data {
        // Try to read a complete frame
        while true {
            // 1. Check closed state (lightweight lock)
            let closed = sharedState.withLock { $0.isClosed }
            if closed {
                throw TLSError.connectionClosed
            }

            // 2. Check buffer and decrypt (receive lock only)
            let frameResult: Result<Data?, any Error> = recvState.withLock { state in
                do {
                    if let (message, consumed) = try readTLSMessage(from: state.buffer) {
                        state.buffer = Data(state.buffer.dropFirst(consumed))

                        // Decrypt the message
                        let plaintext = try state.cipher.decrypt(message)
                        return .success(plaintext)
                    }
                } catch {
                    // Frame parsing or decryption failed - clear buffer to prevent infinite retry
                    state.buffer = Data()
                    return .failure(error)
                }
                return .success(nil)
            }

            switch frameResult {
            case .success(let data):
                if let data = data {
                    return data
                }
            case .failure(let error):
                // Mark as closed on error
                sharedState.withLock { $0.isClosed = true }
                throw error
            }

            // 3. Read from network (no lock held)
            let chunk = try await underlying.read()
            if chunk.isEmpty {
                throw TLSError.connectionClosed
            }

            // 4. Append to buffer (receive lock only)
            recvState.withLock { state in
                state.buffer.append(chunk)
            }
        }
    }

    public func write(_ data: Data) async throws {
        // 1. Check closed state (lightweight lock)
        let closed = sharedState.withLock { $0.isClosed }
        if closed {
            throw TLSError.connectionClosed
        }

        // Handle empty data: still send a frame (carries authentication)
        if data.isEmpty {
            let encrypted = try sendState.withLock { state -> Data in
                let ciphertext = try state.cipher.encrypt(Data())
                return try encodeTLSMessage(ciphertext)
            }
            try await underlying.write(encrypted)
            return
        }

        var remaining = data[data.startIndex...]

        while !remaining.isEmpty {
            // 2. Re-check closed state in loop
            let closed = sharedState.withLock { $0.isClosed }
            if closed {
                throw TLSError.connectionClosed
            }

            let chunkSize = min(remaining.count, tlsMaxPlaintextSize)
            let chunk = Data(remaining.prefix(chunkSize))
            remaining = remaining.dropFirst(chunkSize)

            // 3. Encrypt (send lock only)
            let encrypted = try sendState.withLock { state -> Data in
                let ciphertext = try state.cipher.encrypt(chunk)
                return try encodeTLSMessage(ciphertext)
            }

            // 4. Write to network (no lock held)
            try await underlying.write(encrypted)
        }
    }

    public func close() async throws {
        sharedState.withLock { $0.isClosed = true }
        try await underlying.close()
    }
}
