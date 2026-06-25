# Mplex — CONTEXT
Scope/role: Mplex multiplexer (`P2PMuxMplex`). Varint-framed stream multiplexing with NO
flow control. Read this before changing the control-frame queue or the per-stream buffer
bound — they prevent head-of-line stalls and unbounded buffering.

`MplexConnection` runs a read loop and demultiplexes varint-framed messages into
`MplexStream`s. Unlike Yamux there is no window-based flow control, so the safety net is the
per-stream read-buffer cap and the bounded control-frame queue.

## Contracts (the load-bearing rules)
- Concurrency: `Mutex<State>` for high-frequency stream state (same as Yamux); an
  `actor` frame writer serializes writes. No EventEmitting (internal).
- **Control frames (RST) go through a bounded queue, not inline.** RST from the read loop is
  sent by a separate task via `MplexControlFrameQueue` to prevent the read loop wedging on
  lower-layer write backpressure. The queue is bounded; on overflow the connection is
  dropped — NO silent drop.
- Cleanup is best-effort but explicit: shutdown/reject-path `sendFrame`/`stream.close()` are
  `do-catch`ed and the failure reason logged at debug — not silently swallowed.

## Invariants (must hold; tests guard them)
- **Per-stream read buffer is bounded by `maxReadBufferSizePerStream` (default 1MB),
  separate from `maxFrameSize`.** Frame size and "max unread stream buffer" are distinct
  concepts; do not conflate them again.
- Stream-ID parity (same as Yamux): Initiator odd, Responder even. Half-close
  (CloseInitiator/CloseReceiver) and reset (ResetInitiator/ResetReceiver) are distinct
  per-direction operations.

## Dependencies & seams
- `P2PMux` (Muxer).

## Wire protocol notes
- Protocol ID `/mplex/6.7.0`. Frame: `[header: varint][length: varint][data: bytes]` where
  `header = (streamID << 3) | flag`. Flags: NewStream 0, MessageReceiver 1,
  MessageInitiator 2, CloseReceiver 3, CloseInitiator 4, ResetReceiver 5, ResetInitiator 6.
  No flow control and no keep-alive (vs Yamux).

## Build
- Host: `swift build`. Tests: `swift test --filter Mplex` (with a timeout).

Last reviewed: 2026-06-25
