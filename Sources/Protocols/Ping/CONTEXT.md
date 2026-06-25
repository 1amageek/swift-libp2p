# Ping — CONTEXT
Scope/role: libp2p Ping (`P2PPing`). Connection liveness, RTT measurement, NAT keepalive.

Ping echoes a fixed 32-byte random payload and times the round trip. The only subtlety is
exact framing: a single `MuxedStream.read()` may return more or fewer than 32 bytes.

## Contracts (the load-bearing rules)
- `PingStreamReader` buffers internally and returns exactly the requested byte count,
  reading more from the stream as needed. Do not assume one read yields exactly 32 bytes.

## Invariants (must hold; tests guard them)
- Payload is exactly 32 bytes (spec); the responder echoes the received payload verbatim.
- Requests have a configurable timeout (30s default).
- `statistics(from:)` computes min/max/avg at nanosecond precision.

## Dependencies & seams
- `P2PCore` (PeerID), `P2PMux` (MuxedStream), `P2PProtocols` (ProtocolService).

## Wire protocol notes
- Protocol ID `/ipfs/ping/1.0.0`. Wire: send 32 random bytes, receive the same 32 bytes
  echoed back; RTT = receive time − send time. Verified against go/rust-libp2p over QUIC.

## Build
- Host: `swift build`. Tests: `swift test --filter Ping` (with a timeout).

Last reviewed: 2026-06-25
