/// WebRTC Muxed Connection
///
/// Wraps a WebRTCConnection as a MuxedConnection for libp2p.
/// Data channels serve as multiplexed streams.
///
/// Data delivery pipeline:
/// WebRTCConnection.setDataHandler → channelID lookup → stream.deliver()

import Foundation
import Synchronization
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

    /// The underlying WebRTC connection
    private let webrtcConnection: WebRTCConnection

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

    private let connectionState: Mutex<ConnectionState>

    private struct ConnectionState: Sendable {
        var remotePeer: PeerID
        var remoteAddress: Multiaddr
        var nextStreamID: UInt64 = 0
        var streams: [UInt64: WebRTCMuxedStream] = [:]
        /// Reverse lookup: data channel ID → stream ID for data delivery
        var channelToStream: [UInt16: UInt64] = [:]
        var inboundStream: AsyncStream<MuxedStream>?
        var inboundContinuation: AsyncStream<MuxedStream>.Continuation?
        var isClosed: Bool = false
    }

    public init(
        webrtcConnection: WebRTCConnection,
        localPeer: PeerID,
        remotePeer: PeerID,
        localAddress: Multiaddr?,
        remoteAddress: Multiaddr
    ) {
        self.webrtcConnection = webrtcConnection
        self.localPeer = localPeer
        self.localAddress = localAddress
        self.connectionState = Mutex(ConnectionState(
            remotePeer: remotePeer,
            remoteAddress: remoteAddress
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
        let peerID = try LibP2PCertificate.extractPeerID(from: certDER)
        updateRemotePeer(peerID)
        return peerID
    }

    // MARK: - MuxedConnection

    /// Opens a new outbound stream (data channel).
    public func newStream() async throws -> MuxedStream {
        let isClosed = connectionState.withLock { $0.isClosed }
        guard !isClosed else {
            throw TransportError.listenerClosed
        }

        let streamID = connectionState.withLock { s -> UInt64 in
            let id = s.nextStreamID
            s.nextStreamID += 1
            return id
        }

        let channel = try webrtcConnection.openDataChannel(
            label: "stream-\(streamID)",
            ordered: true
        )

        let stream = WebRTCMuxedStream(
            id: streamID,
            channel: channel,
            connection: webrtcConnection,
            protocolID: nil
        )

        connectionState.withLock { s in
            s.streams[streamID] = stream
            s.channelToStream[channel.id] = streamID
        }

        return stream
    }

    /// Accepts an incoming stream.
    public func acceptStream() async throws -> MuxedStream {
        for await stream in inboundStreams {
            return stream
        }
        throw TransportError.listenerClosed
    }

    /// Stream of incoming data channels as MuxedStreams.
    public var inboundStreams: AsyncStream<MuxedStream> {
        connectionState.withLock { s in
            if let existing = s.inboundStream { return existing }
            let (stream, continuation) = AsyncStream<MuxedStream>.makeStream()
            s.inboundStream = stream
            s.inboundContinuation = continuation
            return stream
        }
    }

    /// Start forwarding incoming data channels to the inbound streams
    /// and connect the data delivery pipeline.
    public func startForwarding() {
        // Connect data delivery pipeline: received data → stream.deliver()
        webrtcConnection.setDataHandler { [weak self] channelID, data in
            guard let self else { return }
            let stream = connectionState.withLock { s -> WebRTCMuxedStream? in
                guard let streamID = s.channelToStream[channelID] else { return nil }
                return s.streams[streamID]
            }
            stream?.deliver(data)
        }

        // Forward incoming data channels as MuxedStreams
        Task { [weak self] in
            guard let self else { return }
            for await channel in webrtcConnection.incomingChannels {
                let (stream, continuation) = connectionState.withLock { s -> (WebRTCMuxedStream, AsyncStream<MuxedStream>.Continuation?) in
                    let streamID = s.nextStreamID
                    s.nextStreamID += 1

                    let stream = WebRTCMuxedStream(
                        id: streamID,
                        channel: channel,
                        connection: webrtcConnection,
                        protocolID: channel.label
                    )

                    s.streams[streamID] = stream
                    s.channelToStream[channel.id] = streamID

                    return (stream, s.inboundContinuation)
                }
                continuation?.yield(stream)
            }
        }
    }

    /// Closes all streams and the connection.
    public func close() async throws {
        let streams = connectionState.withLock { s -> [WebRTCMuxedStream] in
            s.isClosed = true
            let streams = Array(s.streams.values)
            s.streams.removeAll()
            s.channelToStream.removeAll()
            s.inboundContinuation?.finish()
            s.inboundContinuation = nil
            s.inboundStream = nil
            return streams
        }

        for stream in streams {
            try await stream.close()
        }

        webrtcConnection.close()
    }
}
