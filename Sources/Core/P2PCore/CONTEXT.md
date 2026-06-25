# P2PCore — CONTEXT
Scope/role: the foundation module every other target depends on. Minimal shared
abstractions: identity (PeerID/keys), addressing (Multiaddr), connection protocols, utils
(Varint/Base58/Multihash), and signed records (Envelope/PeerRecord). Read this before
adding to it — it is deliberately small.

P2PCore owns the wire-compatible primitives the whole stack shares. Its hard rule is
minimalism: it must NOT contain Transport/Security/Mux implementations, network I/O, or
state management (ConnectionPool etc.). A change here is a breaking change for everyone, so
keep the surface lean and the wire formats stable.

## Contracts (the load-bearing rules)
- Keep this module minimal: no concrete Transport/Security/Mux, no networking, no stateful
  managers. `RawConnection` / `SecuredConnection` / `SecurityRole` are defined HERE (so the
  Security/Mux layers can import them without importing each other).
- Modern crypto only: Ed25519 + ECDSA P-256 are supported; RSA and Secp256k1 are
  intentionally excluded. `KeyType` defines all variants for protobuf wire compatibility, but
  generating/verifying with RSA/Secp256k1 returns `unsupportedKeyType` (fail-closed, no
  silent degrade).

## Invariants (must hold; tests guard them)
- **PeerID encoding**: Ed25519 (and any key ≤42 bytes) uses the identity multihash (public
  key recoverable from the PeerID); larger keys use SHA-256 (public key NOT recoverable, per
  libp2p spec). Don't change which hash a key type uses.
- **Untrusted-length DoS guards**: Varint→Int conversion is bounds-checked
  (`decodeAsInt`/`toInt`, `valueExceedsIntMax`); Multiaddr parsing caps input at 1KB
  (`multiaddrMaxInputSize`) and 20 components (`multiaddrMaxComponents`). These guards must
  stay — they protect every caller that parses remote bytes.
- **Multiaddr is fail-closed on bad input**: the checked `init` validates `ip4`/`ip6` values
  (invalid → `invalidAddress`, never malformed bytes); IPv6 uses `inet_pton(AF_INET6,...)`
  (covers embedded IPv4 + zone-ID stripping); value-consumption is decided by protocol
  metadata (`requiresValue`), not next-token guessing. `init(uncheckedProtocols:)` exists
  only for already-validated input.
- **Envelope domain separation**: `verify(domain:)` / `record(as:)` include the domain
  string in signature verification. Do not drop the domain (it prevents cross-record-type
  replay).

## Dependencies & seams
- swift-crypto (primitives), swift-log. Nothing else — adding a dependency here propagates
  to the whole stack.

## Wire protocol notes
- PeerID: multihash (identity for Ed25519, SHA-256 otherwise); string parsing supports CIDv1
  multibase prefixes (`z` base58btc, `f` hex, `b` base32) plus legacy `Qm…` base58btc.
  Multiaddr: self-describing binary format. Implemented hashes: Identity (0x00) + SHA-256
  (0x12); SHA-512/SHA3/BLAKE2 are code-defined but unimplemented.

## Build
- Host: `swift build`. Tests: `swift test --filter P2PCore` (with a timeout).

Last reviewed: 2026-06-25
