# Mux — CONTEXT
Scope/role: stream-multiplexing layer — protocol (`P2PMux`) plus implementations
(`P2PMuxYamux`, `P2PMuxMplex`). Turns a `SecuredConnection` into a `MuxedConnection`
carrying many logical `MuxedStream`s. Read this before changing the muxer protocols or the
length-prefixed helpers.

`P2PMux` is protocol-only (`Muxer` / `MuxedConnection` / `MuxedStream`). A muxer is
negotiated by multistream-select over the secured connection, then `multiplex()` yields a
`MuxedConnection` from which streams are opened/accepted. The implementations carry the
flow-control / cancellation invariants — see the per-muxer CONTEXTs.

## Contracts (the load-bearing rules)
- Protocol/implementation split: `P2PMux` defines `Muxer`/`MuxedConnection`/`MuxedStream`
  and depends on `P2PCore`; Yamux/Mplex depend on `P2PMux`.
- Length-prefixed helpers on `MuxedStream`
  (`readLengthPrefixedMessage(maxSize:)`, the buffer-preserving overload, and
  `writeLengthPrefixedMessage`) use libp2p-standard Varint length prefixes and bound the
  message at `maxSize` (default 64KB), throwing `messageTooLarge`. Keep these bounded;
  `streamClosed`/`emptyMessage` are the other error cases.

## Invariants (must hold; tests guard them)
- Stream-ID parity: Initiator opens odd IDs (1,3,5,…), Responder even (2,4,6,…); ID 0 is
  control. This holds for both Yamux and Mplex.
- A muxed stream exposes `closeWrite`/`closeRead`/`close`/`reset` distinctly (half-close vs
  full close vs abort). `MuxedStream.protocolID` holds the multistream-select-agreed protocol.

## Dependencies & seams
- `P2PMux` → `P2PCore`. `SecuredConnection` (the input) is defined in `P2PCore`.

## Wire protocol notes
- Muxer protocol IDs negotiated via multistream-select: `/yamux/1.0.0`, `/mplex/6.7.0`. See
  the per-muxer CONTEXT for framing details.

## Build
- Host: `swift build`. Tests: `swift test --filter Mux` (with a timeout).

Last reviewed: 2026-06-25
