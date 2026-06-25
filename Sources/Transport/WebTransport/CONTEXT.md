# WebTransport — CONTEXT
Scope/role: WebTransport transport (`P2PTransportWebTransport`) for browser-reachable peers.
A "secured" transport built on QUIC: inherits TLS 1.3 + multiplexing, adds certhash-based
certificate verification. Read this before changing certificate rotation or the session
negotiation shim.

WebTransport runs over QUIC + HTTP/3. Until native HTTP/3 Extended CONNECT lands in
swift-quic, session setup uses a QUIC-stream framed hello/ack shim. The load-bearing parts
are short-lived certificate rotation (browser requirement) and certhash verification.

## Contracts (the load-bearing rules)
- `dialSecured`/`listenSecured` return a `WebTransportMuxedConnection` wrapping QUIC streams
  as WebTransport muxed streams. Session negotiation is a QUIC-stream hello/ack shim
  (`WebTransportSessionNegotiator`) — a deliberate placeholder for HTTP/3 Extended CONNECT.
  Keep it isolated so it can be swapped without touching the muxed-connection surface.
- The certificate store (`WebTransportCertificateStore`) holds current + next material and
  the advertised hashes; the listener background-refreshes the advertised `/certhash` values.

## Invariants (must hold; tests guard them)
- **Certificates are short-lived.** Browsers require self-signed certs valid ≤ 14 days;
  default rotation is 12 days (2-day clock-skew buffer). During rotation the server
  advertises BOTH current and next certhashes so clients can connect across the transition.
- ALPN is verified — the negotiated ALPN must be `h3`.
- The client verifies the remote leaf certificate against the `/certhash` in the dialed
  multiaddr (multihash SHA-256). The address parser is strict about protocol order and
  certhash format.
- DNS dial resolves `dns`/`dns4`/`dns6` hosts before the QUIC dial.

## Dependencies & seams
- `P2PCore` (PeerID, Multiaddr, KeyPair), `Crypto` (SHA-256), `Synchronization` (Mutex).
  Runs over the QUIC transport stack.

## Wire protocol notes
- Multiaddr extends QUIC: `/ip4|ip6|dns*/.../udp/<port>/quic-v1/webtransport/certhash/<h>`;
  multiple `/certhash/...` components allowed for rotation. Future: native HTTP/3 Extended
  CONNECT, WebTransport datagrams, browser interop.

## Build
- Host: `swift build`. Tests: `swift test --filter WebTransport` (with a timeout).

Last reviewed: 2026-06-25
