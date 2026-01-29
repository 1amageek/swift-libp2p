/// ResourceTrackedStream - MuxedStream wrapper with automatic resource release
///
/// Wraps a MuxedStream and calls releaseStream on the resource manager
/// when the stream is closed or reset. Ensures release is called exactly once.

import Foundation
import Synchronization
import P2PCore
import P2PMux

/// A MuxedStream wrapper that releases stream resources on close/reset.
///
/// ## Guarantees
///
/// - Release is called exactly once, regardless of how many times
///   `close()` or `reset()` is called.
/// - Release is also called on `deinit` if the stream was not explicitly closed.
internal final class ResourceTrackedStream: MuxedStream, Sendable {

    private let underlying: MuxedStream
    private let peer: PeerID
    private let direction: ConnectionDirection
    private let resourceManager: any ResourceManager
    private let released: Mutex<Bool>

    init(
        stream: MuxedStream,
        peer: PeerID,
        direction: ConnectionDirection,
        resourceManager: any ResourceManager
    ) {
        self.underlying = stream
        self.peer = peer
        self.direction = direction
        self.resourceManager = resourceManager
        self.released = Mutex(false)
    }

    deinit {
        releaseOnce()
    }

    // MARK: - MuxedStream

    var id: UInt64 { underlying.id }
    var protocolID: String? { underlying.protocolID }

    func read() async throws -> Data {
        try await underlying.read()
    }

    func write(_ data: Data) async throws {
        try await underlying.write(data)
    }

    func closeWrite() async throws {
        try await underlying.closeWrite()
    }

    func closeRead() async throws {
        try await underlying.closeRead()
    }

    func close() async throws {
        releaseOnce()
        try await underlying.close()
    }

    func reset() async throws {
        releaseOnce()
        try await underlying.reset()
    }

    // MARK: - Private

    private func releaseOnce() {
        let shouldRelease = released.withLock { released in
            if released { return false }
            released = true
            return true
        }
        if shouldRelease {
            resourceManager.releaseStream(peer: peer, direction: direction)
        }
    }
}
