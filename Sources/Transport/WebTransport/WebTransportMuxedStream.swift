import NIOCore
import P2PMux

/// WebTransport stream wrapper over a generic muxed stream.
public final class WebTransportMuxedStream: MuxedStream, Sendable {

    private let base: any MuxedStream

    public init(base: any MuxedStream) {
        self.base = base
    }

    public var id: UInt64 {
        base.id
    }

    public var protocolID: String? {
        base.protocolID ?? WebTransportProtocol.protocolID
    }

    public func read() async throws -> ByteBuffer {
        try await base.read()
    }

    public func write(_ data: ByteBuffer) async throws {
        try await base.write(data)
    }

    public func closeWrite() async throws {
        try await base.closeWrite()
    }

    public func closeRead() async throws {
        try await base.closeRead()
    }

    public func close() async throws {
        try await base.close()
    }

    public func reset() async throws {
        try await base.reset()
    }
}
