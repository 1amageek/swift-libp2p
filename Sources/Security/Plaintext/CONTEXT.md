# Plaintext — CONTEXT
Scope/role: plaintext security (`P2PSecurityPlaintext`). Exchanges public keys and verifies
PeerID with NO encryption. TEST ONLY — never use in production.

`PlaintextUpgrader` runs the libp2p plaintext/2.0.0 Exchange handshake and returns a
`PlaintextConnection` that delegates read/write straight to the underlying connection. Its
value is fast, deterministic test setup; it provides no confidentiality or integrity.

## Contracts (the load-bearing rules)
- TEST ONLY: no encryption means eavesdropping/tampering are possible. The `P2P` umbrella
  does not `@_exported` this module, and production validation rejects it.
- `readLengthPrefixedMessage()` handles TCP stream semantics (full varint length prefix,
  wait for the whole message, return surplus as `remainder`); the remainder becomes the
  `PlaintextConnection.initialBuffer`, served before reading from the underlying connection.

## Invariants (must hold; tests guard them)
- **PeerID is verified.** The PeerID derived from the exchanged public key must match the
  claimed PeerID (`peerIDMismatch`) and, when set, `expectedPeer`
  (`SecurityError.peerMismatch`). Missing required fields → `invalidExchange`.
- The handshake length prefix is bounded by `maxPlaintextHandshakeSize` (64KB); over-limit
  fails fast with `messageTooLarge` (no unbounded handshake read). `PlaintextError` is
  wrapped in `SecurityError.handshakeFailed(underlying:)`.

## Dependencies & seams
- `P2PSecurity` (SecurityUpgrader). `SecuredConnection` is defined in `P2PCore`.

## Wire protocol notes
- Protocol ID `/plaintext/2.0.0`. Length-prefixed (varint) protobuf
  `Exchange { bytes id = 1; bytes pubkey = 2; }`; both sides send then read. Note: the
  upgrader sends its local exchange before reading regardless of role (full-duplex).

## Build
- Host: `swift build`. Tests: `swift test --filter Plaintext` (with a timeout).

Last reviewed: 2026-06-25
