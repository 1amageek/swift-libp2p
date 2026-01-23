/// NoiseConnection - SecuredConnection implementation for Noise protocol
import Foundation
import P2PCore
import Synchronization

// MARK: - Separated State Structures

/// Send-only state for write operations.
private struct SendState: Sendable {
    var cipher: NoiseCipherState
}

/// Receive-only state for read operations.
private struct RecvState: Sendable {
    var cipher: NoiseCipherState
    var buffer: Data = Data()
}

/// Shared state accessed by both read and write.
private struct SharedState: Sendable {
    var isClosed: Bool = false
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

    /// Shared state - lightweight, accessed by both
    private let sharedState: Mutex<SharedState>

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
        self.sharedState = Mutex(SharedState())
    }

    // MARK: - SecuredConnection

    public var localAddress: Multiaddr? {
        underlying.localAddress
    }

    public var remoteAddress: Multiaddr {
        underlying.remoteAddress
    }

    public func read() async throws -> Data {
        // Try to read a complete frame
        while true {
            // 1. Check closed state (lightweight lock)
            let closed = sharedState.withLock { $0.isClosed }
            if closed {
                throw NoiseError.connectionClosed
            }

            // 2. Check buffer and decrypt (receive lock only)
            let frameResult: Result<Data?, any Error> = recvState.withLock { state in
                do {
                    if let (message, consumed) = try readNoiseMessage(from: state.buffer) {
                        state.buffer = Data(state.buffer.dropFirst(consumed))

                        // Decrypt the message
                        let plaintext = try state.cipher.decryptWithAD(Data(), ciphertext: message)
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
                throw NoiseError.connectionClosed
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
            throw NoiseError.connectionClosed
        }

        // Handle empty data: still send a frame (carries authentication)
        if data.isEmpty {
            let encrypted = try sendState.withLock { state -> Data in
                let ciphertext = try state.cipher.encryptWithAD(Data(), plaintext: Data())
                return try encodeNoiseMessage(ciphertext)
            }
            try await underlying.write(encrypted)
            return
        }

        var remaining = data[data.startIndex...]

        while !remaining.isEmpty {
            // 2. Re-check closed state in loop
            let closed = sharedState.withLock { $0.isClosed }
            if closed {
                throw NoiseError.connectionClosed
            }

            let chunkSize = min(remaining.count, noiseMaxPlaintextSize)
            let chunk = Data(remaining.prefix(chunkSize))
            remaining = remaining.dropFirst(chunkSize)

            // 3. Encrypt (send lock only)
            let encrypted = try sendState.withLock { state -> Data in
                let ciphertext = try state.cipher.encryptWithAD(Data(), plaintext: chunk)
                return try encodeNoiseMessage(ciphertext)
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
