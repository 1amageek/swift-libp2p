/// PingService - Ping protocol implementation
import Foundation
import P2PCore
import P2PMux
import P2PProtocols
import Synchronization

/// Logger for PingService operations.
private let logger = Logger(label: "p2p.ping")

/// Ping payload size (must be 32 bytes per libp2p spec).
private let pingPayloadSize = 32

// MARK: - PingStreamReader

/// A buffered reader for ping streams that reads exactly N bytes.
///
/// MuxedStream.read() may return more than requested if multiple pings arrive,
/// so we need to buffer and extract exactly 32 bytes at a time.
private final class PingStreamReader: Sendable {
    private let stream: MuxedStream
    private let buffer: Mutex<Data>

    init(stream: MuxedStream) {
        self.stream = stream
        self.buffer = Mutex(Data())
    }

    /// Reads exactly `count` bytes from the stream.
    ///
    /// - Parameter count: Number of bytes to read
    /// - Returns: Exactly `count` bytes of data
    /// - Throws: PingError if stream closes before enough data is available
    func readExact(_ count: Int) async throws -> Data {
        while true {
            // Check if we have enough data in buffer
            let extracted: Data? = buffer.withLock { buf in
                if buf.count >= count {
                    let data = Data(buf.prefix(count))
                    buf = Data(buf.dropFirst(count))
                    return data
                }
                return nil
            }

            if let data = extracted {
                return data
            }

            // Need more data
            let chunk = try await stream.read()
            if chunk.readableBytes == 0 {
                throw PingError.streamError("Stream closed before receiving complete ping response")
            }

            buffer.withLock { $0.append(Data(buffer: chunk)) }
        }
    }
}

/// Configuration for PingService.
public struct PingConfiguration: Sendable {
    /// Timeout for ping responses.
    public var timeout: Duration

    public init(timeout: Duration = .seconds(30)) {
        self.timeout = timeout
    }
}

/// Service for the Ping protocol.
///
/// Provides connection liveness checking and RTT measurement.
///
/// ## Usage
///
/// ```swift
/// let pingService = PingService()
///
/// // Register handler with node
/// await pingService.registerHandler(registry: node)
///
/// // Ping a peer
/// let result = try await pingService.ping(remotePeer, using: node)
/// print("RTT: \(result.rtt)")
/// ```
public final class PingService: ProtocolService, EventEmitting, Sendable {

    // MARK: - ProtocolService

    public var protocolIDs: [String] {
        [LibP2PProtocol.ping]
    }

    // MARK: - Properties

    /// Configuration for this service.
    public let configuration: PingConfiguration

    /// Event stream state.
    private let eventState: Mutex<EventState>

    private struct EventState: Sendable {
        var continuation: AsyncStream<PingEvent>.Continuation?
        var stream: AsyncStream<PingEvent>?
    }

    /// Event stream for monitoring ping events.
    public var events: AsyncStream<PingEvent> {
        eventState.withLock { state in
            if let existing = state.stream {
                return existing
            }
            let (stream, continuation) = AsyncStream<PingEvent>.makeStream()
            state.stream = stream
            state.continuation = continuation
            return stream
        }
    }

    // MARK: - Initialization

    public init(configuration: PingConfiguration = .init()) {
        self.configuration = configuration
        self.eventState = Mutex(EventState())
    }

    // MARK: - Handler Registration

    /// Registers the ping protocol handler.
    ///
    /// - Parameter registry: The handler registry to register with
    public func registerHandler(registry: any HandlerRegistry) async {
        await registry.handle(LibP2PProtocol.ping) { [weak self] context in
            await self?.handlePing(context: context)
        }
    }

    // MARK: - Public API

    /// Pings a peer and measures RTT.
    ///
    /// - Parameters:
    ///   - peer: The peer to ping
    ///   - opener: The stream opener to use
    /// - Returns: The ping result with RTT
    @discardableResult
    public func ping(_ peer: PeerID, using opener: any StreamOpener) async throws -> PingResult {
        // Generate random payload
        var payload = Data(count: pingPayloadSize)
        for i in 0..<pingPayloadSize {
            payload[i] = UInt8.random(in: 0...255)
        }

        // Open ping stream
        let stream: MuxedStream
        do {
            stream = try await opener.newStream(to: peer, protocol: LibP2PProtocol.ping)
        } catch {
            let pingError = PingError.unsupported
            emit(.failure(peer: peer, error: pingError))
            throw pingError
        }

        defer {
            Task {
                do {
                    try await stream.close()
                } catch {
                    logger.debug("Failed to close ping stream: \(error)")
                }
            }
        }

        do {
            // Record start time
            let startTime = ContinuousClock.now

            // Send payload
            try await stream.write(ByteBuffer(bytes: payload))

            // Create buffered reader for exact byte reading
            let reader = PingStreamReader(stream: stream)

            // Read response with timeout - exactly 32 bytes
            let response = try await withThrowingTaskGroup(of: Data.self) { group in
                group.addTask {
                    try await reader.readExact(pingPayloadSize)
                }

                group.addTask {
                    try await Task.sleep(for: self.configuration.timeout)
                    throw PingError.timeout
                }

                let result = try await group.next()!
                group.cancelAll()
                return result
            }

            // Calculate RTT
            let endTime = ContinuousClock.now
            let rtt = endTime - startTime

            // Verify response matches payload
            guard response == payload else {
                let error = PingError.mismatch
                emit(.failure(peer: peer, error: error))
                throw error
            }

            let result = PingResult(peer: peer, rtt: rtt)
            emit(.success(result))

            return result
        } catch let error as PingError {
            emit(.failure(peer: peer, error: error))
            throw error
        } catch {
            let pingError = PingError.streamError("\(error)")
            emit(.failure(peer: peer, error: pingError))
            throw pingError
        }
    }

    /// Pings a peer multiple times and returns statistics.
    ///
    /// - Parameters:
    ///   - peer: The peer to ping
    ///   - opener: The stream opener to use
    ///   - count: Number of pings to send
    ///   - interval: Interval between pings
    /// - Returns: Array of ping results (only successful pings)
    public func pingMultiple(
        _ peer: PeerID,
        using opener: any StreamOpener,
        count: Int = 3,
        interval: Duration = .milliseconds(100)
    ) async throws -> [PingResult] {
        var results: [PingResult] = []

        for i in 0..<count {
            if i > 0 {
                try await Task.sleep(for: interval)
            }

            do {
                let result = try await ping(peer, using: opener)
                results.append(result)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                emit(.failure(peer: peer, error: error as? PingError ?? .streamError("\(error)")))
            }
        }

        return results
    }

    /// Calculates statistics from ping results.
    ///
    /// - Parameter results: The ping results
    /// - Returns: Tuple of (min, max, average) RTT, or nil if no results
    public static func statistics(from results: [PingResult]) -> (min: Duration, max: Duration, avg: Duration)? {
        guard !results.isEmpty else { return nil }

        let rtts = results.map { $0.rtt }
        let minRTT = rtts.min()!
        let maxRTT = rtts.max()!

        // Calculate average
        var totalNanoseconds: Int64 = 0
        for rtt in rtts {
            totalNanoseconds += Int64(rtt.components.seconds) * 1_000_000_000
            totalNanoseconds += Int64(rtt.components.attoseconds / 1_000_000_000)
        }
        let avgNanoseconds = totalNanoseconds / Int64(rtts.count)
        let avgRTT = Duration.nanoseconds(avgNanoseconds)

        return (minRTT, maxRTT, avgRTT)
    }

    // MARK: - Protocol Handler

    /// Handles an incoming ping request (echo back).
    private func handlePing(context: StreamContext) async {
        let stream = context.stream
        let reader = PingStreamReader(stream: stream)

        do {
            // Read and echo back pings until stream closes
            while true {
                // Read exactly 32 bytes
                let payload = try await reader.readExact(pingPayloadSize)

                // Echo back
                try await stream.write(ByteBuffer(bytes: payload))
            }
        } catch {
            // Stream closed or error - normal termination
        }

        do {
            try await stream.close()
        } catch {
            logger.debug("Failed to close ping handler stream: \(error)")
        }
    }

    private func emit(_ event: PingEvent) {
        _ = eventState.withLock { state in
            state.continuation?.yield(event)
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
}
