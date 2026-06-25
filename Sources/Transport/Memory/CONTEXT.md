# Memory Transport — CONTEXT
Scope/role: in-memory transport for tests (`P2PTransportMemory`). Simulates connections with
no network for fast, deterministic unit tests. Not for production.

`MemoryHub` routes dials to registered listeners and creates connection pairs;
`MemoryChannel` is the bidirectional data channel. A shared default hub serves simple tests;
an isolated `MemoryHub()` isolates test cases (`reset()` cleans up).

## Contracts (the load-bearing rules)
- Single-reader / single-accepter by design: concurrent `read()` or `accept()` throw
  `TransportError.unsupportedOperation` (so tests fail loudly instead of hanging). Keep this.
- `MemoryHub` holds listeners by weak reference; dropping the strong reference auto-removes
  them. `register` prunes dead weak entries to prevent unbounded tombstone accumulation.
- All public APIs throw `TransportError`; `MemoryHubDetailError` /
  `MemoryConnectionDetailError` are carried as the `connectionFailed(underlying:)` payload.

## Invariants (must hold; tests guard them)
- Buffers are bounded per direction (`memoryChannelMaxBufferedBytes`, default 1MB). On
  overflow, `write()` throws `connectionFailed(underlying: .receiveBufferFull)` and resumes
  once the peer drains — NO silent drop and NO silent switch (fail-closed backpressure).
- Empty `Data()` is the EOF sentinel on the channel (a documented behavior; differs from TCP
  which throws on EOF).

## Dependencies & seams
- `P2PTransport` only. No NIO; single-process only.

## Build
- Host: `swift build`. Tests: `swift test --filter MemoryTransport` (with a timeout).

Last reviewed: 2026-06-25
