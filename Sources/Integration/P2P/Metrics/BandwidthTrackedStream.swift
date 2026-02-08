/// BandwidthTrackedStream - MuxedStream wrapper that records bandwidth usage
///
/// Wraps a MuxedStream and reports bytes read/written to a BandwidthReporter.
/// Follows the same wrapper pattern as ResourceTrackedStream.

import P2PCore
import P2PMux

/// A MuxedStream wrapper that tracks bytes read and written.
///
/// Each `read()` records the number of readable bytes as inbound traffic.
/// Each `write()` records the number of readable bytes as outbound traffic.
/// Both are attributed to the configured peer and protocol.
internal final class BandwidthTrackedStream: MuxedStream, Sendable {

    private let underlying: MuxedStream
    private let reporter: BandwidthReporter
    private let peer: PeerID?
    private let trackedProtocolID: String?

    init(
        stream: MuxedStream,
        reporter: BandwidthReporter,
        peer: PeerID? = nil,
        protocolID: String? = nil
    ) {
        self.underlying = stream
        self.reporter = reporter
        self.peer = peer
        self.trackedProtocolID = protocolID ?? stream.protocolID
    }

    // MARK: - MuxedStream

    var id: UInt64 { underlying.id }
    var protocolID: String? { underlying.protocolID }

    func read() async throws -> ByteBuffer {
        let buffer = try await underlying.read()
        reporter.recordInbound(
            bytes: buffer.readableBytes,
            protocol: trackedProtocolID,
            peer: peer
        )
        return buffer
    }

    func write(_ data: ByteBuffer) async throws {
        reporter.recordOutbound(
            bytes: data.readableBytes,
            protocol: trackedProtocolID,
            peer: peer
        )
        try await underlying.write(data)
    }

    func closeWrite() async throws {
        try await underlying.closeWrite()
    }

    func closeRead() async throws {
        try await underlying.closeRead()
    }

    func close() async throws {
        try await underlying.close()
    }

    func reset() async throws {
        try await underlying.reset()
    }
}
