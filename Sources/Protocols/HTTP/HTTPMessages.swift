/// HTTPMessages - Request, response, and method types for HTTP over libp2p.

/// HTTP method verbs.
public enum HTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case delete = "DELETE"
    case head = "HEAD"
    case options = "OPTIONS"
    case patch = "PATCH"
}

/// An HTTP request transmitted over a libp2p stream.
public struct HTTPRequest: Sendable {
    /// The HTTP method.
    public var method: HTTPMethod

    /// The request path (e.g., "/api/v1/resource").
    public var path: String

    /// Headers as ordered key-value pairs.
    public var headers: [(String, String)]

    /// Optional request body.
    public var body: [UInt8]?

    /// Creates a new HTTP request.
    ///
    /// - Parameters:
    ///   - method: The HTTP method
    ///   - path: The request path
    ///   - headers: Headers as key-value pairs
    ///   - body: Optional request body
    public init(
        method: HTTPMethod,
        path: String,
        headers: [(String, String)] = [],
        body: [UInt8]? = nil
    ) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }
}

/// An HTTP response transmitted over a libp2p stream.
public struct HTTPResponse: Sendable {
    /// The HTTP status code (e.g., 200, 404).
    public var statusCode: Int

    /// The HTTP status message (e.g., "OK", "Not Found").
    public var statusMessage: String

    /// Headers as ordered key-value pairs.
    public var headers: [(String, String)]

    /// Optional response body.
    public var body: [UInt8]?

    /// Creates a new HTTP response.
    ///
    /// - Parameters:
    ///   - statusCode: The HTTP status code
    ///   - statusMessage: The HTTP status message
    ///   - headers: Headers as key-value pairs
    ///   - body: Optional response body
    public init(
        statusCode: Int,
        statusMessage: String,
        headers: [(String, String)] = [],
        body: [UInt8]? = nil
    ) {
        self.statusCode = statusCode
        self.statusMessage = statusMessage
        self.headers = headers
        self.body = body
    }

    /// Creates a 200 OK response.
    ///
    /// - Parameters:
    ///   - body: Optional response body
    ///   - headers: Additional headers
    /// - Returns: A 200 OK response
    public static func ok(body: [UInt8]? = nil, headers: [(String, String)] = []) -> HTTPResponse {
        HTTPResponse(statusCode: 200, statusMessage: "OK", headers: headers, body: body)
    }

    /// Creates a 404 Not Found response.
    ///
    /// - Returns: A 404 Not Found response
    public static func notFound() -> HTTPResponse {
        HTTPResponse(statusCode: 404, statusMessage: "Not Found")
    }

    /// Creates a 400 Bad Request response.
    ///
    /// - Returns: A 400 Bad Request response
    public static func badRequest() -> HTTPResponse {
        HTTPResponse(statusCode: 400, statusMessage: "Bad Request")
    }

    /// Creates a 500 Internal Server Error response.
    ///
    /// - Returns: A 500 Internal Server Error response
    public static func internalServerError() -> HTTPResponse {
        HTTPResponse(statusCode: 500, statusMessage: "Internal Server Error")
    }
}
