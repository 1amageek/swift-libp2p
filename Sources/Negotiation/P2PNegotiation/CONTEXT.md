# P2PNegotiation — CONTEXT
Scope/role: multistream-select (`P2PNegotiation`). Protocol negotiation (initiator +
responder), protocol listing (`ls`), and V1-Lazy (0-RTT) negotiation. Read this before
changing the framing, the remainder handling, or the DoS bound.

`MultistreamSelect` negotiates which security/mux/app protocol to run over a stream. The
subtle parts are reading across fragmented/coalesced messages and preserving bytes read past
the negotiation (the `remainder`) so the next layer doesn't lose application data.

## Contracts (the load-bearing rules)
- `readNextMessage()` absorbs fragmentation and coalesced reads internally; partial reads are
  accumulated, never assumed complete. Negotiation may read past its last message —
  `NegotiationResult.remainder` carries that surplus, and callers (e.g.
  `Integration/P2P/P2P.swift` via `BufferedMuxedStream`) MUST forward it to the next layer.
  Do not discard the remainder.
- V1-Lazy (`negotiateLazy()`): the first candidate + header are sent together (1 RTT when
  accepted); on `na` it falls back to the remaining candidates normally. V1-Lazy is
  backward-compatible with V1, so the responder needs no change.

## Invariants (must hold; tests guard them)
- **Message length is bounded** by `maxMessageSize` (with an `Int.max` guard before
  allocation) — no unbounded allocation from a remote length prefix.
- Decoding is strict: invalid UTF-8 is rejected (strict `String(data:encoding:)`); decode
  returns the consumed length so call sites can preserve trailing bytes.
- Protocol IDs are case-sensitive and the trailing `\n` is required; `ls` returns a single
  outer varint + newline-delimited payload (no nested per-protocol varints — interop-correct).

## Dependencies & seams
- `P2PCore` (Varint). Timeouts are the transport layer's job, not this module's.

## Wire protocol notes
- Protocol ID `/multistream/1.0.0`. Message = `varint(length) + message + "\n"`. Both ends
  exchange the `/multistream/1.0.0` header, then the initiator proposes protocols and the
  responder replies with the protocol or `na` (not available). `ls` lists supported protocols.

## Build
- Host: `swift build`. Tests: `swift test --filter P2PNegotiation` (with a timeout).

Last reviewed: 2026-06-25
