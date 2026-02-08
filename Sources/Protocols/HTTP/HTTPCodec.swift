/// HTTPCodec - Simple HTTP/1.1 text format encoder/decoder for libp2p streams.

/// Encodes and decodes HTTP/1.1 messages for transmission over libp2p streams.
///
/// The wire format follows standard HTTP/1.1 text format:
///
/// Request:
/// ```
/// GET /path HTTP/1.1\r\n
/// Header-Name: value\r\n
/// \r\n
/// [body]
/// ```
///
/// Response:
/// ```
/// HTTP/1.1 200 OK\r\n
/// Header-Name: value\r\n
/// \r\n
/// [body]
/// ```
public struct HTTPCodec: Sendable {

    // MARK: - Constants

    private static let crlf: [UInt8] = [0x0D, 0x0A]  // \r\n
    private static let doubleCrlf: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]
    private static let httpVersion = "HTTP/1.1"
    private static let space: UInt8 = 0x20
    private static let colon: UInt8 = 0x3A

    // MARK: - Request Encoding

    /// Encodes an HTTP request into bytes.
    ///
    /// - Parameter request: The request to encode
    /// - Returns: The encoded bytes in HTTP/1.1 format
    public static func encodeRequest(_ request: HTTPRequest) -> [UInt8] {
        var result: [UInt8] = []

        // Request line: METHOD /path HTTP/1.1\r\n
        result.append(contentsOf: Array(request.method.rawValue.utf8))
        result.append(space)
        result.append(contentsOf: Array(request.path.utf8))
        result.append(space)
        result.append(contentsOf: Array(httpVersion.utf8))
        result.append(contentsOf: crlf)

        // Build headers, adding Content-Length if body is present
        var headers = request.headers
        if let body = request.body {
            let hasContentLength = headers.contains { $0.0.lowercased() == "content-length" }
            if !hasContentLength {
                headers.append(("Content-Length", "\(body.count)"))
            }
        }

        // Headers
        for (name, value) in headers {
            result.append(contentsOf: Array(name.utf8))
            result.append(contentsOf: Array(": ".utf8))
            result.append(contentsOf: Array(value.utf8))
            result.append(contentsOf: crlf)
        }

        // Empty line separating headers from body
        result.append(contentsOf: crlf)

        // Body
        if let body = request.body {
            result.append(contentsOf: body)
        }

        return result
    }

    // MARK: - Request Decoding

    /// Decodes an HTTP request from bytes.
    ///
    /// - Parameter data: The raw bytes to decode
    /// - Returns: The decoded HTTP request
    /// - Throws: `HTTPError.malformedMessage` if the data is not valid HTTP/1.1
    /// - Throws: `HTTPError.headersTooLarge` if headers exceed the limit
    /// - Throws: `HTTPError.bodyTooLarge` if the body exceeds the limit
    /// - Throws: `HTTPError.unsupportedMethod` if the HTTP method is not recognized
    public static func decodeRequest(from data: [UInt8]) throws -> HTTPRequest {
        // Find header/body boundary
        guard let headerEndIndex = findDoubleCrlf(in: data) else {
            throw HTTPError.malformedMessage("Missing header terminator (\\r\\n\\r\\n)")
        }

        let headerSize = headerEndIndex
        if headerSize > HTTPProtocol.maxHeaderSize {
            throw HTTPError.headersTooLarge(headerSize)
        }

        // Parse header section as string
        let headerBytes = Array(data[0..<headerEndIndex])
        guard let headerString = String(bytes: headerBytes, encoding: .utf8) else {
            throw HTTPError.malformedMessage("Headers contain invalid UTF-8")
        }

        // Split into lines
        let lines = headerString.components(separatedBy: "\r\n")
        guard !lines.isEmpty else {
            throw HTTPError.malformedMessage("Empty request")
        }

        // Parse request line: METHOD /path HTTP/1.1
        let requestLine = lines[0]
        let requestParts = requestLine.split(separator: " ", maxSplits: 2)
        guard requestParts.count == 3 else {
            throw HTTPError.malformedMessage("Invalid request line: \(requestLine)")
        }

        let methodString = String(requestParts[0])
        guard let method = HTTPMethod(rawValue: methodString) else {
            throw HTTPError.unsupportedMethod(methodString)
        }

        let path = String(requestParts[1])

        // Parse headers
        var headers: [(String, String)] = []
        for i in 1..<lines.count {
            let line = lines[i]
            if line.isEmpty { continue }

            guard let colonIndex = line.firstIndex(of: ":") else {
                throw HTTPError.malformedMessage("Invalid header line: \(line)")
            }

            let name = String(line[line.startIndex..<colonIndex])
            let valueStart = line.index(after: colonIndex)
            let value = String(line[valueStart...]).trimmingCharacters(in: .whitespaces)
            headers.append((name, value))
        }

        // Extract body (everything after \r\n\r\n)
        let bodyStart = headerEndIndex + doubleCrlf.count
        var body: [UInt8]?
        if bodyStart < data.count {
            let bodyBytes = Array(data[bodyStart...])

            // Check body size limit
            if bodyBytes.count > HTTPProtocol.maxBodySize {
                throw HTTPError.bodyTooLarge(bodyBytes.count)
            }

            body = bodyBytes
        }

        return HTTPRequest(method: method, path: path, headers: headers, body: body)
    }

    // MARK: - Response Encoding

    /// Encodes an HTTP response into bytes.
    ///
    /// - Parameter response: The response to encode
    /// - Returns: The encoded bytes in HTTP/1.1 format
    public static func encodeResponse(_ response: HTTPResponse) -> [UInt8] {
        var result: [UInt8] = []

        // Status line: HTTP/1.1 200 OK\r\n
        result.append(contentsOf: Array(httpVersion.utf8))
        result.append(space)
        result.append(contentsOf: Array("\(response.statusCode)".utf8))
        result.append(space)
        result.append(contentsOf: Array(response.statusMessage.utf8))
        result.append(contentsOf: crlf)

        // Build headers, adding Content-Length if body is present
        var headers = response.headers
        if let body = response.body {
            let hasContentLength = headers.contains { $0.0.lowercased() == "content-length" }
            if !hasContentLength {
                headers.append(("Content-Length", "\(body.count)"))
            }
        }

        // Headers
        for (name, value) in headers {
            result.append(contentsOf: Array(name.utf8))
            result.append(contentsOf: Array(": ".utf8))
            result.append(contentsOf: Array(value.utf8))
            result.append(contentsOf: crlf)
        }

        // Empty line separating headers from body
        result.append(contentsOf: crlf)

        // Body
        if let body = response.body {
            result.append(contentsOf: body)
        }

        return result
    }

    // MARK: - Response Decoding

    /// Decodes an HTTP response from bytes.
    ///
    /// - Parameter data: The raw bytes to decode
    /// - Returns: The decoded HTTP response
    /// - Throws: `HTTPError.malformedMessage` if the data is not valid HTTP/1.1
    /// - Throws: `HTTPError.headersTooLarge` if headers exceed the limit
    /// - Throws: `HTTPError.bodyTooLarge` if the body exceeds the limit
    public static func decodeResponse(from data: [UInt8]) throws -> HTTPResponse {
        // Find header/body boundary
        guard let headerEndIndex = findDoubleCrlf(in: data) else {
            throw HTTPError.malformedMessage("Missing header terminator (\\r\\n\\r\\n)")
        }

        let headerSize = headerEndIndex
        if headerSize > HTTPProtocol.maxHeaderSize {
            throw HTTPError.headersTooLarge(headerSize)
        }

        // Parse header section as string
        let headerBytes = Array(data[0..<headerEndIndex])
        guard let headerString = String(bytes: headerBytes, encoding: .utf8) else {
            throw HTTPError.malformedMessage("Headers contain invalid UTF-8")
        }

        // Split into lines
        let lines = headerString.components(separatedBy: "\r\n")
        guard !lines.isEmpty else {
            throw HTTPError.malformedMessage("Empty response")
        }

        // Parse status line: HTTP/1.1 200 OK
        let statusLine = lines[0]
        let statusParts = statusLine.split(separator: " ", maxSplits: 2)
        guard statusParts.count >= 2 else {
            throw HTTPError.malformedMessage("Invalid status line: \(statusLine)")
        }

        guard let statusCode = Int(statusParts[1]) else {
            throw HTTPError.malformedMessage("Invalid status code: \(statusParts[1])")
        }

        let statusMessage: String
        if statusParts.count >= 3 {
            statusMessage = String(statusParts[2])
        } else {
            statusMessage = ""
        }

        // Parse headers
        var headers: [(String, String)] = []
        for i in 1..<lines.count {
            let line = lines[i]
            if line.isEmpty { continue }

            guard let colonIndex = line.firstIndex(of: ":") else {
                throw HTTPError.malformedMessage("Invalid header line: \(line)")
            }

            let name = String(line[line.startIndex..<colonIndex])
            let valueStart = line.index(after: colonIndex)
            let value = String(line[valueStart...]).trimmingCharacters(in: .whitespaces)
            headers.append((name, value))
        }

        // Extract body (everything after \r\n\r\n)
        let bodyStart = headerEndIndex + doubleCrlf.count
        var body: [UInt8]?
        if bodyStart < data.count {
            let bodyBytes = Array(data[bodyStart...])

            // Check body size limit
            if bodyBytes.count > HTTPProtocol.maxBodySize {
                throw HTTPError.bodyTooLarge(bodyBytes.count)
            }

            body = bodyBytes
        }

        return HTTPResponse(statusCode: statusCode, statusMessage: statusMessage, headers: headers, body: body)
    }

    // MARK: - Private Helpers

    /// Finds the index of the first occurrence of \r\n\r\n in the data.
    ///
    /// - Parameter data: The data to search
    /// - Returns: The index of the start of the double CRLF, or nil if not found
    private static func findDoubleCrlf(in data: [UInt8]) -> Int? {
        guard data.count >= 4 else { return nil }

        for i in 0...(data.count - 4) {
            if data[i] == 0x0D && data[i + 1] == 0x0A &&
               data[i + 2] == 0x0D && data[i + 3] == 0x0A {
                return i
            }
        }
        return nil
    }
}
