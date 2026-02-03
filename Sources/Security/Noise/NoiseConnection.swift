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
    var buffer: Data = Data()
    var bufferOffset: Int = 0
    var isClosed: Bool = false

    /// Returns the unprocessed portion of the buffer.
    var unprocessedBuffer: Data {
        buffer[bufferOffset...]
    }

    /// Advances the buffer offset and compacts if needed.
    mutating func advanceBuffer(by n: Int) {
        bufferOffset += n
        if bufferOffset > noiseRecvBufferCompactThreshold {
            buffer = Data(buffer[bufferOffset...])
            bufferOffset = 0
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
        initialBuffer: Data = Data()
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
            let frameResult: Result<Data?, any Error> = recvState.withLock { state in
                if state.isClosed {
                    return .failure(NoiseError.connectionClosed)
                }
                do {
                    if let (message, consumed) = try readNoiseMessage(from: state.unprocessedBuffer) {
                        state.advanceBuffer(by: consumed)

                        // Decrypt the message
                        let plaintext = try state.cipher.decryptWithAD(Data(), ciphertext: message)
                        return .success(plaintext)
                    }
                } catch {
                    // Frame parsing or decryption failed - clear buffer to prevent infinite retry
                    state.buffer = Data()
                    state.bufferOffset = 0
                    state.isClosed = true
                    return .failure(error)
                }
                return .success(nil)
            }

            switch frameResult {
            case .success(let data):
                if let data = data {
                    return ByteBuffer(bytes: data)
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
            let chunkData = Data(buffer: chunk)
            recvState.withLock { state in
                state.buffer.append(chunkData)
            }
        }
    }

    public func write(_ data: ByteBuffer) async throws {
        let inputData = Data(buffer: data)

        // Handle empty data: still send a frame (carries authentication)
        if inputData.isEmpty {
            let encrypted = try sendState.withLock { state -> Data in
                guard !state.isClosed else { throw NoiseError.connectionClosed }
                let ciphertext = try state.cipher.encryptWithAD(Data(), plaintext: Data())
                return try encodeNoiseMessage(ciphertext)
            }
            try await underlying.write(ByteBuffer(bytes: encrypted))
            return
        }

        var remaining = inputData[inputData.startIndex...]

        while !remaining.isEmpty {
            let chunkSize = min(remaining.count, noiseMaxPlaintextSize)
            let chunk = Data(remaining.prefix(chunkSize))
            remaining = remaining.dropFirst(chunkSize)

            // Check closed + encrypt atomically (send lock)
            let encrypted = try sendState.withLock { state -> Data in
                guard !state.isClosed else { throw NoiseError.connectionClosed }
                let ciphertext = try state.cipher.encryptWithAD(Data(), plaintext: chunk)
                return try encodeNoiseMessage(ciphertext)
            }

            // Write to network (no lock held)
            try await underlying.write(ByteBuffer(bytes: encrypted))
        }
    }

    public func close() async throws {
        recvState.withLock { $0.isClosed = true }
        sendState.withLock { $0.isClosed = true }
        try await underlying.close()
    }
}
