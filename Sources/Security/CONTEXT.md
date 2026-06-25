# Security — CONTEXT
Scope/role: security-upgrade layer — protocol (`P2PSecurity`) plus implementations (Noise,
TLS, Plaintext, Pnet). Upgrades a `RawConnection` to a `SecuredConnection` with mutual
PeerID authentication. Read this before changing the upgrade contract or peer verification.

`P2PSecurity` is protocol-only (`SecurityUpgrader`). An upgrader takes a `RawConnection`,
runs a handshake, and returns a `SecuredConnection` with `localPeer`/`remotePeer` fixed.
Pnet (Private Network) is a separate, lower layer: when configured it encrypts the whole
connection (including the security handshake) before the upgrader runs.

## Contracts (the load-bearing rules)
- Protocol/implementation split: `P2PSecurity` defines `SecurityUpgrader` only and depends
  on `P2PCore`. Note: `SecuredConnection` itself is defined in `P2PCore`, NOT `P2PSecurity`.
- During the handshake the upgrader buffers reads; any bytes received past the handshake are
  handed to the `SecuredConnection` as an initial buffer (Noise: frame-reassembly buffer;
  TLS: `initialApplicationData`; Plaintext: post-Exchange remainder). Do not drop these
  trailing bytes — they are real application/record data.
- Per-module concurrency uniformity: full-duplex connections (Noise, Pnet) use separate
  `Mutex<SendState>` + `Mutex<RecvState>` so read and write never contend; handshake state
  machines are `struct: Sendable` value types mutated via `mutating` methods.

## Invariants (must hold; tests guard them)
- **Mutual PeerID authentication.** When `expectedPeer` is supplied, the upgrade fails
  unless the verified remote PeerID matches; handshake failure raises a typed
  `SecurityError`. Never surface an unverified/mismatched peer.
- pnet runs BELOW the SecurityUpgrader: all traffic, including the security handshake, is
  PSK-encrypted when a private network is configured.

## Dependencies & seams
- `P2PSecurity` → `P2PCore`. Noise/TLS depend on swift-crypto (+ swift-tls/P2PCertificate
  for TLS); Pnet uses `Crypto` (SHA-256 only) + NIO + Synchronization. See each
  submodule's CONTEXT for its specific invariants.

## Wire protocol notes
- Security protocol IDs negotiated via multistream-select: `/tls/1.0.0`, `/noise`,
  `/plaintext/2.0.0`. (Plaintext is test-only and must never ship in production.)

## Build
- Host: `swift build`. Tests: `swift test --filter Security` (with a timeout).

Last reviewed: 2026-06-25
