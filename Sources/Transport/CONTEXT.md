# Transport — CONTEXT
Scope/role: transport-layer protocol definitions (`P2PTransport`) plus implementations
(TCP, Memory, QUIC, WebRTC, WebSocket, WebTransport). Read this before adding a transport
or touching the dial/listen contract.

`P2PTransport` is protocol-only and depends on `P2PCore` alone (no NIO). A "raw" transport
(`Transport`) returns a `RawConnection` that the Security and Mux layers then upgrade.
"Secured" transports (QUIC/WebRTC/WebTransport) bypass that pipeline and return a
`MuxedConnection` directly because they bring their own TLS/DTLS + multiplexing.

## Contracts (the load-bearing rules)
- Protocol/implementation split: `P2PTransport` carries only the `Transport` / `Listener`
  protocols and depends only on `P2PCore`. Implementations live in separate targets and
  depend on `P2PTransport`. Do not pull NIO into `P2PTransport`.
- A raw `Transport.dial`/`listen` returns `RawConnection`; securing is the Security layer's
  job. Secured transports implement `dialSecured`/`listenSecured` and return an
  already-secured-and-muxed connection. Keep these two shapes distinct.
- Concurrency: async/await throughout; do not use `EventLoopFuture` in transport surfaces.
  Use `class + Mutex` only where channel state must be tracked.
- `TransportError` (in `P2PTransport`) is the unified public error type. Internal detail
  errors (e.g. `MemoryHubDetailError`, `WebSocketDetailError`) are carried as the
  `connectionFailed(underlying:)` payload, which stays `any Error` (the
  `any Error & Sendable` tightening was deliberately rejected — see git history; E2E tests
  recursively unwrap `underlying` to read POSIX errno).

## Invariants (must hold; tests guard them)
- Bounded inbound buffering on every real transport (DoS defense): TCP/WebSocket cap at
  1MB (`tcpMaxReadBufferSize` / `wsMaxReadBufferSize`), Memory bounds per direction
  (`memoryChannelMaxBufferedBytes`). No silent unbounded growth.
- TCP/WebSocket support concurrent `read()`/`accept()` via FIFO waiter queues; `read()`
  returns buffered data before reporting closed (no data loss on close); `close()` cleans up
  all waiters and pending connections and is idempotent.
- Memory transport is single-reader / single-accepter by design (deterministic tests):
  concurrent `read()`/`accept()` throw `TransportError.unsupportedOperation`, not hang.

## Dependencies & seams
- `P2PTransport` → `P2PCore`. TCP → NIO; QUIC → swift-quic + `P2PMux`; WebRTC → swift-webrtc
  + `P2PMux` + `P2PCertificate`; WebSocket → NIOWebSocket/NIOHTTP1; Memory → none.

## Wire protocol notes
- `Transport.protocols` advertises the multiaddr component stacks each transport handles
  (e.g. `[["ip4","tcp"],["ip6","tcp"]]`). `canDial`/`canListen` gate addressability.

## Build
- Host: `swift build`. Tests: `swift test --filter Transport` (with a timeout).

Last reviewed: 2026-06-25
