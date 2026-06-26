# WebSocket Transport — CONTEXT
Scope/role: WebSocket transport (`P2PTransportWebSocket`) over NIOWebSocket + NIOHTTP1.
A raw `Transport` (like TCP): returns `RawConnection` for the Security → Mux pipeline.

`ws` provides no encryption, so it goes through the standard libp2p Security upgrade; `wss`
adds transport-level TLS but that is independent of the libp2p Security layer (Noise/TLS).
All payload frames are sent as Binary opcode.

## Contracts (the load-bearing rules)
- Implements `Transport` (NOT `SecuredTransport`); returns `RawConnection`. Client uses the
  NIO typed upgrade API; server uses the typed upgrader + `NIOAsyncChannel`
  (`executeThenClose`), with a background Task iterating inbound streams. `close()` cancels
  that Task, ending `executeThenClose` and auto-closing the server channel.
- Concurrency: `class + Mutex` (same pattern as TCP). State protected by `Mutex`:
  connection read buffer/waiters, listener pending connections/waiters + accept Task,
  frame-handler buffering.
- Frames: outgoing data is Binary opcode; clients MUST mask per RFC 6455, servers MUST NOT;
  Ping is auto-answered with Pong; a Close frame triggers a close response then channel close.

## Invariants (must hold; tests guard them)
- DoS bounds: `wsMaxReadBufferSize` (1MB) caps the read buffer; `wsMaxFrameSize` (1MB) caps
  frame size. Overflow closes the connection fail-closed; WebSocket must preserve the
  byte-stream contract for the Security -> Mux pipeline.
- Concurrent reads are FIFO-ordered; `close()` is idempotent; `read()` returns buffered data
  before reporting closed.
- `wss` is restricted: dial only with client TLS `.fullVerification` and a DNS hostname (IP
  literals rejected); listen only with an explicitly supplied server TLS config
  (`canListen(.wss)` is `false` otherwise). The `/p2p/<peer>` suffix is allowed on dial only.

## Dependencies & seams
- `P2PTransport`, `NIOCore`, `NIOHTTP1`, `NIOWebSocket`.

## Wire protocol notes
- Multiaddr: `/ip4|ip6|dns|dns4|dns6/<host>/tcp/<port>/ws` (code 477) and `.../wss`
  (code 478, secure). RFC 6455 framing; HTTP/1.1 Upgrade handshake.
  `protocols == [["ip4","tcp","ws"],["ip6","tcp","ws"]]`.

## Build
- Host: `swift build`. Tests: `swift test --filter WebSocketTransport` (with a timeout).

Last reviewed: 2026-06-25
