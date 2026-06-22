/// HTTPService - HTTP protocol service for libp2p.
///
/// Provides HTTP/1.1 request/response semantics over libp2p streams.
/// Supports both server-side route handling and client-side request sending.

import Foundation
import Synchronization
import P2PCore
import P2PMux
import P2PProtocols

/// Logger for HTTP operations.
private let logger = Logger(label: "p2p.http")

/// Configuration for HTTPService.
public struct HTTPConfiguration: Sendable {
    /// Timeout for HTTP operations.
    public var timeout: Duration

    /// Creates a new HTTP configuration.
    ///
    /// - Parameter timeout: Timeout for operations (default: 30 seconds)
    public init(timeout: Duration = .seconds(30)) {
        self.timeout = timeout
    }
}

/// Service for the HTTP protocol over libp2p streams.
///
/// HTTPService enables HTTP/1.1 request/response semantics over multiplexed
/// libp2p streams. It supports:
/// - Server-side route registration with method and path matching
/// - Client-side request sending to remote peers
/// - Event emission for monitoring request/response lifecycle
///
/// ## Usage
///
/// ```swift
/// let httpService = HTTPService()
///
/// // Register a route
/// httpService.route(method: .get, path: "/hello") { request in
///     return .ok(body: Array("Hello, World!".utf8))
/// }
///
/// // Send a request to a peer
/// let response = try await httpService.request(
///     HTTPRequest(method: .get, path: "/hello"),
///     to: remotePeer,
///     using: node
/// )
/// ```
public final class HTTPService: EventEmitting, Sendable {

    // MARK: - Event

    /// Events emitted by HTTPService.
    public enum Event: Sendable {
        /// A request was received from a peer.
        case requestReceived(PeerID, HTTPRequest)

        /// A response was sent to a peer.
        case responseSent(PeerID, Int)

        /// An error occurred during HTTP processing.
        case error(PeerID?, HTTPError)
    }

    // MARK: - Handler Type

    /// A handler that processes an HTTP request and returns a response.
    public typealias Handler = @Sendable (HTTPRequest) async throws -> HTTPResponse

    // MARK: - Route

    /// A registered route with method, path, and handler.
    private struct Route: Sendable {
        let method: HTTPMethod?
        let path: String
        let handler: Handler
    }

    // MARK: - StreamService

    public var protocolIDs: [String] {
        [HTTPProtocol.protocolID]
    }

    // MARK: - Properties

    /// Configuration for this service.
    public let configuration: HTTPConfiguration

    /// Event channel.
    private let channel = EventChannel<Event>()

    /// Registered routes.
    private let routeState: Mutex<[Route]>

    // MARK: - EventEmitting

    /// Event stream for monitoring HTTP events.
    public var events: AsyncStream<Event> { channel.stream }

    // MARK: - Initialization

    /// Creates a new HTTP service.
    ///
    /// - Parameter configuration: Service configuration
    public init(configuration: HTTPConfiguration = .init()) {
        self.configuration = configuration
        self.routeState = Mutex([])
    }

    // MARK: - Route Registration

    /// Registers a route handler for a specific HTTP method and path.
    ///
    /// - Parameters:
    ///   - method: The HTTP method to match
    ///   - path: The path to match
    ///   - handler: The handler to invoke when a matching request is received
    public func route(method: HTTPMethod, path: String, handler: @escaping Handler) {
        routeState.withLock { routes in
            routes.append(Route(method: method, path: path, handler: handler))
        }
    }

    /// Registers a route handler for any HTTP method on a given path.
    ///
    /// - Parameters:
    ///   - path: The path to match
    ///   - handler: The handler to invoke when a matching request is received
    public func route(path: String, handler: @escaping Handler) {
        routeState.withLock { routes in
            routes.append(Route(method: nil, path: path, handler: handler))
        }
    }

    // MARK: - Client API

    /// Sends an HTTP request to a remote peer and returns the response.
    ///
    /// - Parameters:
    ///   - request: The HTTP request to send
    ///   - peer: The remote peer to send the request to
    ///   - opener: The stream opener for creating new streams
    /// - Returns: The HTTP response from the peer
    /// - Throws: `HTTPError` if the operation fails
    public func request(
        _ request: HTTPRequest,
        to peer: PeerID,
        using opener: any StreamOpener
    ) async throws -> HTTPResponse {
        let stream: MuxedStream
        do {
            stream = try await opener.newStream(to: peer, protocol: HTTPProtocol.protocolID)
        } catch {
            let httpError = HTTPError.connectionFailed("\(error)")
            emit(.error(peer, httpError))
            throw httpError
        }

        defer {
            Task {
                do {
                    try await stream.close()
                } catch {
                    logger.debug("Failed to close HTTP stream: \(error)")
                }
            }
        }

        do {
            // Encode and send request
            let encoded = HTTPCodec.encodeRequestBuffer(request)
            try await stream.write(encoded)

            // Read response with timeout
            let response = try await withThrowingTaskGroup(of: HTTPResponse.self) { group in
                group.addTask {
                    try await self.readResponse(from: stream)
                }

                group.addTask {
                    try await Task.sleep(for: self.configuration.timeout)
                    throw HTTPError.timeout
                }

                let result = try await group.next()!
                group.cancelAll()
                return result
            }

            return response
        } catch let error as HTTPError {
            emit(.error(peer, error))
            throw error
        } catch {
            let httpError = HTTPError.streamClosed
            emit(.error(peer, httpError))
            throw httpError
        }
    }

    // MARK: - Incoming Handler

    /// Handles an incoming HTTP request on a stream.
    private func handleIncoming(context: StreamContext) async {
        let stream = context.stream
        let remotePeer = context.remotePeer

        do {
            // Read the request
            let request = try await readRequest(from: stream)

            // Emit event
            emit(.requestReceived(remotePeer, request))

            // Find matching route
            let handler = findRoute(for: request)

            let response: HTTPResponse
            if let handler = handler {
                do {
                    response = try await handler(request)
                } catch {
                    let httpError = HTTPError.handlerError("\(error)")
                    emit(.error(remotePeer, httpError))
                    response = .internalServerError()
                }
            } else {
                response = .notFound()
            }

            // Encode and send response
            let encoded = HTTPCodec.encodeResponseBuffer(response)
            try await stream.write(encoded)

            emit(.responseSent(remotePeer, response.statusCode))
        } catch let error as HTTPError {
            emit(.error(remotePeer, error))
        } catch {
            emit(.error(remotePeer, .streamClosed))
        }

        do {
            try await stream.close()
        } catch {
            logger.debug("Failed to close HTTP handler stream: \(error)")
        }
    }

    // MARK: - Route Matching

    /// Finds a matching route for the given request.
    ///
    /// - Parameter request: The request to match
    /// - Returns: The handler for the matching route, or nil if no route matches
    private func findRoute(for request: HTTPRequest) -> Handler? {
        let routes = routeState.withLock { $0 }

        // First try exact method + path match
        for route in routes {
            if let routeMethod = route.method {
                if routeMethod == request.method && route.path == request.path {
                    return route.handler
                }
            }
        }

        // Then try wildcard method (any method) + path match
        for route in routes {
            if route.method == nil && route.path == request.path {
                return route.handler
            }
        }

        return nil
    }

    // MARK: - Stream Reading

    /// Reads an HTTP request from a muxed stream.
    ///
    /// - Parameter stream: The stream to read from
    /// - Returns: The decoded HTTP request
    /// - Throws: `HTTPError` if reading or decoding fails
    private func readRequest(from stream: MuxedStream) async throws -> HTTPRequest {
        let data = try await readHTTPMessage(from: stream)
        return try HTTPCodec.decodeRequest(from: data)
    }

    /// Reads an HTTP response from a muxed stream.
    ///
    /// - Parameter stream: The stream to read from
    /// - Returns: The decoded HTTP response
    /// - Throws: `HTTPError` if reading or decoding fails
    private func readResponse(from stream: MuxedStream) async throws -> HTTPResponse {
        let data = try await readHTTPMessage(from: stream)
        return try HTTPCodec.decodeResponse(from: data)
    }

    /// Reads a complete HTTP message (headers + body) from a stream.
    ///
    /// Accumulates data until the header/body separator (\r\n\r\n) is found,
    /// then reads the body based on Content-Length if present.
    ///
    /// - Parameter stream: The stream to read from
    /// - Returns: The complete message bytes
    /// - Throws: `HTTPError` if the stream closes prematurely or limits are exceeded
    private func readHTTPMessage(from stream: MuxedStream) async throws -> ByteBuffer {
        var buffer = ByteBuffer()

        // Read until we find the header/body separator
        while true {
            var chunk = try await stream.read()
            if chunk.readableBytes == 0 {
                throw HTTPError.streamClosed
            }

            buffer.writeBuffer(&chunk)

            // Check for header size limit during accumulation
            if buffer.readableBytes > HTTPProtocol.maxHeaderSize + HTTPProtocol.maxBodySize {
                throw HTTPError.bodyTooLarge(buffer.readableBytes)
            }

            // Check if we have the complete headers
            if let headerEnd = findDoubleCrlf(in: buffer) {
                let bodyStart = headerEnd + 4  // After \r\n\r\n

                // Reject framing we cannot honor (e.g. chunked transfer-encoding).
                try validateTransferEncoding(from: buffer, headerEnd: headerEnd)

                // Parse and strictly validate Content-Length.
                let contentLength = try parseContentLength(from: buffer, headerEnd: headerEnd)

                if let contentLength = contentLength {
                    // Overflow-checked total. bodyStart and contentLength are both
                    // already validated as non-negative and bounded.
                    let (totalExpected, overflow) = bodyStart.addingReportingOverflow(contentLength)
                    if overflow {
                        throw HTTPError.invalidContentLength("Content-Length + header size overflows")
                    }

                    // Read until we have the full body.
                    while buffer.readableBytes < totalExpected {
                        var moreData = try await stream.read()
                        if moreData.readableBytes == 0 {
                            throw HTTPError.streamClosed
                        }
                        buffer.writeBuffer(&moreData)
                    }

                    // If there are MORE bytes than the framed message, the extra
                    // bytes are unframed and must be treated as an error rather
                    // than silently dropped.
                    if buffer.readableBytes > totalExpected {
                        throw HTTPError.malformedMessage("Unexpected bytes after Content-Length body")
                    }

                    // Return exactly the expected amount.
                    guard let message = buffer.readSlice(length: totalExpected) else {
                        throw HTTPError.streamClosed
                    }
                    return message
                } else {
                    // No Content-Length: a body cannot be framed. Any bytes beyond
                    // the headers are unframed and must not be silently dropped.
                    if buffer.readableBytes > bodyStart {
                        throw HTTPError.malformedMessage("Body present without Content-Length")
                    }
                    return buffer
                }
            }
        }
    }

    /// Rejects framing the parser cannot honor.
    ///
    /// `Transfer-Encoding: chunked` is not supported; any Transfer-Encoding
    /// header is rejected explicitly rather than ignored (ignoring it would
    /// leave the body unframed / enable request smuggling).
    private func validateTransferEncoding(from data: ByteBuffer, headerEnd: Int) throws {
        var headerBuffer = data
        headerBuffer.moveWriterIndex(to: headerBuffer.readerIndex + headerEnd)
        let headerString = String(decoding: headerBuffer.readableBytesView, as: UTF8.self)
        for line in headerString.components(separatedBy: "\r\n") {
            if line.lowercased().hasPrefix("transfer-encoding:") {
                let value = line.dropFirst("transfer-encoding:".count).trimmingCharacters(in: .whitespaces)
                throw HTTPError.unsupportedFraming("Transfer-Encoding not supported: \(value)")
            }
        }
    }

    /// Finds the index of the first \r\n\r\n in the buffer.
    private func findDoubleCrlf(in data: ByteBuffer) -> Int? {
        let bytes = data.readableBytesView
        guard bytes.count >= 4 else { return nil }
        let lastStart = bytes.count - 4
        for i in 0...lastStart {
            let index0 = bytes.index(bytes.startIndex, offsetBy: i)
            let index1 = bytes.index(after: index0)
            let index2 = bytes.index(after: index1)
            let index3 = bytes.index(after: index2)
            if bytes[index0] == 0x0D && bytes[index1] == 0x0A &&
               bytes[index2] == 0x0D && bytes[index3] == 0x0A {
                return i
            }
        }
        return nil
    }

    /// Parses and strictly validates the Content-Length header.
    ///
    /// - Returns: the validated non-negative length, or `nil` if no
    ///   Content-Length header is present.
    /// - Throws: `HTTPError.invalidContentLength` if the value is non-numeric,
    ///   negative, overflows `Int`, exceeds `maxBodySize`, or if multiple
    ///   conflicting Content-Length headers are present.
    private func parseContentLength(from data: ByteBuffer, headerEnd: Int) throws -> Int? {
        var headerBuffer = data
        headerBuffer.moveWriterIndex(to: headerBuffer.readerIndex + headerEnd)
        let headerString = String(decoding: headerBuffer.readableBytesView, as: UTF8.self)

        var found: Int? = nil
        for line in headerString.components(separatedBy: "\r\n") {
            let lower = line.lowercased()
            guard lower.hasPrefix("content-length:") else { continue }

            let valueString = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)

            // Must be a non-empty run of ASCII digits only. This rejects
            // negatives ("-1"), "+1", whitespace-embedded, hex, and overflow
            // (Int(...) returns nil on overflow).
            guard !valueString.isEmpty, valueString.allSatisfy({ $0.isNumber }) else {
                throw HTTPError.invalidContentLength("Non-numeric Content-Length: \(valueString)")
            }
            guard let value = Int(valueString) else {
                throw HTTPError.invalidContentLength("Content-Length out of range: \(valueString)")
            }
            guard value >= 0 else {
                throw HTTPError.invalidContentLength("Negative Content-Length: \(value)")
            }
            guard value <= HTTPProtocol.maxBodySize else {
                throw HTTPError.invalidContentLength(
                    "Content-Length \(value) exceeds maximum \(HTTPProtocol.maxBodySize)"
                )
            }

            // Duplicate headers must agree; conflicting values are rejected.
            if let existing = found, existing != value {
                throw HTTPError.invalidContentLength("Conflicting Content-Length headers")
            }
            found = value
        }
        return found
    }

    // MARK: - Event Emission

    private func emit(_ event: Event) {
        channel.yield(event)
    }

    // MARK: - Shutdown

    /// Shuts down the service and finishes the event stream.
    public func shutdown() async throws {
        channel.finish()
    }
}

// MARK: - StreamService

extension HTTPService: LifecycleService, StreamService {
    public func handleInboundStream(_ context: StreamContext) async {
        await handleIncoming(context: context)
    }
}
