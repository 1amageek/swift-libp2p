# CYCLON Discovery — CONTEXT
Scope/role: CYCLON random peer sampling (`P2PDiscoveryCYCLON`). Each node keeps a partial
view and periodically shuffles entries with a random peer to randomize overlay topology.

A `DiscoveryService` that maintains a bounded partial view and exchanges it with peers to
keep the overlay well-mixed. It follows the Discovery-layer conventions.

## Contracts (the load-bearing rules)
- `CYCLONDiscovery` is an `actor` (low-frequency shuffle), uses
  `EventBroadcaster<PeerObservation>` (Discovery-layer multi-consumer), and matches its
  sibling pattern (`SWIMMembership`). The high-frequency partial view
  (`CYCLONPartialView`) is `final class + Mutex`.
- Node integration via `NodeDiscoveryHandlerRegistrable` +
  `NodeDiscoveryStartableWithOpener`; streams exchanged through an injected `StreamOpener`.

## Invariants (must hold; tests guard them)
- The partial view is bounded; shuffle exchanges and eviction keep it within its size limit.

## Dependencies & seams
- `P2PDiscovery` (DiscoveryService), `P2PCore`. Streams via `StreamOpener`.

## Wire protocol notes
- Protocol ID `/cyclon/1.0.0`. Hand-written protobuf, length-prefixed messages.

## Build
- Host: `swift build`. Tests: `swift test --filter CYCLON` (with a timeout).

Last reviewed: 2026-06-25
