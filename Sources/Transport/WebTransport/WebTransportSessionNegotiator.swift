import Foundation
import QUIC

/// Session negotiation over QUIC streams for WebTransport connections.
///
/// This provides explicit session establishment semantics at the transport layer
/// until full HTTP/3 Extended CONNECT support is available in the underlying stack.
enum WebTransportSessionNegotiator {

    private static let helloPayload = Data("swift-libp2p-webtransport/1".utf8)
    private static let ackPayload = Data("ok".utf8)
    private static let maxFrameSize = 4096

    static func performClientNegotiation(
        on connection: any QUICConnectionProtocol,
        timeout: Duration
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                let stream = try await connection.openStream()
                try await writeFrame(payload: helloPayload, to: stream)
                try await stream.closeWrite()

                let response = try await readFrame(from: stream, maxBytes: maxFrameSize)
                guard response == ackPayload else {
                    throw WebTransportError.connectionFailed("Invalid session negotiation response")
                }
            }

            group.addTask {
                try await Task.sleep(for: timeout)
                throw WebTransportError.timeout
            }

            _ = try await group.next()
            group.cancelAll()
        }
    }

    static func performServerNegotiation(
        on connection: any QUICConnectionProtocol,
        timeout: Duration
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                guard let stream = await firstIncomingStream(from: connection) else {
                    throw WebTransportError.connectionFailed("No inbound stream for session negotiation")
                }

                let request = try await readFrame(from: stream, maxBytes: maxFrameSize)
                guard request == helloPayload else {
                    throw WebTransportError.connectionFailed("Invalid session negotiation request")
                }

                try await writeFrame(payload: ackPayload, to: stream)
                try await stream.closeWrite()
            }

            group.addTask {
                try await Task.sleep(for: timeout)
                throw WebTransportError.timeout
            }

            _ = try await group.next()
            group.cancelAll()
        }
    }

    private static func firstIncomingStream(
        from connection: any QUICConnectionProtocol
    ) async -> (any QUICStreamProtocol)? {
        var iterator = connection.incomingStreams.makeAsyncIterator()
        return await iterator.next()
    }

    private static func writeFrame(
        payload: Data,
        to stream: any QUICStreamProtocol
    ) async throws {
        guard payload.count <= Int(UInt16.max) else {
            throw WebTransportError.connectionFailed("Negotiation payload too large")
        }

        var frame = Data(capacity: 2 + payload.count)
        let length = UInt16(payload.count).bigEndian
        withUnsafeBytes(of: length) { frame.append(contentsOf: $0) }
        frame.append(payload)
        try await stream.write(frame)
    }

    private static func readFrame(
        from stream: any QUICStreamProtocol,
        maxBytes: Int
    ) async throws -> Data {
        var buffer = Data()

        while buffer.count < 2 {
            let chunk = try await stream.read()
            if chunk.isEmpty {
                throw WebTransportError.connectionFailed("Unexpected end of stream during negotiation")
            }
            buffer.append(chunk)
        }

        let length = (Int(buffer[0]) << 8) | Int(buffer[1])

        guard length <= maxBytes else {
            throw WebTransportError.connectionFailed("Negotiation frame exceeds size limit")
        }

        let required = 2 + length
        while buffer.count < required {
            let chunk = try await stream.read()
            if chunk.isEmpty {
                throw WebTransportError.connectionFailed("Unexpected end of stream during negotiation")
            }
            buffer.append(chunk)
        }

        return Data(buffer[2..<required])
    }
}
