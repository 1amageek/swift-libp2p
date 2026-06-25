# Noise — CONTEXT
Scope/role: libp2p Noise XX (`P2PSecurityNoise`). `Noise_XX_25519_ChaChaPoly_SHA256` mutual
authentication and the encrypted transport that follows. Read this before changing the
handshake, the crypto state, or the identity signature.

Since the 2026-06 Embedded migration the Noise XX state machine lives in the Embedded-clean
`LibP2PCore`, generic over the `P2PCoreCrypto.CryptoProvider` seam. This module is the HOST
ADAPTER: it specializes the core at `C = NoiseFoundationProvider` (swift-crypto backend) and
keeps the `Data`/NIO/`Mutex` surface so existing callers stay byte-identical. The security
invariants below are the load-bearing part — they must hold byte-for-byte across host and
Embedded.

## Contracts (the load-bearing rules)
- The core (`NoiseCipherStateCore`/`NoiseSymmetricStateCore`/`NoiseHandshakeCore`/
  `NoiseKeyAgreementCore`, error `NoiseCryptoError`) is generic and Embedded-clean. The
  adapter (`NoiseFoundationProvider` + the `Data`-bridging `NoiseCipherState`/
  `NoiseSymmetricState`/`NoiseHandshake`) wraps it. Do not push Foundation/`Data`/`Mutex`
  into the core, and keep adapter behavior byte-identical to the core.
- The identity signature stays adapter-side: `NoisePayload` builds/verifies the
  `"noise-libp2p-static-key:" || static_pubkey` signature via the multi-scheme `P2PCore`
  identity key (Ed25519 raw + ECDSA-P256 DER). The core returns the decrypted payload +
  remote static key that the adapter binds the signature to.
- Concurrency: `NoiseConnection` uses separate `Mutex<SendState>` + `Mutex<RecvState>` so
  full-duplex read/write run without lock contention. `NoiseHandshake` is `struct: Sendable`.

## Invariants (must hold; tests guard them, preserved byte-identically host vs Embedded)
- **Identity signature verification is fail-closed** (`NoiseError.invalidSignature`); an
  unverified peer is never surfaced. The PeerID is derived from the verified identity key.
- **`expectedPeer` is enforced**: a mismatch throws `NoiseError.peerMismatch`; a bad
  signature throws `NoiseError.invalidSignature`.
- **X25519 small-order rejection**: small-order public keys (8 known points) and an all-zero
  shared secret are rejected — CryptoKit does not reject these and would yield a degenerate
  shared secret. Do not remove this check.
- **Per-message nonce, never reused.** 64-bit counter incremented per encrypt/decrypt;
  reaching `UInt64.max` throws `NoiseError.nonceOverflow` (connection must be closed/rekeyed).
- **Empty-payload EncryptAndHash is mandatory in Message A.** `WriteMessage` always calls
  `EncryptAndHash`, even on an empty payload, so `mixHash(empty)` runs and the handshake hash
  advances (`SHA256(h || empty) ≠ h`). Required for go/rust-libp2p interop — do not skip it.
- AEAD tag handling is fail-closed; the handshake-hash binding is preserved. No silent
  fallback anywhere.

## Embedded constraints (do not regress)
- The state machine is gated into `LibP2PCore` and must stay free of Foundation, `any`
  existentials, `Mutex`, and swift-crypto. Crypto comes through the injected
  `CryptoProvider` seam (`NoiseFoundationProvider` on host). HKDF is a custom RFC-5869
  HMAC-SHA256 expand (not swift-crypto's HKDF type) for exact libp2p-Noise output control.

## Dependencies & seams
- `P2PSecurity` (SecurityUpgrader), `P2PCore` (KeyPair, PeerID, PublicKey, Varint),
  swift-crypto (host AEAD/hash/HKDF/HMAC + X25519/P256/P384 + Ed25519/P256/P384 signatures).
- `SecuredConnection` is defined in `P2PCore`.

## Wire protocol notes
- Protocol ID `/noise`; cipher suite `Noise_XX_25519_ChaChaPoly_SHA256`. Prologue is empty
  (multistream-select is a separate layer). XX: `-> e` / `<- e, ee, s, es` / `-> s, se`.
  Transport frames: 2-byte BE length + ChaCha20-Poly1305 ciphertext; max frame 65535,
  16-byte tag, max plaintext 65519. Nonce = 4 zero bytes + 8-byte LE counter. Note the Noise
  static key (X25519) is distinct from the libp2p identity key.

## Build
- Host: `swift build`. Tests: `swift test --filter Noise` (with a timeout).

Last reviewed: 2026-06-25
