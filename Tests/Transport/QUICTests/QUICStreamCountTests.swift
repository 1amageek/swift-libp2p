/// QUICStreamCountTests - Regression test for the QUIC open-stream-count leak
/// fix (review finding R3).
///
/// `QUICMuxedConnection` incremented `openStreamCount` when opening/accepting a
/// stream but nothing ever decremented it, so `hasActiveStreams` stayed
/// permanently true and the connection was never idle-reclaimed. The fix adds an
/// `onTerminate` callback on `QUICMuxedStream` (mirroring `WebRTCMuxedStream`)
/// that decrements the parent's count on close/reset. This test opens then closes
/// N streams and asserts the count returns to zero.
import Testing
import Foundation
import NIOCore
import Synchronization
@testable import P2PTransportQUIC
@testable import P2PTransport
@testable import P2PCore
@testable import P2PMux
import QUIC

@Suite("QUIC Stream Count Tests")
struct QUICStreamCountTests {

    @Test("Opening then closing N streams returns openStreamCount to 0", .timeLimit(.minutes(1)))
    func closingStreamsReturnsCountToZero() async throws {
        let connection = MockQUICConnection()
        let muxed = QUICMuxedConnection(
            quicConnection: connection,
            localPeer: KeyPair.generateEd25519().peerID,
            remotePeer: KeyPair.generateEd25519().peerID,
            localAddress: nil,
            remoteAddress: try Multiaddr("/ip4/127.0.0.1/udp/4001/quic-v1")
        )

        // Initially idle.
        #expect(!muxed.hasActiveStreams)

        // Open N outbound streams.
        var streams: [MuxedStream] = []
        for _ in 0..<5 {
            streams.append(try await muxed.newStream())
        }
        #expect(muxed.hasActiveStreams)

        // Close each stream: the onTerminate callback must decrement the count.
        for stream in streams {
            try await stream.close()
        }

        // The connection is now idle again.
        #expect(!muxed.hasActiveStreams)
    }

    @Test("Resetting a stream also decrements the open count", .timeLimit(.minutes(1)))
    func resettingStreamDecrementsCount() async throws {
        let connection = MockQUICConnection()
        let muxed = QUICMuxedConnection(
            quicConnection: connection,
            localPeer: KeyPair.generateEd25519().peerID,
            remotePeer: KeyPair.generateEd25519().peerID,
            localAddress: nil,
            remoteAddress: try Multiaddr("/ip4/127.0.0.1/udp/4001/quic-v1")
        )

        let stream = try await muxed.newStream()
        #expect(muxed.hasActiveStreams)

        try await stream.reset()
        #expect(!muxed.hasActiveStreams)
    }

    @Test("closeWrite + closeRead together decrement the open count", .timeLimit(.minutes(1)))
    func halfCloseBothSidesDecrementsCount() async throws {
        let connection = MockQUICConnection()
        let muxed = QUICMuxedConnection(
            quicConnection: connection,
            localPeer: KeyPair.generateEd25519().peerID,
            remotePeer: KeyPair.generateEd25519().peerID,
            localAddress: nil,
            remoteAddress: try Multiaddr("/ip4/127.0.0.1/udp/4001/quic-v1")
        )

        let stream = try await muxed.newStream()
        #expect(muxed.hasActiveStreams)

        // Half-closing only the write side must NOT terminate yet.
        try await stream.closeWrite()
        #expect(muxed.hasActiveStreams)

        // Closing the read side completes termination.
        try await stream.closeRead()
        #expect(!muxed.hasActiveStreams)
    }
}

// MARK: - Mocks

/// A minimal `QUICStreamProtocol` that records nothing and never errors.
private final class MockQUICStream: QUICStreamProtocol, Sendable {
    let id: UInt64
    var isUnidirectional: Bool { false }
    var isBidirectional: Bool { true }

    init(id: UInt64) {
        self.id = id
    }

    func read() async throws -> Data { Data() }
    func read(maxBytes: Int) async throws -> Data { Data() }
    func write(_ data: Data) async throws {}
    func closeWrite() async throws {}
    func reset(errorCode: UInt64) async {}
    func stopSending(errorCode: UInt64) async throws {}
}

/// A minimal `QUICConnectionProtocol` that hands out `MockQUICStream`s.
private final class MockQUICConnection: QUICConnectionProtocol, Sendable {
    private let nextStreamID = Mutex<UInt64>(0)

    var localAddress: QUIC.SocketAddress? { nil }
    var remoteAddress: QUIC.SocketAddress { QUIC.SocketAddress(ipAddress: "127.0.0.1", port: 4001) }
    var currentRemoteAddress: QUIC.SocketAddress { remoteAddress }
    var isEstablished: Bool { true }

    func openStream() async throws -> any QUICStreamProtocol {
        let id = nextStreamID.withLock { current -> UInt64 in
            let value = current
            current += 1
            return value
        }
        return MockQUICStream(id: id)
    }

    func openUniStream() async throws -> any QUICStreamProtocol {
        try await openStream()
    }

    var incomingStreams: AsyncStream<any QUICStreamProtocol> {
        AsyncStream { $0.finish() }
    }

    func close(error: UInt64?) async {}
    func close(applicationError errorCode: UInt64, reason: String) async {}
}
