/// DCUtRService - Direct Connection Upgrade through Relay service.
///
/// Coordinates hole punching to upgrade relayed connections to direct connections.

import Foundation
import Synchronization
import P2PCore
import P2PMux
import P2PProtocols

/// Configuration for DCUtRService.
public struct DCUtRConfiguration: Sendable {
    /// Timeout for hole punch attempts.
    public var timeout: Duration

    /// Maximum number of hole punch attempts per peer.
    public var maxAttempts: Int

    /// Function to get local addresses for exchange.
    public var getLocalAddresses: @Sendable () -> [Multiaddr]

    /// Dialer function for responder-side hole punching.
    /// Called when the service receives SYNC from initiator.
    public var dialer: (@Sendable (Multiaddr) async throws -> Void)?

    /// Creates a new configuration.
    public init(
        timeout: Duration = .seconds(30),
        maxAttempts: Int = 3,
        getLocalAddresses: @escaping @Sendable () -> [Multiaddr] = { [] },
        dialer: (@Sendable (Multiaddr) async throws -> Void)? = nil
    ) {
        self.timeout = timeout
        self.maxAttempts = maxAttempts
        self.getLocalAddresses = getLocalAddresses
        self.dialer = dialer
    }
}

/// DCUtR (Direct Connection Upgrade through Relay) service.
///
/// Coordinates hole punching to upgrade relayed connections to direct connections.
///
/// ## Usage
///
/// ```swift
/// let dcutr = DCUtRService(configuration: .init(
///     getLocalAddresses: { node.listenAddresses }
/// ))
/// await dcutr.registerHandler(registry: node)
///
/// // Attempt to upgrade a relayed connection
/// try await dcutr.upgradeToDirectConnection(
///     with: remotePeer,
///     using: node,
///     dialer: { addr in try await node.connect(to: addr) }
/// )
/// ```
public final class DCUtRService: ProtocolService, EventEmitting, Sendable {

    // MARK: - ProtocolService

    public var protocolIDs: [String] {
        [DCUtRProtocol.protocolID]
    }

    // MARK: - Properties

    /// Service configuration.
    public let configuration: DCUtRConfiguration

    /// Event state (dedicated).
    private let eventState: Mutex<EventState>

    private struct EventState: Sendable {
        var stream: AsyncStream<DCUtREvent>?
        var continuation: AsyncStream<DCUtREvent>.Continuation?
    }

    /// Service state (separated).
    private let serviceState: Mutex<ServiceState>

    private struct ServiceState: Sendable {
        var pendingUpgrades: [PeerID: UpgradeAttempt] = [:]
    }

    private struct UpgradeAttempt: Sendable {
        let peer: PeerID
        let observedAddresses: [Multiaddr]
        let startTime: ContinuousClock.Instant
        var attemptCount: Int
    }

    // MARK: - Events

    /// Stream of DCUtR events.
    public var events: AsyncStream<DCUtREvent> {
        eventState.withLock { state in
            if let existing = state.stream { return existing }
            let (stream, continuation) = AsyncStream<DCUtREvent>.makeStream()
            state.stream = stream
            state.continuation = continuation
            return stream
        }
    }

    // MARK: - Initialization

    /// Creates a new DCUtR service.
    ///
    /// - Parameter configuration: Service configuration.
    public init(configuration: DCUtRConfiguration = .init()) {
        self.configuration = configuration
        self.eventState = Mutex(EventState())
        self.serviceState = Mutex(ServiceState())
    }

    // MARK: - Handler Registration

    /// Registers the DCUtR protocol handler.
    ///
    /// - Parameter registry: The handler registry to register with.
    public func registerHandler(registry: any HandlerRegistry) async {
        await registry.handle(DCUtRProtocol.protocolID) { [weak self] context in
            await self?.handleDCUtR(context: context)
        }
    }

    // MARK: - Public API

    /// Initiates a direct connection upgrade with a peer connected via relay.
    ///
    /// This method:
    /// 1. Opens a DCUtR stream over the relayed connection
    /// 2. Exchanges addresses with the remote peer
    /// 3. Coordinates timing for simultaneous dial (hole punching)
    /// 4. Attempts to establish a direct connection
    ///
    /// Retries up to `maxAttempts` times if hole punching fails.
    ///
    /// - Parameters:
    ///   - peer: The peer to upgrade connection with.
    ///   - opener: Stream opener for opening the DCUtR negotiation stream.
    ///   - dialer: Function to dial addresses directly.
    /// - Throws: `DCUtRError.maxAttemptsExceeded` if all attempts fail.
    public func upgradeToDirectConnection(
        with peer: PeerID,
        using opener: any StreamOpener,
        dialer: @escaping @Sendable (Multiaddr) async throws -> Void
    ) async throws {
        var lastError: Error = DCUtRError.allDialsFailed

        for attempt in 1...configuration.maxAttempts {
            do {
                try await performSingleUpgradeAttempt(
                    with: peer,
                    attempt: attempt,
                    using: opener,
                    dialer: dialer
                )
                // Success - return
                return
            } catch {
                lastError = error
                emit(.holePunchAttemptFailed(
                    peer: peer,
                    attempt: attempt,
                    maxAttempts: configuration.maxAttempts,
                    reason: error.localizedDescription
                ))

                // Fatal errors - rethrow immediately without wrapping
                if case DCUtRError.noAddresses = error {
                    throw error
                }
                if case DCUtRError.protocolViolation = error {
                    throw error
                }

                // Wait before retry (exponential backoff)
                if attempt < configuration.maxAttempts {
                    let backoff = Duration.seconds(Double(1 << (attempt - 1)))
                    try? await Task.sleep(for: backoff)
                }
            }
        }

        emit(.holePunchFailed(peer: peer, reason: "Max attempts exceeded (\(configuration.maxAttempts))"))
        throw DCUtRError.maxAttemptsExceeded(lastError)
    }

    /// Performs a single upgrade attempt.
    private func performSingleUpgradeAttempt(
        with peer: PeerID,
        attempt: Int,
        using opener: any StreamOpener,
        dialer: @escaping @Sendable (Multiaddr) async throws -> Void
    ) async throws {
        emit(.holePunchAttemptStarted(peer: peer, attempt: attempt))

        // Open DCUtR stream over relayed connection
        let stream = try await opener.newStream(to: peer, protocol: DCUtRProtocol.protocolID)

        do {
            // Get our local addresses
            let ourAddresses = configuration.getLocalAddresses()

            // Measure RTT during CONNECT exchange
            let rttStart = ContinuousClock.now

            // Send CONNECT with our observed addresses
            let connectMsg = DCUtRMessage.connect(addresses: ourAddresses)
            try await writeMessage(DCUtRProtobuf.encode(connectMsg), to: stream)

            // Receive CONNECT response with their observed addresses
            let responseData = try await readMessage(from: stream)
            let response = try DCUtRProtobuf.decode(responseData)

            // RTT is the time from sending CONNECT to receiving response
            let estimatedRTT = ContinuousClock.now - rttStart

            guard response.type == .connect else {
                throw DCUtRError.protocolViolation("Expected CONNECT response")
            }

            let theirAddresses = response.observedAddresses
            emit(.addressExchangeCompleted(peer: peer, theirAddresses: theirAddresses))

            if theirAddresses.isEmpty {
                throw DCUtRError.noAddresses
            }

            // Send SYNC to coordinate timing
            let syncMsg = DCUtRMessage.sync()
            try await writeMessage(DCUtRProtobuf.encode(syncMsg), to: stream)

            // Wait RTT/2 before dialing so both sides start at approximately the same time
            try await Task.sleep(for: estimatedRTT / 2)

            // Close the DCUtR stream - we're done with negotiation
            try await stream.close()

            // Attempt to dial addresses in parallel for better hole punch success rate
            if let successAddress = await dialParallel(addresses: theirAddresses, dialer: dialer) {
                emit(.directConnectionEstablished(peer: peer, address: successAddress))
                return
            }

            // All dials failed
            emit(.holePunchFailed(peer: peer, reason: "All addresses failed"))
            throw DCUtRError.allDialsFailed

        } catch {
            try? await stream.close()
            if let dcutrError = error as? DCUtRError {
                throw dcutrError
            }
            emit(.holePunchFailed(peer: peer, reason: error.localizedDescription))
            throw DCUtRError.holePunchFailed(error.localizedDescription)
        }
    }

    // MARK: - Protocol Handler

    /// Handles incoming DCUtR requests.
    private func handleDCUtR(context: StreamContext) async {
        let stream = context.stream
        let peer = context.remotePeer

        do {
            // Read CONNECT message
            let connectData = try await readMessage(from: stream)
            let connect = try DCUtRProtobuf.decode(connectData)

            guard connect.type == .connect else {
                throw DCUtRError.protocolViolation("Expected CONNECT")
            }

            let theirAddresses = connect.observedAddresses

            // Get our local addresses
            let ourAddresses = configuration.getLocalAddresses()

            // Send our CONNECT response
            let response = DCUtRMessage.connect(addresses: ourAddresses)
            try await writeMessage(DCUtRProtobuf.encode(response), to: stream)

            emit(.addressExchangeCompleted(peer: peer, theirAddresses: theirAddresses))

            // Wait for SYNC
            let syncData = try await readMessage(from: stream)
            let sync = try DCUtRProtobuf.decode(syncData)

            guard sync.type == .sync else {
                throw DCUtRError.protocolViolation("Expected SYNC")
            }

            // SYNC received - start dialing on our end
            emit(.holePunchAttemptStarted(peer: peer))

            // Close the stream - negotiation complete
            try await stream.close()

            // Attempt to dial the initiator's addresses in parallel
            // This is the responder side of hole punching
            if let dialer = configuration.dialer, !theirAddresses.isEmpty {
                if let successAddress = await dialParallel(addresses: theirAddresses, dialer: dialer) {
                    emit(.directConnectionEstablished(peer: peer, address: successAddress))
                    return
                }
                // All dials failed - this is not necessarily an error on responder side
                // as the initiator may have succeeded from their end
                emit(.holePunchFailed(peer: peer, reason: "All dial attempts failed"))
            }

        } catch {
            emit(.holePunchFailed(peer: peer, reason: error.localizedDescription))
            try? await stream.close()
        }
    }

    // MARK: - Message I/O

    private func readMessage(from stream: MuxedStream) async throws -> Data {
        // Apply timeout to prevent indefinite blocking on malicious/stalled peers
        return try await withTimeout(configuration.timeout) {
            do {
                return try await stream.readLengthPrefixedMessage(maxSize: UInt64(DCUtRProtocol.maxMessageSize))
            } catch let error as StreamMessageError {
                switch error {
                case .streamClosed, .emptyMessage:
                    throw DCUtRError.protocolViolation("Stream closed")
                case .messageTooLarge:
                    throw DCUtRError.protocolViolation("Message too large")
                }
            }
        }
    }

    /// Executes an async operation with a timeout.
    private func withTimeout<T: Sendable>(
        _ duration: Duration,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }

            group.addTask {
                try await Task.sleep(for: duration)
                throw DCUtRError.timeout
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func writeMessage(_ data: Data, to stream: MuxedStream) async throws {
        // Apply timeout to prevent indefinite blocking
        try await withTimeout(configuration.timeout) {
            try await stream.writeLengthPrefixedMessage(data)
        }
    }

    // MARK: - Parallel Dialing

    /// Dials multiple addresses in parallel, returning the first successful address.
    ///
    /// - Parameters:
    ///   - addresses: The addresses to dial.
    ///   - dialer: The dialer function.
    /// - Returns: The first successfully connected address, or nil if all failed.
    private func dialParallel(
        addresses: [Multiaddr],
        dialer: @escaping @Sendable (Multiaddr) async throws -> Void
    ) async -> Multiaddr? {
        let timeout = configuration.timeout

        return await withTaskGroup(of: Multiaddr?.self) { group in
            for address in addresses {
                group.addTask {
                    do {
                        // Apply timeout to each dial attempt to prevent stalling
                        try await withThrowingTaskGroup(of: Void.self) { innerGroup in
                            innerGroup.addTask {
                                try await dialer(address)
                            }
                            innerGroup.addTask {
                                try await Task.sleep(for: timeout)
                                throw DCUtRError.timeout
                            }
                            _ = try await innerGroup.next()!
                            innerGroup.cancelAll()
                        }
                        return address
                    } catch {
                        return nil
                    }
                }
            }

            // Return the first successful result
            for await result in group {
                if let address = result {
                    group.cancelAll()  // Cancel remaining dial attempts
                    return address
                }
            }
            return nil
        }
    }

    // MARK: - Shutdown

    /// Shuts down the service and finishes the event stream.
    ///
    /// Call this method when the service is no longer needed to properly
    /// terminate any consumers waiting on the `events` stream.
    public func shutdown() {
        eventState.withLock { state in
            state.continuation?.finish()
            state.continuation = nil
            state.stream = nil
        }
    }

    // MARK: - Event Emission

    private func emit(_ event: DCUtREvent) {
        _ = eventState.withLock { state in
            state.continuation?.yield(event)
        }
    }
}
