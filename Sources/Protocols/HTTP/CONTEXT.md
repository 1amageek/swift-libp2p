# HTTP — CONTEXT
Scope/role: HTTP/1.1 semantics over libp2p streams (`P2PHTTP`). Server-side route
registration + dispatch and client-side request sending over multiplexed streams.

This is HTTP/1.1 request/response carried on a libp2p `MuxedStream`, not over TCP sockets.
`HTTPCodec` does the text-format encode/decode; `HTTPService` registers routes and
dispatches.

## Contracts (the load-bearing rules)
- `HTTPService` is `class + Mutex` (high-frequency route lookups), EventEmitting (single
  consumer), `shutdown()` per the Protocols-layer convention. Keep these.
- Route matching order: exact method+path first, then wildcard method+path.

## Invariants (must hold; tests guard them)
- Message size and Content-Length handling are bounded by `HTTPProtocol` limits; the codec
  round-trips request/response framing faithfully (tested for header/body edge cases).

## Dependencies & seams
- `P2PCore` (PeerID, ByteBuffer, Logger), `P2PMux` (MuxedStream), `P2PProtocols`.

## Wire protocol notes
- Protocol ID `/http/1.1`. Standard HTTP/1.1 text framing
  (`METHOD /path HTTP/1.1\r\n` headers `\r\n\r\n` body / `HTTP/1.1 CODE MSG\r\n` ...).

## Build
- Host: `swift build`. Tests: `swift test --filter HTTP` (with a timeout).

Last reviewed: 2026-06-25
