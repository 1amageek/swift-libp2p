# Discovery — CONTEXT
Scope/role: peer-discovery layer — protocol (`P2PDiscovery`) plus implementations (SWIM,
mDNS, CYCLON, Plumtree, Beacon, WiFiBeacon) and the peer/address stores. Read this before
changing the `DiscoveryService` contract, scoring, or ownership rules.

Discovery is observation-based: services collect `PeerObservation`s (announcement /
reachable / unreachable) and surface ranked `ScoredCandidate`s rather than dialing directly.
`P2PDiscovery` is protocol-only; concrete services live in sibling targets.
`DiscoveryPipeline` (the result-builder successor to CompositeDiscovery) composes several
services and owns their lifecycle.

## Contracts (the load-bearing rules)
- Self-exclusion is enforced by the protocol extension, not by each conformer:
  `DiscoveryService` requires `localPeerID` + `collectKnownPeers()` (raw, may include self),
  and the extension's `knownPeers()` filters out `localPeerID`. Implement `collectKnownPeers`;
  do not re-implement `knownPeers` (the cross-cutting filter must stay in one place).
- Concurrency: discovery services that talk to peers are `actor` (low-frequency,
  user-facing); high-frequency internal state (partial views, peer stores) is
  `class + Mutex`. `DiscoveryPipeline` is `final class + Mutex` (event forwarding only).
- Events: ALL discovery services use `EventBroadcaster<PeerObservation>` (multi-consumer:
  different consumers watch different peers via `subscribe(to: PeerID)`), declared
  `nonisolated let` and shut down in `deinit`. Do not use EventEmitting here.
- Lifecycle: every service implements `func shutdown() async throws` (it must stop async
  resources like transports/browsers, which `deinit` cannot `await`). `shutdown()` is
  idempotent.

## Invariants (must hold; tests guard them)
- **Ownership is single-claim.** `DiscoveryPipeline` claims each child service via
  `DiscoveryServiceOwnershipRegistry` (`ownerID`); a service instance may belong to only one
  pipeline, and post-claim direct access is caught by precondition. After handing a service
  to a pipeline, do not use it directly. `shutdown()` must be called (it stops children too).
- **No fabricated observations.** Services emit only observations they can actually justify
  (e.g. mDNS emits `.announcement`/`.reachable` only, never a synthesized `.unreachable`).
- `find()` runs services in parallel (TaskGroup) and tolerates partial failure (not
  fail-fast). Malformed inbound datagrams are logged at debug, never silently dropped.

## Dependencies & seams
- `P2PDiscovery` → `P2PCore`. mDNS → swift-mDNS facade; SWIM → swift-SWIM + NIOUDPTransport;
  Plumtree → `P2PPlumtree`; WiFiBeacon → `P2PDiscoveryBeacon`. Node integration via the
  `NodeDiscovery*` hooks (register/start/peer-stream lifecycle). Address ranking is injected
  via `AddressBook` (default `DefaultAddressBook`: transport-priority + success-history +
  half-life time decay); peer storage via `PeerStore` (default `MemoryPeerStore`, LRU
  ≤1000 peers, TTL GC).

## Build
- Host: `swift build`. Tests: `swift test --filter P2PDiscovery` (with a timeout).

Last reviewed: 2026-06-25
