/// NoiseConnection - SecuredConnection implementation for Noise protocol
import Foundation
import NIOCore
import P2PCore
import Synchronization

// MARK: - Separated State Structures

/// Send-only state for write operations.
private struct SendState: Sendable {
    var cipher: NoiseCipherState
    var isClosed: Bool = false
}

/// Threshold for compacting the receive buffer (64KB)
private let noiseRecvBufferCompactThreshold = 64 * 1024

/// Receive-only state for read operations.
private struct RecvState: Sendable {
    var cipher: NoiseCipherState
    var buffer: ByteBuffer = ByteBuffer()
    var isClosed: Bool = false

    /// Advances the buffer offset and compacts if needed.
    mutating func compactBufferIfNeeded() {
        if buffer.readerIndex > noiseRecvBufferCompactThreshold {
            buffer.discardReadBytes()
        }
    }
}

// MARK: - NoiseConnection

/// A secured connection using the Noise protocol.
///
/// Provides encrypted read/write over an underlying raw connection.
/// Uses separate locks for send and receive operations to enable
/// full-duplex communication without lock contention.
public final class NoiseConnection: SecuredConnection, Sendable {
    public let localPeer: PeerID
    public let remotePeer: PeerID

    private let underlying: any RawConnection

    /// Send state - only accessed by write()
    private let sendState: Mutex<SendState>

    /// Receive state - only accessed by read()
    private let recvState: Mutex<RecvState>

    /// Creates a new NoiseConnection.
    ///
    /// - Parameters:
    ///   - underlying: The raw connection to encrypt
    ///   - localPeer: Our peer ID
    ///   - remotePeer: Remote peer ID
    ///   - sendCipher: Cipher state for sending
    ///   - recvCipher: Cipher state for receiving
    ///   - initialBuffer: Any data already read during handshake
    init(
        underlying: any RawConnection,
        localPeer: PeerID,
        remotePeer: PeerID,
        sendCipher: NoiseCipherState,
        recvCipher: NoiseCipherState,
        initialBuffer: ByteBuffer = ByteBuffer()
    ) {
        self.underlying = underlying
        self.localPeer = localPeer
        self.remotePeer = remotePeer
        self.sendState = Mutex(SendState(cipher: sendCipher))
        self.recvState = Mutex(RecvState(cipher: recvCipher, buffer: initialBuffer))
    }

    // MARK: - SecuredConnection

    public var localAddress: Multiaddr? {
        underlying.localAddress
    }

    public var remoteAddress: Multiaddr {
        underlying.remoteAddress
    }

    public func read() async throws -> ByteBuffer {
        // Try to read a complete frame
        while true {
            // 1. Check closed + buffer atomically (receive lock)
            let frameResult: Result<ByteBuffer?, any Error> = recvState.withLock { state in
                if state.isClosed {
                    return .failure(NoiseError.connectionClosed)
                }
                do {
                    if let message = try readLengthPrefixedFrame(
                        from: &state.buffer,
                        maxMessageSize: noiseMaxMessageSize
                    ) {
                        state.compactBufferIfNeeded()

                        // Decrypt the message
                        let plaintext = try state.cipher.decryptWithAD(Data(), ciphertext: message.readableBytesView)
                        return .success(ByteBuffer(bytes: plaintext))
                    }
                } catch {
                    // Frame parsing or decryption failed - clear buffer to prevent infinite retry
                    state.buffer = ByteBuffer()
                    state.isClosed = true
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
                throw error
            }

            // 2. Read from network (no lock held)
            let chunk = try await underlying.read()
            if chunk.readableBytes == 0 {
                throw NoiseError.connectionClosed
            }

            // 3. Append to buffer (receive lock only)
            recvState.withLock { state in
                var mutableChunk = chunk
                state.buffer.writeBuffer(&mutableChunk)
            }
        }
    }

    public func write(_ data: ByteBuffer) async throws {
        // Handle empty data: still send a frame (carries authentication)
        if data.readableBytes == 0 {
            let encrypted = try sendState.withLock { state -> ByteBuffer in
                guard !state.isClosed else { throw NoiseError.connectionClosed }
                let ciphertext = try state.cipher.encryptWithAD(Data(), plaintext: Data())
                var buffer = ByteBuffer()
                try encodeLengthPrefixedFrame(ciphertext, maxMessageSize: noiseMaxMessageSize, into: &buffer)
                return buffer
            }
            try await underlying.write(encrypted)
            return
        }

        var remaining = data

        while remaining.readableBytes > 0 {
            let chunkSize = min(remaining.readableBytes, noiseMaxPlaintextSize)
            guard let chunk = remaining.readSlice(length: chunkSize) else {
                throw NoiseError.connectionClosed
            }

            // Check closed + encrypt atomically (send lock)
            let encrypted = try sendState.withLock { state -> ByteBuffer in
                guard !state.isClosed else { throw NoiseError.connectionClosed }
                let ciphertext = try state.cipher.encryptWithAD(Data(), plaintext: chunk.readableBytesView)
                var buffer = ByteBuffer()
                try encodeLengthPrefixedFrame(ciphertext, maxMessageSize: noiseMaxMessageSize, into: &buffer)
                return buffer
            }

            // Write to network (no lock held)
            try await underlying.write(encrypted)
        }
    }

    public func close() async throws {
        recvState.withLock { $0.isClosed = true }
        sendState.withLock { $0.isClosed = true }
        try await underlying.close()
    }
}
