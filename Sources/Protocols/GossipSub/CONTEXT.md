# GossipSub — CONTEXT
Scope/role: libp2p Pub/Sub (`P2PGossipSub`). Topic-based mesh pub/sub with gossip, peer scoring, and Sybil/spam defenses. Read this before changing the router, scorer, or RPC bounds.

GossipSub extends FloodSub with a per-topic mesh plus lazy gossip. The router is a
`class + Mutex`, not an actor, because message routing is a very high-frequency path
where actor serialization would dominate; lock scope is kept minimal so independent
publish/subscribe/mesh operations run concurrently. Treat the router as the load-bearing
state machine — security checks live there, not in the public service.

## Contracts (the load-bearing rules)
- `GossipSubRouter` is `class + Mutex`. Never collect-and-emit events while holding a
  lock; collect under the lock, emit after releasing it (the broadcaster has its own lock).
- The inbound stream-reading Task is intentionally NOT tracked by `GossipSubService`. It is
  bound to the connection lifetime: `Node.shutdown()` → `swarm.shutdown()` → connection
  close → `stream.read()` throws → loop ends → `handlePeerDisconnected()` cleans up. Do not
  add Task tracking; connection lifetime == Task lifetime.
- Events use `EventBroadcaster` (multi-consumer Pub/Sub pattern). Do not convert this
  module to `EventEmitting`.

## Invariants (must hold; tests guard them)
- **Message signature verification is on by default and fail-closed.** Default
  `strictSignatureVerification = true`; unsigned/spoofed messages are rejected.
  Pre-2020 unsigned-message legacy interop is intentionally unsupported. Never default
  this to `false`.
- **Validate before inserting into the seen-cache.** A message is validated first; only
  valid messages enter dedup state. Do not cache-then-validate (that lets invalid messages
  suppress valid retransmits).
- **Signed peer-exchange records are verified.** PRUNE Peer Exchange entries must pass
  signed-record verification before use.
- **Control traffic is bounded** to resist amplification/DoS: IHAVE/IWANT/GRAFT/PRUNE/
  IDONTWANT counts and the per-peer IDONTWANT set (`maxDontWantEntries = 10_000`) are
  capped. Publish enforces `maxMessageSize`; RPC size is capped (max 5MB) with overflow
  protection. Do not remove these bounds.
- **MessageID uses SHA-256** (a cryptographic hash), never Swift `Hasher`.
- Peer scoring (global + per-topic P1–P4/P3b) drives graylisting and mesh peer selection
  via `computeScore(for:)`; IP-colocation tracking is a Sybil defense. `isGraylisted()` /
  `sortByScore()` must use `computeScore(for:)` (global + per-topic), not global-only.

## Dependencies & seams
- `P2PCore` (PeerID, Multiaddr), `P2PMux` (MuxedStream), `P2PProtocols`
  (ProtocolService, StreamOpener, HandlerRegistry).
- Tracing is injected via the `GossipSubTracer` protocol (`JSONTracer` is one impl).

## Wire protocol notes
- Protocol IDs: `/meshsub/1.1.0` (v1.1), `/meshsub/1.2.0` (v1.2, adds IDONTWANT control
  field 5), `/floodsub/1.0.0` (FloodSub back-compat).
- Hand-written protobuf RPC: `subscriptions` (SubOpts), `publish` (Message), `control`
  (IHAVE/IWANT/GRAFT/PRUNE/IDONTWANT). PRUNE carries v1.1 Peer Exchange peers + backoff.
- Heartbeat interval default 1s: mesh maintenance (GRAFT to reach D, PRUNE above D_high),
  fanout cleanup, gossip emission (IHAVE to D_lazy non-mesh peers). Default mesh params:
  D=6, D_low=4, D_high=12, D_lazy=6, D_out=2, seen_ttl=2m, fanout_ttl=60s, mcache_len=5.
- go-libp2p single-node wire interop (control/publish round-trip) verified; rust ongoing.

## Build
- Host: `swift build`. Tests: `swift test --filter GossipSub` (with a timeout).

Last reviewed: 2026-06-25
