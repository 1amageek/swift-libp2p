import Foundation
import Synchronization
import P2PCore
import P2PTransport
import P2PMux
import P2PTransportQUIC
import QUIC

private final class WebTransportStreamChannel: Sendable {
    private struct State: Sendable {
        var buffer: [MuxedStream] = []
        var waiters: [CheckedContinuation<MuxedStream?, Never>] = []
        var isFinished = false
    }

    private let state = Mutex(State())

    func send(_ stream: MuxedStream) {
        let waiterToResume: CheckedContinuation<MuxedStream?, Never>? = state.withLock { state in
            guard !state.isFinished else { return nil }
            if !state.waiters.isEmpty {
                return state.waiters.removeFirst()
            }
            state.buffer.append(stream)
            return nil
        }
        waiterToResume?.resume(returning: stream)
    }

    func finish() {
        let waitersToResume: [CheckedContinuation<MuxedStream?, Never>] = state.withLock { state in
            guard !state.isFinished else { return [] }
            state.isFinished = true
            let waiters = state.waiters
            state.waiters.removeAll()
            return waiters
        }
        for waiter in waitersToResume {
            waiter.resume(returning: nil)
        }
    }

    func receive() async -> MuxedStream? {
        enum Action {
            case returnStream(MuxedStream)
            case returnNil
            case wait
        }

        return await withCheckedContinuation { continuation in
            let action: Action = state.withLock { state in
                if !state.buffer.isEmpty {
                    return .returnStream(state.buffer.removeFirst())
                }
                if state.isFinished {
                    return .returnNil
                }
                state.waiters.append(continuation)
                return .wait
            }

            switch action {
            case .returnStream(let stream):
                continuation.resume(returning: stream)
            case .returnNil:
                continuation.resume(returning: nil)
            case .wait:
                break
            }
        }
    }
}

/// A WebTransport connection backed by QUIC streams.
public final class WebTransportMuxedConnection: MuxedConnection, Sendable {
    private let quicConnection: any QUICConnectionProtocol
    private let onClose: (@Sendable () async -> Void)?
    private let _localPeer: PeerID
    private let _remotePeer: PeerID
    private let _localAddress: Multiaddr?
    private let remoteCertificateHashes: [Data]

    private let streamChannel: WebTransportStreamChannel
    private let state: Mutex<State>

    private struct State: Sendable {
        var isClosed = false
        var forwardingTask: Task<Void, Never>?
        var inboundStream: AsyncStream<MuxedStream>?
    }

    public var localPeer: PeerID { _localPeer }
    public var remotePeer: PeerID { _remotePeer }
    public var localAddress: Multiaddr? { _localAddress }

    public var remoteAddress: Multiaddr {
        let socket = quicConnection.currentRemoteAddress
        return WebTransportAddressComponents(
            host: socket.ipAddress.contains(":")
                ? .ip6(socket.ipAddress)
                : .ip4(socket.ipAddress),
            port: socket.port,
            certificateHashes: remoteCertificateHashes,
            peerID: _remotePeer
        ).toMultiaddr()
    }

    public var inboundStreams: AsyncStream<MuxedStream> {
        state.withLock { state in
            if let existing = state.inboundStream {
                return existing
            }
            let stream = AsyncStream<MuxedStream> { continuation in
                Task { [streamChannel] in
                    while let stream = await streamChannel.receive() {
                        continuation.yield(stream)
                    }
                    continuation.finish()
                }
            }
            state.inboundStream = stream
            return stream
        }
    }

    init(
        quicConnection: any QUICConnectionProtocol,
        localPeer: PeerID,
        remotePeer: PeerID,
        localAddress: Multiaddr?,
        remoteCertificateHashes: [Data],
        onClose: (@Sendable () async -> Void)? = nil
    ) {
        self.quicConnection = quicConnection
        self.onClose = onClose
        self._localPeer = localPeer
        self._remotePeer = remotePeer
        self._localAddress = localAddress
        self.remoteCertificateHashes = remoteCertificateHashes
        self.streamChannel = WebTransportStreamChannel()
        self.state = Mutex(State())
    }

    func startForwarding() {
        let task = Task { [weak self] in
            guard let self = self else { return }

            for await quicStream in self.quicConnection.incomingStreams {
                let isClosed = self.state.withLock { $0.isClosed }
                if isClosed { break }

                let base = QUICMuxedStream(stream: quicStream, protocolID: WebTransportProtocol.protocolID)
                self.streamChannel.send(WebTransportMuxedStream(base: base))
            }

            self.streamChannel.finish()
        }

        state.withLock { $0.forwardingTask = task }
    }

    public func newStream() async throws -> MuxedStream {
        let quicStream = try await quicConnection.openStream()
        let base = QUICMuxedStream(stream: quicStream, protocolID: WebTransportProtocol.protocolID)
        return WebTransportMuxedStream(base: base)
    }

    public func acceptStream() async throws -> MuxedStream {
        guard let stream = await streamChannel.receive() else {
            throw TransportError.connectionClosed
        }
        return stream
    }

    public func close() async throws {
        let (alreadyClosed, task) = state.withLock { state -> (Bool, Task<Void, Never>?) in
            let wasClosed = state.isClosed
            state.isClosed = true
            let forwardingTask = state.forwardingTask
            state.forwardingTask = nil
            return (wasClosed, forwardingTask)
        }

        guard !alreadyClosed else { return }

        streamChannel.finish()
        task?.cancel()
        await quicConnection.close(error: nil)
        if let onClose {
            await onClose()
        }
    }
}
