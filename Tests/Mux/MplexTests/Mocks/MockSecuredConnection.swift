/// MockSecuredConnection - Test infrastructure for Mplex tests
import Foundation
import Synchronization
@testable import P2PCore

/// A mock SecuredConnection for testing Mplex.
///
/// This mock allows tests to:
/// - Inject inbound data to simulate received frames
/// - Capture outbound data to verify sent frames
/// - Simulate connection closure and errors
final class MockSecuredConnection: SecuredConnection, Sendable {
    let localPeer: PeerID
    let remotePeer: PeerID
    var localAddress: Multiaddr? { nil }
    let remoteAddress: Multiaddr

    private let state = Mutex<MockState>(MockState())

    private struct MockState: Sendable {
        var inboundQueue: [Data] = []
        var outboundData: [Data] = []
        var readContinuation: CheckedContinuation<Data, any Error>?
        var isClosed = false
        var shouldFailWrite = false
        var writeError: (any Error & Sendable)?
    }

    init(
        localPeer: PeerID? = nil,
        remotePeer: PeerID? = nil,
        remoteAddress: Multiaddr? = nil
    ) {
        self.localPeer = localPeer ?? KeyPair.generateEd25519().peerID
        self.remotePeer = remotePeer ?? KeyPair.generateEd25519().peerID
        self.remoteAddress = remoteAddress ?? Multiaddr.tcp(host: "127.0.0.1", port: 4001)
    }

    // MARK: - Test Helpers

    /// Inject data to be read by the connection (simulates receiving data from network).
    func injectInbound(_ data: Data) {
        state.withLock { s in
            if let continuation = s.readContinuation {
                s.readContinuation = nil
                continuation.resume(returning: data)
            } else {
                s.inboundQueue.append(data)
            }
        }
    }

    /// Inject multiple frames to be read sequentially.
    func injectInbound(_ frames: [Data]) {
        for frame in frames {
            injectInbound(frame)
        }
    }

    /// Get all data that was written to this connection.
    func captureOutbound() -> [Data] {
        state.withLock { $0.outboundData }
    }

    /// Clear captured outbound data.
    func clearOutbound() {
        state.withLock { $0.outboundData.removeAll() }
    }

    /// Configure the mock to fail the next write operation.
    func setWriteFailure(_ error: any Error & Sendable) {
        state.withLock { s in
            s.shouldFailWrite = true
            s.writeError = error
        }
    }

    /// Check if the connection was closed.
    var wasClosed: Bool {
        state.withLock { $0.isClosed }
    }

    /// Force close the connection (simulates network failure).
    func forceClose() {
        state.withLock { s in
            s.isClosed = true
            if let continuation = s.readContinuation {
                s.readContinuation = nil
                continuation.resume(throwing: MockConnectionError.connectionClosed)
            }
        }
    }

    // MARK: - SecuredConnection

    func read() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            state.withLock { s in
                if s.isClosed {
                    continuation.resume(throwing: MockConnectionError.connectionClosed)
                } else if !s.inboundQueue.isEmpty {
                    let data = s.inboundQueue.removeFirst()
                    continuation.resume(returning: data)
                } else {
                    s.readContinuation = continuation
                }
            }
        }
    }

    func write(_ data: Data) async throws {
        try state.withLock { s in
            if s.isClosed {
                throw MockConnectionError.connectionClosed
            }
            if s.shouldFailWrite {
                s.shouldFailWrite = false
                if let error = s.writeError {
                    s.writeError = nil
                    throw error
                }
                throw MockConnectionError.writeFailed
            }
            s.outboundData.append(data)
        }
    }

    func close() async throws {
        let continuation = state.withLock { s -> CheckedContinuation<Data, any Error>? in
            s.isClosed = true
            let cont = s.readContinuation
            s.readContinuation = nil
            return cont
        }
        continuation?.resume(throwing: MockConnectionError.connectionClosed)
    }
}

/// Errors for MockSecuredConnection
enum MockConnectionError: Error, Sendable {
    case connectionClosed
    case writeFailed
}
