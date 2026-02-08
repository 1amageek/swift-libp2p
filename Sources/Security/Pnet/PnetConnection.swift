/// PnetConnection - A connection wrapped with XSalsa20 encryption for private networks
import Foundation
import NIOCore
import P2PCore
import Synchronization

// MARK: - State Structures

/// Send-only state for write operations.
private struct PnetSendState: Sendable {
    var cipher: XSalsa20
    var isClosed: Bool = false
    /// Guards against concurrent write() calls which would corrupt the stream cipher.
    var isWriting: Bool = false
}

/// Receive-only state for read operations.
private struct PnetRecvState: Sendable {
    var cipher: XSalsa20
    var isClosed: Bool = false
    /// Guards against concurrent read() calls which would corrupt the stream cipher.
    var isReading: Bool = false
}

// MARK: - PnetConnection

/// A connection wrapped with XSalsa20 encryption.
///
/// Provides transparent encryption/decryption of all data flowing through
/// the underlying raw connection. Uses separate Mutex-protected cipher
/// states for send and receive to enable full-duplex communication without
/// lock contention.
///
/// This sits below the security layer (Noise/TLS) and above raw transport,
/// encrypting all traffic including security handshake data.
///
/// **Concurrency contract**: Concurrent `read()` calls from different tasks
/// are NOT supported — the stream cipher requires strict byte ordering.
/// Similarly, concurrent `write()` calls are NOT supported. Full-duplex
/// (one reader + one writer) IS supported. Violating this contract triggers
/// a `PnetError.concurrentAccess` error rather than silent data corruption.
public final class PnetConnection: RawConnection, Sendable {
    public let localAddress: Multiaddr?
    public let remoteAddress: Multiaddr

    private let inner: any RawConnection

    /// Send cipher state - only accessed by write()
    private let sendState: Mutex<PnetSendState>

    /// Receive cipher state - only accessed by read()
    private let recvState: Mutex<PnetRecvState>

    /// Creates a new PnetConnection wrapping the given raw connection.
    ///
    /// - Parameters:
    ///   - inner: The underlying raw connection to encrypt
    ///   - sendCipher: XSalsa20 cipher initialized with PSK + local nonce (for outgoing data)
    ///   - recvCipher: XSalsa20 cipher initialized with PSK + remote nonce (for incoming data)
    init(
        inner: any RawConnection,
        sendCipher: XSalsa20,
        recvCipher: XSalsa20
    ) {
        self.inner = inner
        self.localAddress = inner.localAddress
        self.remoteAddress = inner.remoteAddress
        self.sendState = Mutex(PnetSendState(cipher: sendCipher))
        self.recvState = Mutex(PnetRecvState(cipher: recvCipher))
    }

    // MARK: - RawConnection

    public func read() async throws -> ByteBuffer {
        // Atomically check closed state and set the isReading flag.
        // This fails fast if another task is already reading, preventing
        // stream cipher keystream desynchronization.
        try recvState.withLock { state in
            if state.isClosed {
                throw PnetError.connectionFailed("Connection is closed")
            }
            if state.isReading {
                throw PnetError.concurrentAccess("Concurrent read() calls are not supported on PnetConnection")
            }
            state.isReading = true
        }

        defer {
            recvState.withLock { $0.isReading = false }
        }

        // Read encrypted data from the underlying connection
        let encryptedBuffer = try await inner.read()

        // Decrypt the data — safe because isReading guarantees exclusive access
        var data = Array(encryptedBuffer.readableBytesView)
        recvState.withLock { state in
            state.cipher.process(&data)
        }

        return ByteBuffer(bytes: data)
    }

    public func write(_ data: ByteBuffer) async throws {
        // Atomically check closed state, set isWriting flag, and encrypt.
        // Encryption happens inside the lock because it is synchronous and fast,
        // and must occur in the same serial order as the writes to the wire.
        let encrypted: [UInt8] = try sendState.withLock { state in
            guard !state.isClosed else {
                throw PnetError.connectionFailed("Connection is closed")
            }
            if state.isWriting {
                throw PnetError.concurrentAccess("Concurrent write() calls are not supported on PnetConnection")
            }
            state.isWriting = true
            var bytes = Array(data.readableBytesView)
            state.cipher.process(&bytes)
            return bytes
        }

        defer {
            sendState.withLock { $0.isWriting = false }
        }

        // Write to network (no cipher lock held)
        try await inner.write(ByteBuffer(bytes: encrypted))
    }

    public func close() async throws {
        // Atomically mark both directions as closed and determine whether
        // the underlying connection still needs to be closed.
        let alreadyClosed = recvState.withLock { state -> Bool in
            let was = state.isClosed
            state.isClosed = true
            return was
        }
        sendState.withLock { $0.isClosed = true }

        // Only close the inner connection once (idempotent close).
        guard !alreadyClosed else { return }
        try await inner.close()
    }
}
