# P2PHTTP

## Overview
HTTP/1.1 semantics over libp2p streams.

## Responsibilities
- HTTP request/response over multiplexed libp2p streams
- Server-side route registration and request dispatching
- Client-side request sending to remote peers
- Event emission for request/response lifecycle monitoring

## Protocol ID
- `/http/1.1`

## Dependencies
- `P2PCore` (PeerID, ByteBuffer, Logger)
- `P2PMux` (MuxedStream)
- `P2PProtocols` (ProtocolService, StreamOpener, HandlerRegistry)

---

## File Structure

```
Sources/Protocols/HTTP/
├── HTTPProtocol.swift    # Protocol constants
├── HTTPMessages.swift    # HTTPRequest, HTTPResponse, HTTPMethod
├── HTTPCodec.swift       # HTTP/1.1 text format encoder/decoder
├── HTTPError.swift       # Error types
├── HTTPService.swift     # Main service implementation
└── CONTEXT.md
```

## Key Types

| Type | Description |
|------|-------------|
| `HTTPProtocol` | Protocol constants (ID, limits) |
| `HTTPMethod` | HTTP method verbs (GET, POST, etc.) |
| `HTTPRequest` | Request message (method, path, headers, body) |
| `HTTPResponse` | Response message (status, headers, body) |
| `HTTPCodec` | Encoder/decoder for HTTP/1.1 wire format |
| `HTTPError` | Error types for HTTP operations |
| `HTTPService` | Protocol service implementation |
| `HTTPConfiguration` | Service configuration |

---

## Wire Protocol

### Request Format

```
METHOD /path HTTP/1.1\r\n
Header-Name: value\r\n
Content-Length: N\r\n
\r\n
[body bytes]
```

### Response Format

```
HTTP/1.1 STATUS_CODE STATUS_MESSAGE\r\n
Header-Name: value\r\n
Content-Length: N\r\n
\r\n
[body bytes]
```

### Message Flow

```
Client                     Server
   |---- HTTP Request ------->|
   |                          | (route dispatch)
   |<--- HTTP Response -------|
```

---

## API

### Server-side Route Registration

```swift
let httpService = HTTPService()

httpService.route(method: .get, path: "/hello") { request in
    return .ok(body: Array("Hello, World!".utf8))
}

httpService.route(path: "/echo") { request in
    return .ok(body: request.body)
}

await httpService.registerHandler(registry: node)
```

### Client-side Request

```swift
let response = try await httpService.request(
    HTTPRequest(method: .get, path: "/hello"),
    to: remotePeer,
    using: node
)
print("Status: \(response.statusCode)")
```

---

## Design Decisions

- **EventEmitting pattern**: Single consumer, consistent with Protocols layer convention
- **Class + Mutex**: High-frequency route lookups use Mutex, not Actor
- **Lifecycle**: `shutdown()` per Protocols layer convention
- **Route matching**: Exact method+path first, then wildcard method+path

## Tests

```
Tests/Protocols/HTTPTests/
└── HTTPServiceTests.swift    # Unit tests
```

### Test Coverage
| Area | Status |
|------|--------|
| Protocol constants | Planned |
| Message types | Planned |
| Codec roundtrip | Planned |
| Service lifecycle | Planned |
| Route registration | Planned |
| Error handling | Planned |
