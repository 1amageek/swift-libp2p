# QUIC Transport — CONTEXT
Scope/role: QUIC transport (`P2PTransportQUIC`) over swift-quic. A "secured" transport:
TLS 1.3 + native stream multiplexing are built in, so it bypasses the Security/Mux upgrade
pipeline and returns a `MuxedConnection` directly. Read this before changing the TLS
provider, stream-close semantics, or the StreamChannel.

QUIC provides built-in TLS 1.3, native multiplexing, congestion control, and 0-RTT.
`dialSecured`/`listenSecured` yield `QUICMuxedConnection` (already secured + muxed). The
load-bearing parts are libp2p PeerID authentication via the TLS certificate extension and
the stream-close semantics.

## Contracts (the load-bearing rules)
- QUIC bypasses the standard upgrade pipeline; do not route QUIC through SecurityUpgrader
  or a Muxer. The connection is secured and muxed by the transport itself.
- `QUICMuxedConnection` uses a `StreamChannel` (thread-safe buffer + waiters) that BOTH
  `inboundStreams` (AsyncStream) and `acceptStream()` consume from. Use ONE pattern per
  connection, never both — they drain the same source.
- swift-quic's `QUICConnectionProtocol` has no `acceptStream()`; incoming streams arrive via
  `incomingStreams` (single-consumer). `remoteAddress` is dynamic (connection migration).

## Invariants (must hold; tests guard them)
- **Stream close is FIN-only.** `close()` sends FIN (not STOP_SENDING) so pending data is
  delivered before the stream closes; `reset()` sends RESET_STREAM for abrupt termination;
  `closeWrite()` = FIN, `closeRead()` = STOP_SENDING. Do not make `close()` send
  STOP_SENDING (that loses in-flight data).
- **PeerID authentication via TLS 1.3 cert extension** (OID 1.3.6.1.4.1.53594.1.1)
  carrying a `SignedKey { public_key, signature }`; signature is over
  `"libp2p-tls-handshake:" + certificate`. PeerID verification is enforced; Ed25519 + ECDSA.

## Dependencies & seams
- `P2PTransport`, `P2PCore`, `P2PMux`, `QUIC` (swift-quic). The libp2p TLS 1.3 provider is
  `SwiftQUICTLSProvider`; certificate build/parse/verify goes through `P2PCoreDER`
  (Embedded-clean minimal-DER) via `LibP2PCertificateHelper`. `QUICHolePunchCoordinator`
  handles NAT-traversal timing for QUIC hole punching.

## Wire protocol notes
- Multiaddr: `/ip4|ip6/<ip>/udp/<port>/quic-v1`. 0-RTT via `ClientSessionCache`; connection
  migration supported. go-libp2p + rust-libp2p connect/identify/ping interop verified.

## Build
- Host: `swift build`. Tests: `swift test --filter QUICTransport` (with a timeout).

Last reviewed: 2026-06-25
