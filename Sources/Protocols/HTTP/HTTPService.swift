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

    /// Event stream state.
    private let eventState: Mutex<EventState>

    private struct EventState: Sendable {
        var continuation: AsyncStream<Event>.Continuation?
        var stream: AsyncStream<Event>?
    }

    /// Registered routes.
    private let routeState: Mutex<[Route]>

    // MARK: - EventEmitting

    /// Event stream for monitoring HTTP events.
    public var events: AsyncStream<Event> {
        eventState.withLock { state in
            if let existing = state.stream {
                return existing
            }
            let (stream, continuation) = AsyncStream<Event>.makeStream()
            state.stream = stream
            state.continuation = continuation
            return stream
        }
    }

    // MARK: - Initialization

    /// Creates a new HTTP service.
    ///
    /// - Parameter configuration: Service configuration
    public init(configuration: HTTPConfiguration = .init()) {
        self.configuration = configuration
        self.eventState = Mutex(EventState())
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
            let encoded = HTTPCodec.encodeRequest(request)
            try await stream.write(ByteBuffer(bytes: encoded))

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
            let encoded = HTTPCodec.encodeResponse(response)
            try await stream.write(ByteBuffer(bytes: encoded))

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
    private func readHTTPMessage(from stream: MuxedStream) async throws -> [UInt8] {
        var buffer: [UInt8] = []

        // Read until we find the header/body separator
        while true {
            let chunk = try await stream.read()
            if chunk.readableBytes == 0 {
                throw HTTPError.streamClosed
            }

            buffer.append(contentsOf: Data(buffer: chunk))

            // Check for header size limit during accumulation
            if buffer.count > HTTPProtocol.maxHeaderSize + HTTPProtocol.maxBodySize {
                throw HTTPError.bodyTooLarge(buffer.count)
            }

            // Check if we have the complete headers
            if let headerEnd = findDoubleCrlf(in: buffer) {
                // Parse Content-Length to determine body size
                let contentLength = parseContentLength(from: buffer, headerEnd: headerEnd)
                let bodyStart = headerEnd + 4  // After \r\n\r\n

                if let contentLength = contentLength {
                    // Read until we have the full body
                    let totalExpected = bodyStart + contentLength
                    while buffer.count < totalExpected {
                        let moreData = try await stream.read()
                        if moreData.readableBytes == 0 {
                            throw HTTPError.streamClosed
                        }
                        buffer.append(contentsOf: Data(buffer: moreData))
                    }
                    // Return exactly the expected amount
                    return Array(buffer[0..<totalExpected])
                } else {
                    // No Content-Length: return what we have (headers only, no body)
                    return buffer
                }
            }
        }
    }

    /// Finds the index of the first \r\n\r\n in the buffer.
    private func findDoubleCrlf(in data: [UInt8]) -> Int? {
        guard data.count >= 4 else { return nil }
        for i in 0...(data.count - 4) {
            if data[i] == 0x0D && data[i + 1] == 0x0A &&
               data[i + 2] == 0x0D && data[i + 3] == 0x0A {
                return i
            }
        }
        return nil
    }

    /// Parses the Content-Length header value from raw header bytes.
    private func parseContentLength(from data: [UInt8], headerEnd: Int) -> Int? {
        guard let headerString = String(bytes: data[0..<headerEnd], encoding: .utf8) else {
            return nil
        }

        let lines = headerString.components(separatedBy: "\r\n")
        for line in lines {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                let valueString = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                return Int(valueString)
            }
        }
        return nil
    }

    // MARK: - Event Emission

    private func emit(_ event: Event) {
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

// MARK: - StreamService

extension HTTPService: StreamService {
    public func handleInboundStream(_ context: StreamContext) async {
        await handleIncoming(context: context)
    }
    // shutdown(): already defined (sync func satisfies async requirement)
}
