/// PingService - Ping protocol implementation
import Foundation
import P2PCore
import P2PMux
import P2PProtocols
import Synchronization

/// Logger for PingService operations.
private let logger = Logger(label: "p2p.ping")

/// Ping payload size (must be 32 bytes per libp2p spec).
/// Sourced from the Embedded-clean ``PingCodec`` core.
private let pingPayloadSize = PingCodec.payloadSize

// MARK: - PingStreamReader

/// A buffered reader for ping streams that reads exactly N bytes.
///
/// MuxedStream.read() may return more than requested if multiple pings arrive,
/// so we need to buffer and extract exactly 32 bytes at a time.
private final class PingStreamReader: Sendable {
    private let stream: MuxedStream
    private let buffer: Mutex<ByteBuffer>
    /// Upper bound on the internal buffer, preventing an unbounded read buffer
    /// when a peer sends a large amount of data without a complete payload.
    private let maxBufferBytes: Int

    init(stream: MuxedStream, maxBufferBytes: Int = pingPayloadSize * 4) {
        self.stream = stream
        self.buffer = Mutex(ByteBuffer())
        self.maxBufferBytes = max(pingPayloadSize, maxBufferBytes)
    }

    /// Reads exactly `count` bytes from the stream.
    ///
    /// - Parameter count: Number of bytes to read
    /// - Returns: Exactly `count` bytes of data
    /// - Throws: PingError if stream closes before enough data is available, or
    ///   if the buffered data exceeds the configured maximum.
    func readExact(_ count: Int) async throws -> ByteBuffer {
        while true {
            let extracted: ByteBuffer? = buffer.withLock { buf in
                guard buf.readableBytes >= count else {
                    return nil
                }
                return buf.readSlice(length: count)
            }

            if let data = extracted {
                return data
            }

            // Need more data
            let chunk = try await stream.read()
            if chunk.readableBytes == 0 {
                throw PingError.streamError("Stream closed before receiving complete ping response")
            }

            let overflow: Bool = buffer.withLock { buf in
                var chunk = chunk
                buf.writeBuffer(&chunk)
                return buf.readableBytes > maxBufferBytes
            }
            if overflow {
                throw PingError.streamError("Ping read buffer exceeded maximum of \(maxBufferBytes) bytes")
            }
        }
    }
}

/// Configuration for PingService.
public struct PingConfiguration: Sendable {
    /// Timeout for ping responses (outbound).
    public var timeout: Duration

    /// Idle timeout for the inbound echo handler.
    ///
    /// If no complete ping payload is received within this window, the inbound
    /// handler closes the stream. Prevents a peer from holding an echo handler
    /// open indefinitely (reflection / handler exhaustion).
    public var inboundIdleTimeout: Duration

    /// Total lifetime cap for the inbound echo handler.
    ///
    /// Bounds the absolute time a single inbound ping stream may stay open.
    public var inboundTotalTimeout: Duration

    public init(
        timeout: Duration = .seconds(30),
        inboundIdleTimeout: Duration = .seconds(60),
        inboundTotalTimeout: Duration = .seconds(600)
    ) {
        self.timeout = timeout
        self.inboundIdleTimeout = inboundIdleTimeout
        self.inboundTotalTimeout = inboundTotalTimeout
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
/// // Ping a peer
/// let result = try await pingService.ping(remotePeer, using: node)
/// print("RTT: \(result.rtt)")
/// ```
public final class PingService: EventEmitting, Sendable {

    // MARK: - StreamService

    public var protocolIDs: [String] {
        [ProtocolID.ping]
    }

    // MARK: - Properties

    /// Configuration for this service.
    public let configuration: PingConfiguration

    /// Event channel for monitoring ping events.
    private let channel = EventChannel<PingEvent>()

    /// Event stream for monitoring ping events.
    public var events: AsyncStream<PingEvent> { channel.stream }

    // MARK: - Initialization

    public init(configuration: PingConfiguration = .init()) {
        self.configuration = configuration
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
        var payload = ByteBuffer()
        payload.reserveCapacity(pingPayloadSize)
        for _ in 0..<pingPayloadSize {
            payload.writeInteger(UInt8.random(in: 0...255))
        }

        // Open ping stream
        let stream: MuxedStream
        do {
            stream = try await opener.newStream(to: peer, protocol: ProtocolID.ping)
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
            try await stream.write(payload)

            // Create buffered reader for exact byte reading
            let reader = PingStreamReader(stream: stream)

            // Read response with timeout - exactly 32 bytes
            let response = try await withThrowingTaskGroup(of: ByteBuffer.self) { group in
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
            guard response.readableBytesView.elementsEqual(payload.readableBytesView) else {
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
    ///
    /// The handler is bounded by both an idle timeout (per ping payload) and a
    /// total lifetime cap so a peer cannot hold the echo handler open
    /// indefinitely or exhaust handler resources via a stalled stream.
    private func handlePing(context: StreamContext) async {
        let stream = context.stream
        let reader = PingStreamReader(stream: stream)
        let idleTimeout = configuration.inboundIdleTimeout
        let totalTimeout = configuration.inboundTotalTimeout
        let deadline = ContinuousClock.now + totalTimeout

        do {
            // Read and echo back pings until the stream closes or a limit fires.
            while true {
                // Enforce the total lifetime cap.
                if ContinuousClock.now >= deadline {
                    break
                }

                // Read exactly 32 bytes, racing against the idle timeout.
                let payload = try await withThrowingTaskGroup(of: ByteBuffer.self) { group in
                    group.addTask {
                        try await reader.readExact(pingPayloadSize)
                    }
                    group.addTask {
                        try await Task.sleep(for: idleTimeout)
                        throw PingError.timeout
                    }
                    let result = try await group.next()!
                    group.cancelAll()
                    return result
                }

                // Echo back
                try await stream.write(payload)
            }
        } catch {
            // Stream closed, idle timeout, or error - terminate the handler.
        }

        do {
            try await stream.close()
        } catch {
            logger.debug("Failed to close ping handler stream: \(error)")
        }
    }

    private func emit(_ event: PingEvent) {
        channel.yield(event)
    }

    // MARK: - Shutdown

    /// Shuts down the service and finishes the event stream.
    ///
    /// Call this method when the service is no longer needed to properly
    /// terminate any consumers waiting on the `events` stream.
    public func shutdown() async throws {
        channel.finish()
    }
}

// MARK: - StreamService

extension PingService: LifecycleService, StreamService {
    public func handleInboundStream(_ context: StreamContext) async {
        await handlePing(context: context)
    }
}
