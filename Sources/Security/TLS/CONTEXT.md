# TLS — CONTEXT
Scope/role: libp2p TLS 1.3 security for TCP (`P2PSecurityTLS`). A `SecurityUpgrader` over
swift-tls that performs libp2p-TLS mutual authentication. Read this before changing the
certificate validator, the `verifyPeer: false` decision, or the fail-closed PeerID binding.

`TLSUpgrader` delegates the RFC 8446 handshake and record layer to the swift-tls Tier-1
`TLS` facade (`TLSClient`/`TLSServer`); this module only builds/verifies the libp2p
certificate and extracts the verified PeerID. The load-bearing part is that authentication
stays strong even though libp2p certs are self-signed (no CA chain).

## Contracts (the load-bearing rules)
- TLS 1.3 handshake + encryption/decryption are swift-tls's job; this layer owns only
  libp2p certificate generation/verification and PeerID extraction. Certificate
  build/parse/verify goes through `P2PCoreDER` (Embedded-clean minimal-DER), migrated from
  swift-certificates in M6b.
- Mutual TLS: `requireClientCertificate: true` makes both ends present a certificate. After
  the handshake, the upgrader reads the verified `PeerIdentity` from `endpoint.peerIdentity`
  (surfaced by the facade's custom `certificateValidator`) and binds the remote PeerID to
  the `TLSSecuredConnection`.
- Timeout vs external cancellation is distinguished by a `Mutex<Bool>` flag in
  `performTimedHandshake()`. Identities are generated per-identity and cached.

## Invariants (must hold; tests guard them)
- **`verifyPeer: false` is correct, not a weakening.** libp2p certificates are self-signed
  X.509 with no CA chain, so the facade's standard CA-chain check is intentionally off.
  Authentication is NOT weakened because: (1) CertificateVerify proof-of-possession (the peer
  holds the leaf private key) is ALWAYS checked in-core by swift-tls, and (2) the custom
  `certificateValidator` enforces the libp2p extension signature, PeerID derivation, and
  `expectedPeer` match. This mirrors the proven swift-quic libp2p-TLS path.
- **Fail-closed PeerID binding.** If a genuinely verified identity cannot be obtained, the
  upgrader throws `TLSError.peerIdentityUnavailable` — it never silently accepts an
  unidentified peer. As defense-in-depth, when `expectedPeer` is set the upgrader re-checks
  the surfaced PeerID itself rather than trusting the validator alone.

## Dependencies & seams
- swift-tls Tier-1 `TLS` facade (`TLSClient`/`TLSServer`/`TLSConfiguration`/`TLSIdentity`/
  `Certificate`/`PeerIdentity`). The old `TLSCore`/`TLSRecord` were folded into `TLS` by the
  facade redesign — do not route through them.
- `P2PCoreDER` (swift-p2p-core) for libp2p RPK certificate build/parse/verify. swift-crypto
  for P-256 ephemeral key generation + SignedKey sign/verify (injected as closures into
  P2PCoreDER). The custom `certificateValidator` closure is the seam that surfaces the
  verified `PeerIdentity`.

## Wire protocol notes
- Protocol ID `/tls/1.0.0` (go/rust compatible). libp2p extension OID
  `1.3.6.1.4.1.53594.1.1` carries `SignedKey { publicKey, signature }`, where `signature`
  signs `"libp2p-tls-handshake:" + SPKI(DER)`. Certificate uses an ephemeral P-256 key pair.
- Early Muxer Negotiation (ALPN): `EarlyMuxerNegotiating`-conformant. The ALPN list carries
  muxer hints in priority order (e.g. `["libp2p/yamux/1.0.0", "libp2p/mplex/6.7.0",
  "libp2p"]`); a negotiated ALPN starting `"libp2p/"` selects the muxer directly (saving a
  multistream-select RTT), while bare `"libp2p"` falls back to multistream-select.

## Build
- Host: `swift build`. Tests: `swift test --filter TLS` (with a timeout).

Last reviewed: 2026-06-25
