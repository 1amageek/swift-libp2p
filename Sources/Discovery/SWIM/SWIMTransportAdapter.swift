/// P2PDiscoverySWIM - Adapter from NIOUDPTransport to SWIMTransport
import Foundation
import SWIM
import NIOUDPTransport
import NIOCore
import Synchronization

/// Adapts NIOUDPTransport to SWIM's SWIMTransport protocol.
public final class SWIMTransportAdapter: SWIMTransport, Sendable {

    // MARK: - Properties

    public var localAddress: String {
        _localAddress
    }
    private let _localAddress: String

    public let incomingMessages: AsyncStream<(SWIMMessage, MemberID)>

    private let udpTransport: NIOUDPTransport
    private let messageContinuation: AsyncStream<(SWIMMessage, MemberID)>.Continuation

    private struct State: Sendable {
        var receiveTask: Task<Void, Never>?
    }
    private let state = Mutex(State())

    // MARK: - Initialization

    /// Creates a new SWIM transport adapter.
    ///
    /// - Parameters:
    ///   - port: The UDP port to bind to.
    ///   - host: The host address to bind to (default: "0.0.0.0").
    public init(port: Int, host: String = "0.0.0.0") {
        self._localAddress = "\(host):\(port)"

        // Use specific bind address for custom host
        let config: UDPConfiguration
        if host == "0.0.0.0" {
            config = UDPConfiguration.unicast(port: port)
        } else {
            config = UDPConfiguration(bindAddress: .specific(host: host, port: port))
        }
        self.udpTransport = NIOUDPTransport(configuration: config)

        // Create message stream
        var continuation: AsyncStream<(SWIMMessage, MemberID)>.Continuation!
        self.incomingMessages = AsyncStream { cont in
            continuation = cont
        }
        self.messageContinuation = continuation
    }

    deinit {
        state.withLock { $0.receiveTask?.cancel() }
        messageContinuation.finish()
    }

    // MARK: - Lifecycle

    /// Starts the transport.
    public func start() async throws {
        try await udpTransport.start()

        // Start receiving task
        let task = Task { [weak self] in
            guard let self = self else { return }
            await self.receiveLoop()
        }
        state.withLock { $0.receiveTask = task }
    }

    /// Stops the transport.
    public func stop() async {
        let task = state.withLock { state -> Task<Void, Never>? in
            let t = state.receiveTask
            state.receiveTask = nil
            return t
        }
        task?.cancel()

        await udpTransport.stop()
        messageContinuation.finish()
    }

    // MARK: - SWIMTransport Protocol

    /// Sends a SWIM message to a member.
    public func send(_ message: SWIMMessage, to member: MemberID) async throws {
        let data = SWIMMessageCodec.encode(message)
        try await udpTransport.send(data, to: SocketAddress(hostPort: member.address))
    }

    // MARK: - Private Methods

    private func receiveLoop() async {
        for await datagram in udpTransport.incomingDatagrams {
            // Get sender address
            guard let senderAddress = datagram.remoteAddress.hostPortString else {
                continue
            }

            do {
                let message = try SWIMMessageCodec.decode(datagram.data)
                let senderID = MemberID(address: senderAddress)
                messageContinuation.yield((message, senderID))
            } catch {
                // Skip malformed messages
                continue
            }
        }
    }
}

// MARK: - Errors

/// Errors that can occur in the SWIM transport adapter.
public enum SWIMTransportAdapterError: Error, Sendable {
    /// Invalid address format.
    case invalidAddress(String)
    /// Transport not started.
    case notStarted
}
