# Pnet — CONTEXT
Scope/role: Private Network (`P2PSecurityPnet`). PSK + XSalsa20 stream cipher encrypts ALL
connection traffic so only nodes sharing the PSK can communicate. go-libp2p compatible.
Read this before changing the cipher, nonce exchange, or where pnet sits in the stack.

`PnetProtector.protect()` wraps a `RawConnection` BELOW the SecurityUpgrader: it exchanges
nonces, then XSalsa20-encrypts everything (including the subsequent Noise/TLS handshake). A
node without the matching PSK cannot complete the nonce/cipher exchange.

## Contracts (the load-bearing rules)
- pnet is a layer below SecurityUpgrader — not a `SecurityUpgrader` itself. Connection flow:
  `RawConnection → PnetProtector.protect() → (pnet-encrypted) → multistream-select →
  SecurityUpgrader.secure()`. All traffic, including the security handshake, is PSK-encrypted.
- Concurrency: `PnetConnection` uses separate `Mutex<PnetSendState>` + `Mutex<PnetRecvState>`
  (same full-duplex pattern as Noise). `XSalsa20` is a `struct: Sendable` value type with a
  `mutating` counter; `PnetProtector` is immutable/`Sendable` (holds PSK + fingerprint only).

## Invariants (must hold; tests guard them)
- A configured PSK is applied on both dial and listen and fails closed if it cannot be
  applied — there is NO unprotected fallback.
- XSalsa20 = HSalsa20(key, nonce[0..16]) → 32-byte subkey, then Salsa20(subkey,
  nonce[16..24]) keystream; Salsa20 core is 20 rounds; 64-bit block counter incremented per
  64-byte block. Send cipher keys off the local nonce, read cipher off the remote nonce —
  do not cross them (directional correctness).

## Dependencies & seams
- `P2PCore` (RawConnection, Multiaddr), `Crypto` (SHA-256 only, for the PSK fingerprint),
  `NIOCore` (ByteBuffer), `Synchronization` (Mutex). The Salsa20/XSalsa20 cipher is pure
  Swift (not swift-crypto).

## Wire protocol notes
- PSK file (go-libp2p compatible): `/key/swarm/psk/1.0.0/` + `/base16/` + 64 hex chars
  (32-byte PSK). Handshake: each side sends a 24-byte nonce, reads the peer's 24-byte nonce,
  then all data is XSalsa20-encrypted.

## Build
- Host: `swift build`. Tests: `swift test --filter Pnet` (with a timeout).

Last reviewed: 2026-06-25
