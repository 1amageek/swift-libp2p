# WebRTC Transport — CONTEXT
Scope/role: WebRTC Direct transport (`P2PTransportWebRTC`) over swift-webrtc. A "secured"
transport: DTLS 1.2 + SCTP data-channel multiplexing are built in, so it bypasses the
Security/Mux upgrade pipeline and returns a `MuxedConnection` directly. Read this before
changing the UDP routing, certificate verification, or the swift-webrtc import surface.

WebRTC Direct is UDP-based (NAT-traversal friendly). `dialSecured`/`listenSecured` yield a
`WebRTCMuxedConnection`. The load-bearing parts are the UDP→DTLS→SCTP→DataChannel demux,
certhash-based certificate verification, and address-based connection routing.

## Contracts (the load-bearing rules)
- WebRTC bypasses the standard upgrade pipeline; do not route it through SecurityUpgrader or
  a Muxer.
- Import ONLY the `WebRTC` umbrella product from swift-webrtc (plus `DataChannel` for
  DCEP/data-channel types). DTLS runs through the swift-tls Tier-1 `TLS` facade
  (`DTLSClient`/`DTLSServer`) driven internally by `WebRTC`. swift-webrtc's
  `DTLSCore`/`DTLSRecord` are now package targets (not importable products); other exported
  products (STUN*, ICELite*, SCTP*, DataChannelCore) must not be imported directly.
- Socket ownership differs by mode: dial mode creates a dedicated 1:1 ephemeral-port socket
  owned by the connection; listen mode binds one 1:N shared socket owned by
  `WebRTCSecuredListener` and routes datagrams by remote address (`addressKey`), removing
  routes on connection close. Keep this ownership split — it governs cleanup.

## Invariants (must hold; tests guard them)
- Datagram demux follows RFC 5764 §5.1.2 by first byte: STUN (0–3) → ICE Lite,
  DTLS (20–63) → DTLSConnection; post-handshake payloads are SCTP-decoded into DCEP
  (new DataChannel/stream) vs application data.
- **PeerID authentication via DTLS 1.2 self-signed cert extension**
  (OID 1.3.6.1.4.1.53594.1.1) carrying `SignedKey { public_key, signature }` over
  `"libp2p-tls-handshake:" + certificate` — same scheme as libp2p-QUIC. After the
  handshake, PeerID is extracted via `LibP2PCertificate.extractPeerID()`. The dial-side
  `/certhash` (multihash SHA-256 of the DTLS cert) is verified against the presented leaf.
- `SocketAddress.addressKey` is derived from `ipAddress` (not `host`) because
  `SocketAddress(ipAddress:port:)` leaves `host` empty while NIO-received addresses populate
  it; mixing them would split the routing table.

## Dependencies & seams
- `P2PTransport`, `P2PCore`, `P2PMux`, `P2PCertificate`, `WebRTC` (swift-webrtc umbrella).

## Wire protocol notes
- Multiaddr: `/ip4|ip6/<ip>/udp/<port>/webrtc-direct[/certhash/<base64-multihash>]`. ICE
  candidate exchange and TURN relay are pending; browser/go/rust interop pending.

## Build
- Host: `swift build`. Tests: `swift test --filter WebRTCTransport` (with a timeout).

Last reviewed: 2026-06-25
