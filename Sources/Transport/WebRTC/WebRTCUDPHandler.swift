/// WebRTC UDP Handler
///
/// NIO ChannelInboundHandler that receives UDP datagrams and forwards
/// them to WebRTCUDPSocket for routing to the appropriate WebRTCConnection.
///
/// Thread safety: Uses Mutex<HandlerState> for safe cross-thread access.
/// The handler's channelRead runs on the NIO event loop, while setHandlers
/// is called from the setup thread after channel bind. Mutex synchronizes
/// access to callbacks and the packet buffer.

import Foundation
import Synchronization
import NIOCore

/// NIO handler that forwards incoming UDP datagrams to a callback.
///
/// This handler is installed in the NIO DatagramChannel pipeline.
/// When a UDP datagram arrives, it extracts the remote address and
/// payload bytes, then calls `onDatagram`.
///
/// Datagrams arriving before `setHandlers` is called are buffered
/// and delivered when handlers become available (no packet loss).
final class WebRTCUDPHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>

    private let handlerState: Mutex<HandlerState>

    struct HandlerState: Sendable {
        /// Callback invoked for each received datagram.
        var onDatagram: (@Sendable (SocketAddress, Data) -> Void)?
        /// Callback invoked when the channel encounters an error.
        var onError: (@Sendable (Error) -> Void)?
        /// Datagrams received before handlers were set.
        var buffered: [(SocketAddress, Data)] = []
    }

    init() {
        self.handlerState = Mutex(HandlerState())
    }

    /// Sets the datagram and error callbacks.
    ///
    /// Flushes any datagrams that arrived before callbacks were ready.
    /// Thread-safe: can be called from any thread.
    func setHandlers(
        onDatagram: @escaping @Sendable (SocketAddress, Data) -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) {
        let buffered = handlerState.withLock { state -> [(SocketAddress, Data)] in
            state.onDatagram = onDatagram
            state.onError = onError
            let b = state.buffered
            state.buffered.removeAll()
            return b
        }
        // Deliver buffered datagrams outside the lock
        for (addr, data) in buffered {
            onDatagram(addr, data)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = unwrapInboundIn(data)
        let remoteAddress = envelope.remoteAddress
        var buffer = envelope.data
        let bytes: Data
        if let readBytes = buffer.readBytes(length: buffer.readableBytes) {
            bytes = Data(readBytes)
        } else {
            bytes = Data()
        }

        // Determine action inside lock, execute outside
        enum Action {
            case deliver(@Sendable (SocketAddress, Data) -> Void)
            case buffer
        }

        let action = handlerState.withLock { state -> Action in
            if let callback = state.onDatagram {
                return .deliver(callback)
            } else {
                state.buffered.append((remoteAddress, bytes))
                return .buffer
            }
        }

        if case .deliver(let callback) = action {
            callback(remoteAddress, bytes)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        let onError = handlerState.withLock { $0.onError }
        onError?(error)
        context.close(promise: nil)
    }
}
