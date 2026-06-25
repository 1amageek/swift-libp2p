# TCP Transport — CONTEXT
Scope/role: SwiftNIO-based TCP transport (`P2PTransportTCP`). Returns `RawConnection` for
the standard Security → Mux upgrade pipeline.

`TCPTransport` dials/listens via NIO bootstraps and wraps a NIO `Channel` as a
`RawConnection`. Reads are bridged through a `ChannelInboundHandler` into a buffer guarded
by a `Mutex`; writes use `channel.writeAndFlush`.

## Contracts (the load-bearing rules)
- async/await only — no `EventLoopFuture` in the public surface. NIO is bridged via
  `Channel` + `TCPReadHandler`; `class + Mutex` is used only for channel state
  (`TCPConnectionState`, `ListenerState`, the handlers themselves).
- The `EventLoopGroup` lifecycle is owned here (`ownsGroup` tracks whether to shut it down).

## Invariants (must hold; tests guard them)
- Inbound buffering is bounded by `tcpMaxReadBufferSize` (1MB); on overflow the connection
  is closed and waiters fail (no unbounded growth / DoS).
- Concurrent `read()`/`accept()` are FIFO via `readWaiters`/`acceptWaiters`, never deadlock.
- `read()` returns buffered data before checking `isClosed` (no loss of data received just
  before close); `write()` checks local close state first; `close()` closes pending
  connections (no leak) and is idempotent. `SocketAddress.toMultiaddr()` returns `nil` on a
  missing port rather than fabricating `/tcp/0`.
- TCP socket options set: `tcp_nodelay` + `so_keepalive` on both transport and listener.

## Dependencies & seams
- `P2PTransport` (Transport), `NIOCore`, `NIOPosix`.

## Wire protocol notes
- Plain TCP; no libp2p-specific framing. Protocol negotiation happens in the Security/Mux
  layers above. `protocols == [["ip4","tcp"],["ip6","tcp"]]`.

## Build
- Host: `swift build`. Tests: `swift test --filter TCPTransport` (with a timeout).

Last reviewed: 2026-06-25
