# SWIM Discovery — CONTEXT
Scope/role: cluster membership + failure detection via SWIM (`P2PDiscoverySWIM`). A
`DiscoveryService` that runs SWIM over UDP and gossips member alive/suspect/dead status.

`SWIMMembership` drives the swift-SWIM engine over a NIO UDP transport and translates SWIM
status transitions into `PeerObservation`s. It follows the Discovery-layer conventions
(actor + EventBroadcaster + async `shutdown`). The membership model differs from other
discovery services: you join a cluster, you don't merely announce.

## Contracts (the load-bearing rules)
- `SWIMMembership` is an `actor`, uses `EventBroadcaster<PeerObservation>`, and matches its
  sibling pattern (`MDNSDiscovery`/`CYCLONDiscovery`).
- `announce(addresses:)` does NOT change cluster membership — it only records the local
  address. Cluster membership is via `join(seeds:)` / `leave()`. SWIM-specific operations
  (`join`/`leave`/`members`/`aliveCount`) are outside the `DiscoveryService` requirements and
  are guarded by `DiscoveryServiceOwnershipRegistry.preconditionAccessible` once the service
  is handed to a pipeline.

## Invariants (must hold; tests guard them)
- **Advertised host must be routable.** `0.0.0.0` / `::` are bind-only and rejected for
  advertising; `resolveAdvertisedHost()` validates (auto-detects when `advertisedHost` is nil).
- `shutdown()` is ordered and idempotent: cancel forwarding task → `swim.leave()` →
  `swim.shutdown()` → `transport.shutdown()` → reset state → `broadcaster.shutdown()`;
  `deinit` calls `broadcaster.shutdown()`.
- Malformed datagrams / missing sender address are logged at debug, never silently skipped.

## Dependencies & seams
- swift-SWIM: `import SWIM` for the `SWIMCluster` engine (init shape +
  `start/shutdown/join/leave/members/aliveCount/events` API; renamed from `SWIMInstance`),
  `Member`/`MemberID`/`SWIMConfiguration`; `import SWIMWire` for the Tier-3 `SWIMMessageCodec`
  (used by the transport adapter); `import NIOUDPTransport`. `SWIMTransportAdapter` adapts
  `NIOUDPTransport` to SWIM's `SWIMTransport`; `SWIMBridge` converts PeerID/Multiaddr ↔
  SWIM `MemberID`.

## Wire protocol notes
- SWIM over UDP. Defaults: `port` 7946, `bindHost` `0.0.0.0`.

## Build
- Host: `swift build`. Tests: `swift test --filter SWIM` (with a timeout).

Last reviewed: 2026-06-25
