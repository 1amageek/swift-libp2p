/// PlaintextConnection - Secured connection wrapper for plaintext
import Foundation
import NIOCore
import P2PCore
import P2PSecurity
import Synchronization

/// Internal state for PlaintextConnection.
private struct PlaintextConnectionState: Sendable {
    var initialBuffer: ByteBuffer
}

/// A secured connection with no encryption.
///
/// This simply wraps the underlying connection and passes through
/// all read/write operations without modification.
public final class PlaintextConnection: SecuredConnection, Sendable {

    public let localPeer: PeerID
    public let remotePeer: PeerID

    private let underlying: any RawConnection
    private let state: Mutex<PlaintextConnectionState>

    public var localAddress: Multiaddr? {
        underlying.localAddress
    }

    public var remoteAddress: Multiaddr {
        underlying.remoteAddress
    }

    init(
        underlying: any RawConnection,
        localPeer: PeerID,
        remotePeer: PeerID,
        initialBuffer: ByteBuffer = ByteBuffer()
    ) {
        self.underlying = underlying
        self.localPeer = localPeer
        self.remotePeer = remotePeer
        self.state = Mutex(PlaintextConnectionState(initialBuffer: initialBuffer))
    }

    public func read() async throws -> ByteBuffer {
        // Return buffered data first if available
        let buffered = state.withLock { state -> ByteBuffer? in
            if state.initialBuffer.readableBytes > 0 {
                let data = state.initialBuffer
                state.initialBuffer = ByteBuffer()
                return data
            }
            return nil
        }

        if let data = buffered {
            return data
        }

        return try await underlying.read()
    }

    public func write(_ data: ByteBuffer) async throws {
        try await underlying.write(data)
    }

    public func close() async throws {
        try await underlying.close()
    }
}
