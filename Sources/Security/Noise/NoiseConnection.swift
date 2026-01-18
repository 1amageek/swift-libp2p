/// NoiseConnection - SecuredConnection implementation for Noise protocol
import Foundation
import P2PCore
import Synchronization

/// Internal state for NoiseConnection.
private struct NoiseConnectionState: Sendable {
    var sendCipher: NoiseCipherState
    var recvCipher: NoiseCipherState
    var readBuffer: Data = Data()
    var isClosed: Bool = false
}

/// A secured connection using the Noise protocol.
///
/// Provides encrypted read/write over an underlying raw connection.
public final class NoiseConnection: SecuredConnection, Sendable {
    public let localPeer: PeerID
    public let remotePeer: PeerID

    private let underlying: any RawConnection
    private let state: Mutex<NoiseConnectionState>

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
        self.state = Mutex(NoiseConnectionState(
            sendCipher: sendCipher,
            recvCipher: recvCipher,
            readBuffer: initialBuffer
        ))
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
            // Check if we have a complete frame in buffer
            let frameResult: Result<Data?, any Error> = state.withLock { state in
                if state.isClosed {
                    return .failure(NoiseError.connectionClosed)
                }

                do {
                    if let (message, consumed) = try readNoiseMessage(from: state.readBuffer) {
                        state.readBuffer = Data(state.readBuffer.dropFirst(consumed))

                        // Decrypt the message
                        let plaintext = try state.recvCipher.decryptWithAD(Data(), ciphertext: message)
                        return .success(plaintext)
                    }
                } catch {
                    // Frame parsing or decryption failed - mark connection as closed
                    // and clear buffer to prevent infinite retry loops
                    state.isClosed = true
                    state.readBuffer = Data()
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

            // Need more data
            let chunk = try await underlying.read()
            if chunk.isEmpty {
                throw NoiseError.connectionClosed
            }

            state.withLock { state in
                state.readBuffer.append(chunk)
            }
        }
    }

    public func write(_ data: Data) async throws {
        // Handle empty data: still send a frame (carries authentication)
        if data.isEmpty {
            let encrypted = try state.withLock { state -> Data in
                if state.isClosed {
                    throw NoiseError.connectionClosed
                }
                let ciphertext = try state.sendCipher.encryptWithAD(Data(), plaintext: Data())
                return try encodeNoiseMessage(ciphertext)
            }
            try await underlying.write(encrypted)
            return
        }

        var remaining = data[data.startIndex...]

        while !remaining.isEmpty {
            let chunkSize = min(remaining.count, noiseMaxPlaintextSize)
            let chunk = Data(remaining.prefix(chunkSize))
            remaining = remaining.dropFirst(chunkSize)

            // Encrypt single chunk while holding lock
            let encrypted = try state.withLock { state -> Data in
                if state.isClosed {
                    throw NoiseError.connectionClosed
                }

                let ciphertext = try state.sendCipher.encryptWithAD(Data(), plaintext: chunk)
                return try encodeNoiseMessage(ciphertext)
            }

            // Write encrypted chunk immediately (outside lock)
            try await underlying.write(encrypted)
        }
    }

    public func close() async throws {
        state.withLock { state in
            state.isClosed = true
        }
        try await underlying.close()
    }
}
