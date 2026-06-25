# Kademlia — CONTEXT
Scope/role: Kademlia DHT (`P2PKademlia`). Peer routing, value records, and provider
discovery, with optional S/Kademlia hardening. Read this before changing key handling,
the query state machine, or record validation.

Kademlia provides peer routing, value storage, and provider discovery over a 256-bucket
routing table keyed by XOR distance on SHA-256. Queries are iterative and parallel
(ALPHA). The security-relevant surface is input validation (malformed keys must not
crash), record validation, and the S/Kademlia anti-Sybil/anti-Eclipse extensions.

## Contracts (the load-bearing rules)
- Keys are 256-bit; bucket index = leading-zero count of `XOR(SHA256(a), SHA256(b))`.
  Construct keys via `KademliaKey(validating:)` — it throws `invalidLength` for non-32-byte
  input. Never construct a key from unchecked remote bytes (a force/precondition path is a
  remote crash vector).
- Background TTL/republish maintenance is opt-in: `startMaintenance()` /
  `startRepublish()` must be called explicitly; nothing runs them implicitly.
- The query state machine drives routing-table updates via the `QueryDelegate` callback;
  responses auto-update the table. Keep this seam — do not mutate the table inline in
  network code.

## Invariants (must hold; tests guard them)
- **Malformed-key requests are rejected, not crashed.** FIND_NODE with a non-32-byte key
  is rejected; GET_VALUE/GET_PROVIDERS accept arbitrary key lengths by design.
- **Per-peer send/receive has a timeout** (`peerTimeout`, 10s default) with guaranteed
  stream cleanup on timeout; query-level timeout is enforced via TaskGroup race. Do not
  reintroduce unbounded reads.
- **Client mode refuses inbound queries** (go/rust-compatible) and does not advertise
  protocol support.
- **Record selection is validator-driven.** GET_VALUE collects multiple records and picks
  via `RecordValidator.select(key:records:)`; the default validator verifies IPNS and
  public-key record signatures. `SignedRecordValidator` selects newest by timestamp.
- S/Kademlia (`.secure` config): node-ID cryptographic verification
  (`SKademliaValidator.validateNodeID`) prevents attacker-chosen IDs; Sibling Broadcast
  diversifies query candidates across buckets (Eclipse resistance); Disjoint Paths runs
  independent parallel lookups and merges results (single-malicious-node resistance).
- File-backed storage persists timestamps as wall-clock `Date`, NOT
  `ContinuousClock.Instant` (monotonic/process-specific values are invalid after restart);
  converted to monotonic on load.

## Dependencies & seams
- `P2PCore` (PeerID, Multiaddr, Varint), `P2PMux` (MuxedStream), `P2PProtocols`.
- Storage backends are injected via `RecordStorage` / `ProviderStorage` protocols
  (in-memory default; `FileRecordStorage`/`FileProviderStorage` for persistence).
- Record validation injected via `RecordValidator` (`NamespacedValidator`,
  `CompositeValidator`, `SignedRecordValidator`).

## Wire protocol notes
- Protocol ID `/ipfs/kad/1.0.0`. Constants: K=20 (replication / bucket size), ALPHA=3
  (query parallelism, dynamically adjustable via `enableDynamicAlpha`).
- Protobuf `Message` types: PUT_VALUE(0), GET_VALUE(1), ADD_PROVIDER(2),
  GET_PROVIDERS(3), FIND_NODE(4); PING(5) deprecated. Carries `record`, `closerPeers`,
  `providerPeers`, and `key` (field 10).
- go-libp2p DHT wire round-trips (FIND_NODE/PUT_VALUE/GET_VALUE/GET_PROVIDERS) verified;
  rust ongoing.

## Build
- Host: `swift build`. Tests: `swift test --filter Kademlia` (with a timeout).

Last reviewed: 2026-06-25
