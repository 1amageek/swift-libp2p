# Yamux — CONTEXT
Scope/role: Yamux multiplexer (`P2PMuxYamux`). Stream multiplexing with window-based flow
control, keep-alive (Ping/Pong), and graceful shutdown (GoAway). Read this before changing
flow control, the control-frame queue, or the DoS bounds — they prevent stalls and resource
exhaustion.

`YamuxConnection` runs a read loop over the secured connection and demultiplexes 12-byte
framed messages into `YamuxStream`s. Flow control is per-stream AND per-connection. The
load-bearing parts are window accounting (no leaks), head-of-line-blocking avoidance, and
the many DoS caps.

## Contracts (the load-bearing rules)
- `YamuxConnection.start()` must be called before use (starts the read loop); it is
  idempotent. State lives behind a `Mutex`.
- Window reservation is TOCTOU-safe: `YamuxStream.write()` checks-and-reserves window
  atomically inside the lock (`WindowReserveResult.reserved/noWindow/closed`). Do not split
  the check and the debit.
- Concurrent `read()` and window-wait use arrays of continuations with FIFO/wake-all
  semantics (single continuations would lose waiters). Keep the array form.
- **Control frames go through a bounded queue, not inline.** ACK/RST/Pong are sent by a
  separate task via `ControlFrameQueue`, never inline from the read loop — otherwise
  lower-layer write backpressure can wedge the read loop and stop draining window updates
  (soft deadlock). The queue is bounded; on overflow the connection is dropped — NO silent
  drop.

## Invariants (must hold; tests guard them)
- **No flow-control window leaks.** Data discarded after `closeRead()`/`localReadClosed`
  still returns its receive-window credit (`FlowController.dataDiscarded`/`windowForClose`),
  so a peer that keeps writing to a half-closed stream cannot starve the window to 0 and
  stall.
- **Connection-level flow control**: a shared receive window
  (`connectionReceiveWindow`, default 16MB, `ConnectionFlowController`) bounds aggregate
  in-flight bytes below the session read buffer; consumed/discarded bytes are returned via
  stream-0 window updates; exceeding it is a protocol violation that drops the connection.
- DoS bounds (all reject with RST / typed error, never silent): frame length capped at
  `yamuxMaxFrameSize` (16MB, `frameTooLarge`); `maxConcurrentStreams` (1000); SYN for an
  existing stream ID rejected; inbound stream backpressure via `.bufferingOldest`
  (`maxPendingInboundStreams`, 100) — deliver-then-ACK/RST, never silent drop; send-window
  update overflow capped at `yamuxMaxWindowSize` (16MB); `newStream()` cleans up its map
  entry if the SYN send fails.
- Remote stream-ID validation: ID 0 invalid; an initiator must receive even IDs, a responder
  odd IDs; violations answered with RST. A zero send-window writer times out after 30s
  (`YamuxError.protocolError`).
- Keep-alive (go-libp2p/HashiCorp-compatible defaults: interval 30s, timeout 60s,
  `keepAliveTimeout >= keepAliveInterval` enforced): periodic Ping; missing Pong past timeout
  closes the connection and notifies all streams.

## Dependencies & seams
- `P2PMux` (Muxer). Big-endian wire encoding.

## Wire protocol notes
- Protocol ID `/yamux/1.0.0`. 12-byte header: Version(8, always 0), Type(8: Data 0,
  WindowUpdate 1, Ping 2, GoAway 3), Flags(16: SYN 0x1, ACK 0x2, FIN 0x4, RST 0x8),
  StreamID(32), Length(32). Default initial window 256KB; WindowUpdate sent when the receive
  window drops below half. GoAway codes: 0 normal, 1 protocol error, 2 internal error.

## Build
- Host: `swift build`. Tests: `swift test --filter Yamux` (with a timeout).

Last reviewed: 2026-06-25
