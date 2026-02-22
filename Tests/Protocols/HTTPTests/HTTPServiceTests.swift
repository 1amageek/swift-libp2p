/// HTTPServiceTests - Unit tests for HTTP over libp2p
import Testing
import Foundation
@testable import P2PHTTP
@testable import P2PCore
@testable import P2PProtocols

// MARK: - Protocol Constants

@Suite("HTTPProtocol Constants Tests")
struct HTTPProtocolConstantsTests {

    @Test("Protocol ID is /http/1.1")
    func protocolID() {
        #expect(HTTPProtocol.protocolID == "/http/1.1")
    }

    @Test("Max header size is 8192 bytes")
    func maxHeaderSize() {
        #expect(HTTPProtocol.maxHeaderSize == 8192)
    }

    @Test("Max body size is 10MB")
    func maxBodySize() {
        #expect(HTTPProtocol.maxBodySize == 10 * 1024 * 1024)
    }
}

// MARK: - HTTPMethod

@Suite("HTTPMethod Tests")
struct HTTPMethodTests {

    @Test("GET raw value")
    func getRawValue() {
        #expect(HTTPMethod.get.rawValue == "GET")
    }

    @Test("POST raw value")
    func postRawValue() {
        #expect(HTTPMethod.post.rawValue == "POST")
    }

    @Test("PUT raw value")
    func putRawValue() {
        #expect(HTTPMethod.put.rawValue == "PUT")
    }

    @Test("DELETE raw value")
    func deleteRawValue() {
        #expect(HTTPMethod.delete.rawValue == "DELETE")
    }

    @Test("HEAD raw value")
    func headRawValue() {
        #expect(HTTPMethod.head.rawValue == "HEAD")
    }

    @Test("OPTIONS raw value")
    func optionsRawValue() {
        #expect(HTTPMethod.options.rawValue == "OPTIONS")
    }

    @Test("PATCH raw value")
    func patchRawValue() {
        #expect(HTTPMethod.patch.rawValue == "PATCH")
    }

    @Test("HTTPMethod can be created from raw value")
    func initFromRawValue() {
        #expect(HTTPMethod(rawValue: "GET") == .get)
        #expect(HTTPMethod(rawValue: "POST") == .post)
        #expect(HTTPMethod(rawValue: "INVALID") == nil)
    }
}

// MARK: - HTTPRequest

@Suite("HTTPRequest Tests")
struct HTTPRequestTests {

    @Test("Request creation with defaults")
    func requestWithDefaults() {
        let request = HTTPRequest(method: .get, path: "/hello")

        #expect(request.method == .get)
        #expect(request.path == "/hello")
        #expect(request.headers.isEmpty)
        #expect(request.body == nil)
    }

    @Test("Request creation with all parameters")
    func requestWithAllParams() {
        let body: [UInt8] = Array("test body".utf8)
        let headers: [(String, String)] = [
            ("Content-Type", "text/plain"),
            ("Accept", "application/json"),
        ]

        let request = HTTPRequest(
            method: .post,
            path: "/api/data",
            headers: headers,
            body: body
        )

        #expect(request.method == .post)
        #expect(request.path == "/api/data")
        #expect(request.headers.count == 2)
        #expect(request.headers[0].0 == "Content-Type")
        #expect(request.headers[0].1 == "text/plain")
        #expect(request.headers[1].0 == "Accept")
        #expect(request.headers[1].1 == "application/json")
        #expect(request.body == body)
    }

    @Test("Request is mutable")
    func requestIsMutable() {
        var request = HTTPRequest(method: .get, path: "/original")
        request.method = .post
        request.path = "/modified"
        request.headers = [("X-Custom", "value")]
        request.body = [0x01, 0x02]

        #expect(request.method == .post)
        #expect(request.path == "/modified")
        #expect(request.headers.count == 1)
        #expect(request.body == [0x01, 0x02])
    }
}

// MARK: - HTTPResponse

@Suite("HTTPResponse Tests")
struct HTTPResponseTests {

    @Test("Response creation with all parameters")
    func responseWithAllParams() {
        let body: [UInt8] = Array("response body".utf8)
        let response = HTTPResponse(
            statusCode: 201,
            statusMessage: "Created",
            headers: [("Location", "/resource/1")],
            body: body
        )

        #expect(response.statusCode == 201)
        #expect(response.statusMessage == "Created")
        #expect(response.headers.count == 1)
        #expect(response.headers[0].0 == "Location")
        #expect(response.headers[0].1 == "/resource/1")
        #expect(response.body == body)
    }

    @Test("Response ok factory")
    func responseOk() {
        let body: [UInt8] = Array("hello".utf8)
        let response = HTTPResponse.ok(body: body)

        #expect(response.statusCode == 200)
        #expect(response.statusMessage == "OK")
        #expect(response.body == body)
    }

    @Test("Response ok factory with headers")
    func responseOkWithHeaders() {
        let response = HTTPResponse.ok(
            body: Array("data".utf8),
            headers: [("Content-Type", "text/plain")]
        )

        #expect(response.statusCode == 200)
        #expect(response.headers.count == 1)
        #expect(response.headers[0].0 == "Content-Type")
        #expect(response.headers[0].1 == "text/plain")
    }

    @Test("Response ok factory with nil body")
    func responseOkNilBody() {
        let response = HTTPResponse.ok()

        #expect(response.statusCode == 200)
        #expect(response.statusMessage == "OK")
        #expect(response.body == nil)
    }

    @Test("Response notFound factory")
    func responseNotFound() {
        let response = HTTPResponse.notFound()

        #expect(response.statusCode == 404)
        #expect(response.statusMessage == "Not Found")
        #expect(response.body == nil)
    }

    @Test("Response badRequest factory")
    func responseBadRequest() {
        let response = HTTPResponse.badRequest()

        #expect(response.statusCode == 400)
        #expect(response.statusMessage == "Bad Request")
        #expect(response.body == nil)
    }

    @Test("Response internalServerError factory")
    func responseInternalServerError() {
        let response = HTTPResponse.internalServerError()

        #expect(response.statusCode == 500)
        #expect(response.statusMessage == "Internal Server Error")
        #expect(response.body == nil)
    }
}

// MARK: - HTTPCodec Request Roundtrip

@Suite("HTTPCodec Request Tests")
struct HTTPCodecRequestTests {

    @Test("Encode/decode GET request roundtrip")
    func getRequestRoundtrip() throws {
        let request = HTTPRequest(method: .get, path: "/api/v1/status")

        let encoded = HTTPCodec.encodeRequest(request)
        let decoded = try HTTPCodec.decodeRequest(from: encoded)

        #expect(decoded.method == .get)
        #expect(decoded.path == "/api/v1/status")
        #expect(decoded.body == nil)
    }

    @Test("Encode/decode POST request with body roundtrip")
    func postRequestWithBodyRoundtrip() throws {
        let body: [UInt8] = Array("{\"key\":\"value\"}".utf8)
        let request = HTTPRequest(
            method: .post,
            path: "/api/data",
            headers: [("Content-Type", "application/json")],
            body: body
        )

        let encoded = HTTPCodec.encodeRequest(request)
        let decoded = try HTTPCodec.decodeRequest(from: encoded)

        #expect(decoded.method == .post)
        #expect(decoded.path == "/api/data")
        #expect(decoded.body == body)

        // Check that Content-Type header is preserved
        let contentType = decoded.headers.first { $0.0 == "Content-Type" }
        #expect(contentType != nil)
        #expect(contentType?.1 == "application/json")
    }

    @Test("Encode/decode request with multiple headers roundtrip")
    func requestWithMultipleHeaders() throws {
        let request = HTTPRequest(
            method: .put,
            path: "/resource",
            headers: [
                ("Accept", "text/html"),
                ("Authorization", "Bearer token123"),
                ("X-Custom-Header", "custom-value"),
            ]
        )

        let encoded = HTTPCodec.encodeRequest(request)
        let decoded = try HTTPCodec.decodeRequest(from: encoded)

        #expect(decoded.method == .put)
        #expect(decoded.path == "/resource")
        #expect(decoded.headers.count == 3)

        #expect(decoded.headers[0].0 == "Accept")
        #expect(decoded.headers[0].1 == "text/html")
        #expect(decoded.headers[1].0 == "Authorization")
        #expect(decoded.headers[1].1 == "Bearer token123")
        #expect(decoded.headers[2].0 == "X-Custom-Header")
        #expect(decoded.headers[2].1 == "custom-value")
    }

    @Test("All HTTP methods encode/decode correctly")
    func allMethodsRoundtrip() throws {
        let methods: [HTTPMethod] = [.get, .post, .put, .delete, .head, .options, .patch]

        for method in methods {
            let request = HTTPRequest(method: method, path: "/test")
            let encoded = HTTPCodec.encodeRequest(request)
            let decoded = try HTTPCodec.decodeRequest(from: encoded)
            #expect(decoded.method == method, "Method \(method.rawValue) roundtrip failed")
        }
    }

    @Test("Request encoding produces valid HTTP/1.1 format")
    func requestEncodingFormat() {
        let request = HTTPRequest(
            method: .get,
            path: "/hello",
            headers: [("Host", "example.com")]
        )

        let encoded = HTTPCodec.encodeRequest(request)
        let text = String(bytes: encoded, encoding: .utf8)!

        #expect(text.hasPrefix("GET /hello HTTP/1.1\r\n"))
        #expect(text.contains("Host: example.com\r\n"))
        #expect(text.hasSuffix("\r\n\r\n"))
    }
}

// MARK: - HTTPCodec Response Roundtrip

@Suite("HTTPCodec Response Tests")
struct HTTPCodecResponseTests {

    @Test("Encode/decode 200 OK response roundtrip")
    func okResponseRoundtrip() throws {
        let body: [UInt8] = Array("Hello, World!".utf8)
        let response = HTTPResponse.ok(body: body)

        let encoded = HTTPCodec.encodeResponse(response)
        let decoded = try HTTPCodec.decodeResponse(from: encoded)

        #expect(decoded.statusCode == 200)
        #expect(decoded.statusMessage == "OK")
        #expect(decoded.body == body)
    }

    @Test("Encode/decode 404 Not Found response roundtrip")
    func notFoundResponseRoundtrip() throws {
        let response = HTTPResponse.notFound()

        let encoded = HTTPCodec.encodeResponse(response)
        let decoded = try HTTPCodec.decodeResponse(from: encoded)

        #expect(decoded.statusCode == 404)
        #expect(decoded.statusMessage == "Not Found")
        #expect(decoded.body == nil)
    }

    @Test("Encode/decode response with headers roundtrip")
    func responseWithHeadersRoundtrip() throws {
        let response = HTTPResponse(
            statusCode: 201,
            statusMessage: "Created",
            headers: [
                ("Content-Type", "application/json"),
                ("X-Request-Id", "abc-123"),
            ],
            body: Array("{\"id\":1}".utf8)
        )

        let encoded = HTTPCodec.encodeResponse(response)
        let decoded = try HTTPCodec.decodeResponse(from: encoded)

        #expect(decoded.statusCode == 201)
        #expect(decoded.statusMessage == "Created")
        #expect(decoded.body == Array("{\"id\":1}".utf8))

        let contentType = decoded.headers.first { $0.0 == "Content-Type" }
        #expect(contentType?.1 == "application/json")

        let requestId = decoded.headers.first { $0.0 == "X-Request-Id" }
        #expect(requestId?.1 == "abc-123")
    }

    @Test("Response encoding produces valid HTTP/1.1 format")
    func responseEncodingFormat() {
        let response = HTTPResponse(
            statusCode: 200,
            statusMessage: "OK",
            headers: [("Server", "swift-libp2p")]
        )

        let encoded = HTTPCodec.encodeResponse(response)
        let text = String(bytes: encoded, encoding: .utf8)!

        #expect(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(text.contains("Server: swift-libp2p\r\n"))
        #expect(text.hasSuffix("\r\n\r\n"))
    }
}

// MARK: - HTTPCodec Error Handling

@Suite("HTTPCodec Error Handling Tests")
struct HTTPCodecErrorTests {

    @Test("Decoding empty data throws malformedMessage")
    func decodeEmptyRequest() {
        #expect(throws: HTTPError.self) {
            _ = try HTTPCodec.decodeRequest(from: [])
        }
    }

    @Test("Decoding data without header terminator throws malformedMessage")
    func decodeRequestNoTerminator() {
        let data = Array("GET /path HTTP/1.1\r\nHost: example.com".utf8)
        #expect(throws: HTTPError.self) {
            _ = try HTTPCodec.decodeRequest(from: data)
        }
    }

    @Test("Decoding request with invalid method throws unsupportedMethod")
    func decodeRequestInvalidMethod() {
        let data = Array("INVALID /path HTTP/1.1\r\n\r\n".utf8)
        do {
            _ = try HTTPCodec.decodeRequest(from: data)
            Issue.record("Expected unsupportedMethod error")
        } catch let error as HTTPError {
            if case .unsupportedMethod(let method) = error {
                #expect(method == "INVALID")
            } else {
                Issue.record("Expected unsupportedMethod, got \(error)")
            }
        } catch {
            Issue.record("Expected HTTPError, got \(error)")
        }
    }

    @Test("Decoding response with invalid status line throws malformedMessage")
    func decodeResponseInvalidStatusLine() {
        let data = Array("INVALID\r\n\r\n".utf8)
        #expect(throws: HTTPError.self) {
            _ = try HTTPCodec.decodeResponse(from: data)
        }
    }

    @Test("Decoding response with non-numeric status code throws malformedMessage")
    func decodeResponseNonNumericStatus() {
        let data = Array("HTTP/1.1 ABC OK\r\n\r\n".utf8)
        do {
            _ = try HTTPCodec.decodeResponse(from: data)
            Issue.record("Expected malformedMessage error")
        } catch let error as HTTPError {
            if case .malformedMessage = error {
                // Expected
            } else {
                Issue.record("Expected malformedMessage, got \(error)")
            }
        } catch {
            Issue.record("Expected HTTPError, got \(error)")
        }
    }

    @Test("Decoding empty response data throws malformedMessage")
    func decodeEmptyResponse() {
        #expect(throws: HTTPError.self) {
            _ = try HTTPCodec.decodeResponse(from: [])
        }
    }

    @Test("Decoding request with malformed header line throws error")
    func decodeMalformedHeaderLine() {
        // Header line without a colon
        let data = Array("GET /path HTTP/1.1\r\nBadHeader\r\n\r\n".utf8)
        #expect(throws: HTTPError.self) {
            _ = try HTTPCodec.decodeRequest(from: data)
        }
    }
}

// MARK: - HTTPService

@Suite("HTTPService Tests")
struct HTTPServiceTests {

    @Test("HTTPService has correct protocol ID")
    func protocolID() {
        let service = HTTPService()
        #expect(service.protocolIDs == ["/http/1.1"])
    }

    @Test("HTTPConfiguration has correct defaults")
    func defaultConfiguration() {
        let config = HTTPConfiguration()
        #expect(config.timeout == .seconds(30))
    }

    @Test("HTTPConfiguration accepts custom timeout")
    func customConfiguration() {
        let config = HTTPConfiguration(timeout: .seconds(60))
        #expect(config.timeout == .seconds(60))
    }

    @Test("Events stream is available")
    func eventsStream() {
        let service = HTTPService()

        // Should be able to get the events stream
        _ = service.events

        // Getting it again should return the same stream (single consumer)
        _ = service.events
    }

    @Test("Route registration does not throw")
    func routeRegistration() {
        let service = HTTPService()

        // Register method-specific route
        service.route(method: .get, path: "/test") { _ in
            return .ok()
        }

        // Register wildcard method route
        service.route(path: "/any") { _ in
            return .ok()
        }
    }

    @Test("Multiple routes can be registered")
    func multipleRoutes() {
        let service = HTTPService()

        service.route(method: .get, path: "/a") { _ in .ok() }
        service.route(method: .post, path: "/b") { _ in .ok() }
        service.route(method: .put, path: "/c") { _ in .ok() }
        service.route(method: .delete, path: "/d") { _ in .ok() }
        service.route(path: "/e") { _ in .ok() }

        // Service should still work after multiple registrations
        #expect(service.protocolIDs == ["/http/1.1"])
    }

    @Test("Shutdown terminates event stream", .timeLimit(.minutes(1)))
    func shutdownTerminatesEventStream() async {
        let service = HTTPService()

        // Get the event stream
        let events = service.events

        // Start consuming events in a task
        let consumeTask = Task {
            var count = 0
            for await _ in events {
                count += 1
            }
            return count
        }

        // Give time for the consumer to start
        do { try await Task.sleep(for: .milliseconds(50)) } catch { }

        // Shutdown should terminate the stream
        await service.shutdown()

        // Consumer should complete without timing out
        let count = await consumeTask.value
        #expect(count == 0)
    }

    @Test("Shutdown is idempotent")
    func shutdownIsIdempotent() async {
        let service = HTTPService()

        // Multiple shutdowns should not crash
        await service.shutdown()
        await service.shutdown()
        await service.shutdown()

        // Service should still report correct protocol IDs
        #expect(service.protocolIDs == ["/http/1.1"])
    }
}

// MARK: - Headers Handling

@Suite("Headers Handling Tests")
struct HeadersHandlingTests {

    @Test("Request headers preserve order")
    func requestHeaderOrder() throws {
        let headers: [(String, String)] = [
            ("Z-Header", "last"),
            ("A-Header", "first"),
            ("M-Header", "middle"),
        ]
        let request = HTTPRequest(method: .get, path: "/test", headers: headers)

        let encoded = HTTPCodec.encodeRequest(request)
        let decoded = try HTTPCodec.decodeRequest(from: encoded)

        #expect(decoded.headers[0].0 == "Z-Header")
        #expect(decoded.headers[1].0 == "A-Header")
        #expect(decoded.headers[2].0 == "M-Header")
    }

    @Test("Response headers preserve order")
    func responseHeaderOrder() throws {
        let headers: [(String, String)] = [
            ("X-First", "1"),
            ("X-Second", "2"),
            ("X-Third", "3"),
        ]
        let response = HTTPResponse(
            statusCode: 200,
            statusMessage: "OK",
            headers: headers
        )

        let encoded = HTTPCodec.encodeResponse(response)
        let decoded = try HTTPCodec.decodeResponse(from: encoded)

        #expect(decoded.headers[0].0 == "X-First")
        #expect(decoded.headers[0].1 == "1")
        #expect(decoded.headers[1].0 == "X-Second")
        #expect(decoded.headers[1].1 == "2")
        #expect(decoded.headers[2].0 == "X-Third")
        #expect(decoded.headers[2].1 == "3")
    }

    @Test("Duplicate header names are preserved")
    func duplicateHeaderNames() throws {
        let headers: [(String, String)] = [
            ("Set-Cookie", "a=1"),
            ("Set-Cookie", "b=2"),
        ]
        let response = HTTPResponse(
            statusCode: 200,
            statusMessage: "OK",
            headers: headers
        )

        let encoded = HTTPCodec.encodeResponse(response)
        let decoded = try HTTPCodec.decodeResponse(from: encoded)

        let setCookies = decoded.headers.filter { $0.0 == "Set-Cookie" }
        #expect(setCookies.count == 2)
        #expect(setCookies[0].1 == "a=1")
        #expect(setCookies[1].1 == "b=2")
    }

    @Test("Header values with colons are preserved")
    func headerValuesWithColons() throws {
        let request = HTTPRequest(
            method: .get,
            path: "/test",
            headers: [("Authorization", "Basic dXNlcjpwYXNz")]
        )

        let encoded = HTTPCodec.encodeRequest(request)
        let decoded = try HTTPCodec.decodeRequest(from: encoded)

        let auth = decoded.headers.first { $0.0 == "Authorization" }
        #expect(auth?.1 == "Basic dXNlcjpwYXNz")
    }
}

// MARK: - Body Encoding

@Suite("Body Encoding Tests")
struct BodyEncodingTests {

    @Test("Empty body encodes correctly")
    func emptyBody() throws {
        let request = HTTPRequest(method: .get, path: "/test")
        let encoded = HTTPCodec.encodeRequest(request)
        let decoded = try HTTPCodec.decodeRequest(from: encoded)

        #expect(decoded.body == nil)
    }

    @Test("Binary body encodes correctly")
    func binaryBody() throws {
        let body: [UInt8] = [0x00, 0x01, 0x02, 0xFF, 0xFE, 0xFD]
        let request = HTTPRequest(method: .post, path: "/upload", body: body)

        let encoded = HTTPCodec.encodeRequest(request)
        let decoded = try HTTPCodec.decodeRequest(from: encoded)

        #expect(decoded.body == body)
    }

    @Test("UTF-8 text body roundtrips correctly")
    func utf8Body() throws {
        let text = "Hello, World! Unicode: \u{1F600}"
        let body = Array(text.utf8)
        let request = HTTPRequest(method: .post, path: "/text", body: body)

        let encoded = HTTPCodec.encodeRequest(request)
        let decoded = try HTTPCodec.decodeRequest(from: encoded)

        #expect(decoded.body == body)
        let decodedText = String(bytes: decoded.body!, encoding: .utf8)
        #expect(decodedText == text)
    }

    @Test("Content-Length header is auto-added for request body")
    func contentLengthAutoAddedRequest() {
        let body: [UInt8] = Array("test".utf8)
        let request = HTTPRequest(method: .post, path: "/test", body: body)

        let encoded = HTTPCodec.encodeRequest(request)
        let text = String(bytes: encoded, encoding: .utf8)!

        #expect(text.contains("Content-Length: 4\r\n"))
    }

    @Test("Content-Length header is auto-added for response body")
    func contentLengthAutoAddedResponse() {
        let body: [UInt8] = Array("response".utf8)
        let response = HTTPResponse.ok(body: body)

        let encoded = HTTPCodec.encodeResponse(response)
        let text = String(bytes: encoded, encoding: .utf8)!

        #expect(text.contains("Content-Length: 8\r\n"))
    }

    @Test("Explicit Content-Length is not duplicated")
    func explicitContentLengthNotDuplicated() {
        let body: [UInt8] = Array("test".utf8)
        let request = HTTPRequest(
            method: .post,
            path: "/test",
            headers: [("Content-Length", "4")],
            body: body
        )

        let encoded = HTTPCodec.encodeRequest(request)
        let text = String(bytes: encoded, encoding: .utf8)!

        // Count occurrences of Content-Length
        let occurrences = text.components(separatedBy: "Content-Length").count - 1
        #expect(occurrences == 1)
    }

    @Test("Response body roundtrips correctly")
    func responseBodyRoundtrip() throws {
        let body: [UInt8] = Array("{\"status\":\"ok\",\"count\":42}".utf8)
        let response = HTTPResponse.ok(
            body: body,
            headers: [("Content-Type", "application/json")]
        )

        let encoded = HTTPCodec.encodeResponse(response)
        let decoded = try HTTPCodec.decodeResponse(from: encoded)

        #expect(decoded.body == body)
    }
}

// MARK: - HTTPError

@Suite("HTTPError Tests")
struct HTTPErrorTests {

    @Test("All HTTPError cases exist")
    func allErrorCases() {
        let errors: [HTTPError] = [
            .headersTooLarge(9000),
            .bodyTooLarge(20_000_000),
            .malformedMessage("bad"),
            .unsupportedMethod("TRACE"),
            .noRouteFound("GET", "/missing"),
            .streamClosed,
            .timeout,
            .handlerError("handler failed"),
            .connectionFailed("no route"),
        ]

        #expect(errors.count == 9)
    }

    @Test("HTTPError is Equatable")
    func errorEquatable() {
        #expect(HTTPError.timeout == HTTPError.timeout)
        #expect(HTTPError.streamClosed == HTTPError.streamClosed)
        #expect(HTTPError.headersTooLarge(100) == HTTPError.headersTooLarge(100))
        #expect(HTTPError.headersTooLarge(100) != HTTPError.headersTooLarge(200))
    }

    @Test("HTTPError conforms to Error")
    func errorConformsToError() {
        let error: any Error = HTTPError.timeout
        #expect(error is HTTPError)
    }
}
