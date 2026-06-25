# Identify — CONTEXT
Scope/role: libp2p Identify + Identify Push (`P2PIdentify`). Exchanges peer public key,
listen addresses, supported protocols, and observed address. Read this before changing
signed-peer-record verification or the cache.

Identify learns a peer's identity and capabilities on connect and broadcasts updates via
Push. The security-relevant part is signed-peer-record verification; the operational part
is a bounded TTL/LRU cache with explicit maintenance.

## Contracts (the load-bearing rules)
- Background cache cleanup is opt-in: `startMaintenance()` must be called explicitly;
  `shutdown()` stops maintenance and finishes the event stream.
- Reads are bounded — the message reader throws `messageTooLarge` past the 64KB limit
  rather than silently truncating. Do not reintroduce silent truncation.

## Invariants (must hold; tests guard them)
- **Signed peer records (field 8) are verified when present.**
  `verifySignedPeerRecord()` checks the Envelope signature and requires the PeerID to
  match across three places: the record's PeerID, the envelope signer, and the expected
  peer. A mismatch fails verification.
- Cache eviction is deterministic: expired entries first, then LRU. `cachedInfo(for:)`
  returns `nil` for expired entries; `allCachedInfo` filters expired.

## Dependencies & seams
- `P2PCore` (PeerID, PublicKey, Multiaddr, Envelope), `P2PMux` (MuxedStream),
  `P2PProtocols` (ProtocolService).
- Listen addresses and supported protocols are supplied by injected closures at
  handler registration (`getListenAddresses`, `getSupportedProtocols`).

## Wire protocol notes
- Protocol IDs: `/ipfs/id/1.0.0` (query), `/ipfs/id/push/1.0.0` (push).
- Protobuf `Identify`: `publicKey`(1), `listenAddrs`(2), `protocols`(3),
  `observedAddr`(4), `protocolVersion`(5), `agentVersion`(6), `signedPeerRecord`(8)
  — field 7 is skipped. Query opens a stream and reads one Identify message; Push pushes
  one message on a fresh stream.

## Build
- Host: `swift build`. Tests: `swift test --filter Identify` (with a timeout).

Last reviewed: 2026-06-25
