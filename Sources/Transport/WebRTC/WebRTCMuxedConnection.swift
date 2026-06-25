/// WebRTC Muxed Connection
///
/// Wraps a WebRTCConnection as a MuxedConnection for libp2p.
/// Data channels serve as multiplexed streams.
///
/// Data delivery pipeline:
/// WebRTCConnection.setDataHandler → channelID lookup → stream.deliver()
///
/// Data that arrives before its channel is registered (e.g. a DCEP open
/// and application data bundled in one SCTP packet) is held in a bounded
/// per-channel pending buffer and drained when the channel attaches.

import Foundation
import Synchronization
import Logging
import P2PCore
import P2PTransport
import P2PMux
import P2PCertificate
import WebRTC
import DataChannel

/// A WebRTC connection that conforms to MuxedConnection.
///
/// Each data channel maps to a MuxedStream, with the channel label
/// used as the protocol ID.
public final class WebRTCMuxedConnection: MuxedConnection, Sendable {

    /// Cap on bytes buffered for a channel that has not attached yet.
    /// Mirrors the per-stream read buffer cap.
    private static let maxPendingBytesPerChannel = 1 << 20

    /// Cap on bytes buffered across all unattached channels. Bounds the
    /// total memory a peer can pin by spreading data over many channel
    /// IDs before any of them attach.
    private static let maxTotalPendingBytes = 8 << 20

    /// The underlying WebRTC connection
    private let webrtcConnection: WebRTCConnection

    /// UDP socket for dial-mode connections (1:1 socket per connection).
    /// Nil for listen-mode connections where the socket is shared and
    /// owned by WebRTCSecuredListener.
    private let udpSocket: WebRTCUDPSocket?

    /// Callback invoked when the connection closes.
    /// Used by listen-mode to clean up the route table entry in the shared socket.
    private let onClose: (@Sendable () -> Void)?

    private let logger: Logger

    public let localPeer: PeerID

    /// Remote peer ID. Updated after DTLS handshake completes.
    public var remotePeer: PeerID {
        connectionState.withLock { $0.remotePeer }
    }

    public let localAddress: Multiaddr?

    /// Remote address. Updated when known from the transport layer.
    public var remoteAddress: Multiaddr {
        connectionState.withLock { $0.remoteAddress }
    }

    public var hasActiveStreams: Bool {
        connectionState.withLock { !$0.streams.isEmpty }
    }

    private let connectionState: Mutex<ConnectionState>

    private struct ConnectionState: Sendable {
        var remotePeer: PeerID
        var remoteAddress: Multiaddr
        var nextStreamID: UInt64 = 0
        var streams: [UInt64: WebRTCMuxedStream] = [:]
        /// Reverse lookup: data channel ID → stream ID for data delivery
        var channelToStream: [UInt16: UInt64] = [:]
        /// Data received for channels that have not attached yet,
        /// keyed by channel ID, in arrival order.
        var pendingData: [UInt16: [Data]] = [:]
        var pendingBytes: [UInt16: Int] = [:]
        /// Invariant: sum of `pendingBytes` values.
        var totalPendingBytes: Int = 0
        /// Channels whose pending buffer overflowed. Their stream is
        /// failed explicitly at attach time instead of dropping data
        /// silently.
        var poisonedChannels: Set<UInt16> = []
        /// Channels whose stream has terminated. Closing is local-only
        /// (DCEP has no close message), so the peer may keep sending;
        /// late data must be dropped instead of re-accumulating in the
        /// pending buffer. Bounded by the UInt16 channel ID space and
        /// cleared on terminate.
        var closedChannels: Set<UInt16> = []
        var didStartForwarding: Bool = false
        /// Created eagerly at init so inbound streams arriving before the
        /// first subscription are buffered rather than dropped.
        var inboundStream: AsyncStream<MuxedStream>
        var inboundContinuation: AsyncStream<MuxedStream>.Continuation?
        var isClosed: Bool = false
    }

    public convenience init(
        webrtcConnection: WebRTCConnection,
        localPeer: PeerID,
        remotePeer: PeerID,
        localAddress: Multiaddr?,
        remoteAddress: Multiaddr
    ) {
        self.init(
            webrtcConnection: webrtcConnection,
            localPeer: localPeer,
            remotePeer: remotePeer,
            localAddress: localAddress,
            remoteAddress: remoteAddress,
            udpSocket: nil,
            onClose: nil
        )
    }

    /// Internal initializer with optional UDP socket ownership and close callback.
    ///
    /// - Parameters:
    ///   - udpSocket: Dial-mode connections own their socket (1:1). Nil for listen-mode.
    ///   - onClose: Called when the connection closes. Listen-mode uses this to
    ///     clean up the route table entry in the shared socket.
    init(
        webrtcConnection: WebRTCConnection,
        localPeer: PeerID,
        remotePeer: PeerID,
        localAddress: Multiaddr?,
        remoteAddress: Multiaddr,
        udpSocket: WebRTCUDPSocket?,
        onClose: (@Sendable () -> Void)? = nil
    ) {
        self.webrtcConnection = webrtcConnection
        self.udpSocket = udpSocket
        self.onClose = onClose
        self.logger = Logger(label: "swift-libp2p.WebRTCMuxedConnection")
        self.localPeer = localPeer
        self.localAddress = localAddress
        let (stream, continuation) = AsyncStream<MuxedStream>.makeStream()
        self.connectionState = Mutex(ConnectionState(
            remotePeer: remotePeer,
            remoteAddress: remoteAddress,
            inboundStream: stream,
            inboundContinuation: continuation
        ))
    }

    // MARK: - Peer/Address updates

    /// Update the remote peer ID (e.g., after DTLS handshake reveals the certificate).
    public func updateRemotePeer(_ peer: PeerID) {
        connectionState.withLock { $0.remotePeer = peer }
    }

    /// Update the remote address (e.g., after learning the peer's actual address).
    public func updateRemoteAddress(_ address: Multiaddr) {
        connectionState.withLock { $0.remoteAddress = address }
    }

    /// Attempts to extract the remote PeerID from the DTLS certificate.
    ///
    /// After the DTLS handshake completes, the remote peer's DER-encoded
    /// certificate becomes available. This method extracts the libp2p
    /// public key from the certificate's extension (OID 1.3.6.1.4.1.53594.1.1)
    /// and derives the PeerID, updating `remotePeer` if successful.
    ///
    /// - Returns: The extracted PeerID, or `nil` if the handshake has not completed yet.
    /// - Throws: `LibP2PCertificateError` if the certificate is available but invalid.
    @discardableResult
    public func tryExtractRemotePeerID() throws -> PeerID? {
        guard let certDER = webrtcConnection.remoteCertificateDER else {
            return nil
        }
        // swift-webrtc surfaces the DER as `[UInt8]`; bridge to the `Data`-based
        // certificate parser at this boundary (byte-identical, no behavior change).
        let peerID = try LibP2PCertificate.extractPeerID(from: Data(certDER))
        updateRemotePeer(peerID)
        return peerID
    }

    // MARK: - MuxedConnection

    /// Opens a new outbound stream (data channel).
    public func newStream() async throws -> MuxedStream {
        let isClosed = connectionState.withLock { $0.isClosed }
        guard !isClosed else {
            throw TransportError.connectionClosed
        }

        let streamID = connectionState.withLock { s -> UInt64 in
            let id = s.nextStreamID
            s.nextStreamID += 1
            return id
        }

        let channel: DataChannel
        do {
            channel = try webrtcConnection.openDataChannel(
                label: "stream-\(streamID)",
                ordered: true
            )
        } catch {
            throw TransportError.connectionFailed(underlying: error)
        }

        let stream = WebRTCMuxedStream(
            id: streamID,
            channel: channel,
            connection: webrtcConnection,
            protocolID: nil,
            onTerminate: { [weak self] streamID, channelID in
                self?.removeStream(id: streamID, channelID: channelID)
            }
        )

        try attachChannel(channel.id, to: stream)
        return stream
    }

    /// Accepts an incoming stream.
    public func acceptStream() async throws -> MuxedStream {
        for await stream in inboundStreams {
            return stream
        }
        throw TransportError.connectionClosed
    }

    /// Stream of incoming data channels as MuxedStreams.
    ///
    /// The stream is created eagerly at init, so channels that arrive
    /// before the first subscription are buffered rather than dropped.
    public var inboundStreams: AsyncStream<MuxedStream> {
        connectionState.withLock { $0.inboundStream }
    }

    /// Start forwarding incoming data channels to the inbound streams
    /// and connect the data delivery pipeline.
    public func startForwarding() {
        let alreadyStarted = connectionState.withLock { s -> Bool in
            if s.didStartForwarding { return true }
            s.didStartForwarding = true
            return false
        }
        guard !alreadyStarted else { return }

        // Connect data delivery pipeline: received data → stream.deliver().
        // Data for unattached channels is buffered so a DCEP open and its
        // data bundled in one SCTP packet are not lost.
        webrtcConnection.setDataHandler { [weak self] channelID, data in
            guard let self else { return }

            enum Route {
                case deliver(WebRTCMuxedStream)
                case buffered
                case dropped
                /// Pending buffer overflowed; an already-attached stream (if any)
                /// is failed synchronously so the loss is surfaced immediately
                /// rather than only when the channel later attaches.
                case poisoned(WebRTCMuxedStream?)
            }

            let route = connectionState.withLock { s -> Route in
                if s.isClosed { return .dropped }
                if let streamID = s.channelToStream[channelID],
                   let stream = s.streams[streamID] {
                    return .deliver(stream)
                }
                // Late data for a locally closed channel: the reader
                // relinquished interest, mirror the stream-level drop
                if s.closedChannels.contains(channelID) {
                    return .dropped
                }
                if s.poisonedChannels.contains(channelID) {
                    return .dropped
                }
                let bytes = (s.pendingBytes[channelID] ?? 0) + data.count
                if bytes > Self.maxPendingBytesPerChannel
                    || s.totalPendingBytes + data.count > Self.maxTotalPendingBytes {
                    // Explicit poisoning instead of a silent drop. Any stream
                    // already attached for this channel is failed synchronously
                    // (below); a not-yet-attached channel is failed at attach.
                    s.pendingData.removeValue(forKey: channelID)
                    s.totalPendingBytes -= s.pendingBytes.removeValue(forKey: channelID) ?? 0
                    s.poisonedChannels.insert(channelID)
                    let attached = s.channelToStream[channelID].flatMap { s.streams[$0] }
                    return .poisoned(attached)
                }
                s.pendingData[channelID, default: []].append(data)
                s.pendingBytes[channelID] = bytes
                s.totalPendingBytes += data.count
                return .buffered
            }

            switch route {
            case .deliver(let stream):
                stream.deliver(data)
            case .poisoned(let stream):
                // Surface the loss immediately on the stream if one exists.
                stream?.fail(WebRTCStreamError.receiveBufferExceeded(limit: Self.maxPendingBytesPerChannel))
            case .buffered, .dropped:
                break
            }
        }

        // Forward incoming data channels as MuxedStreams.
        // When the upstream connection terminates, incomingChannels
        // finishes (guaranteed by swift-webrtc) and the loop falls
        // through to terminate(), failing all open streams.
        Task { [weak self] in
            guard let self else { return }
            for await channel in webrtcConnection.incomingChannels {
                let streamID = connectionState.withLock { s -> UInt64 in
                    let id = s.nextStreamID
                    s.nextStreamID += 1
                    return id
                }

                let stream = WebRTCMuxedStream(
                    id: streamID,
                    channel: channel,
                    connection: webrtcConnection,
                    protocolID: channel.label,
                    onTerminate: { [weak self] streamID, channelID in
                        self?.removeStream(id: streamID, channelID: channelID)
                    }
                )

                do {
                    try attachChannel(channel.id, to: stream)
                } catch {
                    // Connection closed while attaching — stop forwarding
                    break
                }

                let continuation = connectionState.withLock { $0.inboundContinuation }
                continuation?.yield(stream)
            }
            terminate(failure: TransportError.connectionClosed)
        }
    }

    /// Closes all streams and the connection. Idempotent.
    public func close() async throws {
        terminate(failure: nil)
    }

    // MARK: - Private

    /// Register the channel → stream mapping, draining any data buffered
    /// before attachment.
    ///
    /// Pending batches are delivered outside the state lock; the mapping
    /// is registered only once no pending data remains, so direct
    /// delivery can never overtake drained data.
    private func attachChannel(_ channelID: UInt16, to stream: WebRTCMuxedStream) throws {
        while true {
            enum Step {
                case deliver([Data])
                case poisoned
                case closed
                case registered
            }

            let step = connectionState.withLock { s -> Step in
                if s.isClosed { return .closed }
                if s.poisonedChannels.contains(channelID) {
                    s.poisonedChannels.remove(channelID)
                    return .poisoned
                }
                if let pending = s.pendingData.removeValue(forKey: channelID), !pending.isEmpty {
                    s.totalPendingBytes -= s.pendingBytes.removeValue(forKey: channelID) ?? 0
                    return .deliver(pending)
                }
                s.totalPendingBytes -= s.pendingBytes.removeValue(forKey: channelID) ?? 0
                // A reused channel ID sheds the previous stream's tombstone
                s.closedChannels.remove(channelID)
                s.streams[stream.id] = stream
                s.channelToStream[channelID] = stream.id
                return .registered
            }

            switch step {
            case .deliver(let batches):
                for data in batches {
                    stream.deliver(data)
                }
            case .poisoned:
                logger.warning("Channel \(channelID) exceeded pending buffer cap before attach; failing stream")
                stream.fail(WebRTCStreamError.receiveBufferExceeded(limit: Self.maxPendingBytesPerChannel))
                return
            case .closed:
                stream.fail(TransportError.connectionClosed)
                throw TransportError.connectionClosed
            case .registered:
                return
            }
        }
    }

    /// Remove a terminated stream from the bookkeeping maps.
    private func removeStream(id: UInt64, channelID: UInt16) {
        connectionState.withLock { s in
            s.streams.removeValue(forKey: id)
            s.channelToStream.removeValue(forKey: channelID)
            // Late data for this channel must be dropped, not buffered
            s.closedChannels.insert(channelID)
        }
    }

    /// Tear down the connection. Idempotent.
    ///
    /// - Parameter failure: When non-nil, open streams are failed with
    ///   this error (terminal propagation). When nil, streams are failed
    ///   with `connectionClosed` as well — a closing connection can no
    ///   longer serve reads or writes.
    private func terminate(failure: Error?) {
        let (streams, continuation) = connectionState.withLock { s -> ([WebRTCMuxedStream], AsyncStream<MuxedStream>.Continuation?) in
            guard !s.isClosed else { return ([], nil) }
            s.isClosed = true
            let streams = Array(s.streams.values)
            s.streams.removeAll()
            s.channelToStream.removeAll()
            s.pendingData.removeAll()
            s.pendingBytes.removeAll()
            s.totalPendingBytes = 0
            s.poisonedChannels.removeAll()
            s.closedChannels.removeAll()
            let continuation = s.inboundContinuation
            s.inboundContinuation = nil
            return (streams, continuation)
        }

        // Nothing to do when another caller already terminated
        guard !streams.isEmpty || continuation != nil else { return }

        let streamError = failure ?? TransportError.connectionClosed
        for stream in streams {
            stream.fail(streamError)
        }
        continuation?.finish()

        webrtcConnection.close()
        udpSocket?.close()
        onClose?()
    }
}
