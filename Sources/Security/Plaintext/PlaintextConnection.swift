/// PlaintextConnection - Secured connection wrapper for plaintext
import Foundation
import P2PCore
import P2PSecurity
import Synchronization

/// Internal state for PlaintextConnection.
private struct PlaintextConnectionState: Sendable {
    var initialBuffer: Data
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
        initialBuffer: Data = Data()
    ) {
        self.underlying = underlying
        self.localPeer = localPeer
        self.remotePeer = remotePeer
        self.state = Mutex(PlaintextConnectionState(initialBuffer: initialBuffer))
    }

    public func read() async throws -> Data {
        // Return buffered data first if available
        let buffered = state.withLock { state -> Data? in
            if !state.initialBuffer.isEmpty {
                let data = state.initialBuffer
                state.initialBuffer = Data()
                return data
            }
            return nil
        }

        if let data = buffered {
            return data
        }

        return try await underlying.read()
    }

    public func write(_ data: Data) async throws {
        try await underlying.write(data)
    }

    public func close() async throws {
        try await underlying.close()
    }
}
