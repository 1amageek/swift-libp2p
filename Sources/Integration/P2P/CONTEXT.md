# P2P Integration — CONTEXT
Scope/role: the batteries-included integration layer (`P2P`). `import P2P` gives `Node` plus
default transport/security/mux and the connection/dial/traversal/resource machinery. Read
this before changing the upgrade pipeline, the resource manager, or the event-stream/idle
lifecycle.

`Node` is the user-facing composition root (an `actor`). It composes the stack from
`NodeConfiguration` (set once at init — there is no `use()`), upgrades connections via
multistream-select, manages a connection pool, orchestrates NAT traversal, and enforces
resource limits. The load-bearing parts are the upgrade ordering, fail-closed startup, and
the bounded resource accounting.

## Contracts (the load-bearing rules)
- Concurrency split: `Node` is an `actor` (low-frequency, user-facing API); `ConnectionPool`
  is an internal `class + Mutex` (high-frequency). Pool state lives behind a `Mutex`; never
  call async inside `withLock`.
- Configuration is complete at init time (`NodeConfiguration`); component runtime roles are
  declared by each component (`LifecycleService`/`StreamService`/`PeerObserver`/
  `DiscoveryService` + capability-consumer protocols), normalized by `NodeRuntime` — the DSL
  must not downcast at startup to guess "what kind of service this is".
- The upgrade pipeline is abstracted behind `ConnectionUpgrader` (`NegotiatingUpgrader` is
  the default); upgrade order is Security (multistream-select → `SecurityUpgrader.secure`)
  then Mux (multistream-select → `Muxer.multiplex`), priorities following the configuration
  array order. The initiator uses V1-Lazy negotiation (1 RTT saved).
- `ConnectionPool.connection(to:)` atomically retrieves the connection AND records activity
  in one `withLock` — no separate `recordActivity()`, no TOCTOU.

## Invariants (must hold; tests guard them)
- **Resource limits are enforced and fail-closed.** `DefaultResourceManager` enforces
  system/peer/protocol scopes; `ResourceTrackedStream` releases all THREE scopes (system +
  peer + protocol) when a `negotiatedProtocolID` is set. There is no silent "unlimited"
  default. (Production-validation rejection of plaintext / disabled resource manager lives in
  P2PProtocols; this layer wires the enforcement.)
- **Negotiation remainder is preserved**: `Node.newStream` / inbound handlers carry
  multistream-select pre-read bytes via `BufferedStreamReader.drainRemainder()` +
  `BufferedMuxedStream` so application head bytes are never lost.
- **Discovery startup failure is propagated, not swallowed** — it surfaces as a
  `Node.start()` failure.
- Bounded reads in the upgrade/negotiation path: `BufferedStreamReader` caps at 64KB with
  proper `VarintError` handling; `ConnectionUpgrader` checks `buffer.count > maxMessageSize`
  before reading.
- Event stream is lazy + reset on shutdown: `Node.events` is created on first access and
  reused; `emit` only yields if a continuation exists (pre-subscription events are NOT
  retained); `shutdown()` finishes the continuation and resets it (a post-shutdown `events`
  access returns an immediately-finished stream).
- Idle/trim task (every `idleTimeout/2`): closes idle connections, trims from highWatermark
  to lowWatermark (emitting `trimmedWithContext` + `trimConstrained` when under-trimmed),
  cleans stale entries. Reconnection respects the policy (no reconnect on
  localClose/gated/limitExceeded).

## Dependencies & seams
- `@_exported`: `P2PCore`, `P2PTransport`, `P2PSecurity`, `P2PMux`, `P2PNegotiation`,
  `P2PDiscovery`, `P2PProtocols`, default impls (`P2PTransportTCP`, `P2PSecurityNoise`,
  `P2PSecurityPlaintext`, `P2PMuxYamux`, `P2PPing`, `P2PGossipSub`), `NIOCore`. Traversal
  pulls in `P2PAutoNAT`/`P2PCircuitRelay`/`P2PDCUtR`/`P2PNAT`. App protocols (Kademlia,
  Plumtree, Rendezvous, …) are imported separately. Default stores: `MemoryPeerStore`,
  `DefaultAddressBook`, `AllowAllGater`.
- Traversal: `TraversalCoordinator` (Class+Mutex, EventEmitting) runs mechanisms
  (LocalDirect → Direct → HolePunch[AutoNAT+DCUtR] → Relay) ordered by `TraversalPolicy`;
  first success wins and in-flight attempts are cancelled. Relayed connections are flagged
  `isLimited` in the pool.

## Build
- Host: `swift build`. Tests: `swift test --filter P2PTests` / `NodeE2ETests` (with a
  timeout).

Last reviewed: 2026-06-25
