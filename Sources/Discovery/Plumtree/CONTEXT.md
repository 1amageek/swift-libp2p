# Plumtree Discovery — CONTEXT
Scope/role: discovery over Plumtree gossip (`P2PDiscoveryPlumtree`). Distributes
self-announcements via Plumtree and converts received announcements into discovery
candidates. (Distinct from `Protocols/Plumtree`, which is the stream protocol itself.)

`PlumtreeDiscovery` publishes the local node's announcement on a Plumtree topic and turns
inbound announcements into observations / `ScoredCandidate`s used by `find(peer:)` /
`knownPeers()`. It follows the Discovery-layer conventions.

## Contracts (the load-bearing rules)
- `PlumtreeDiscovery` is an `actor` conforming to `DiscoveryService`, integrated via
  `NodeDiscoveryHandlerRegistrable` / `NodeDiscoveryStartable` /
  `NodeDiscoveryPeerStreamService`. `start()` subscribes the topic before `announce()` can
  publish; `handlePeerConnected`/`handlePeerDisconnected` track peer lifecycle.

## Invariants (must hold; tests guard them)
- Announcement payloads are self-asserted (NO cryptographic signature). The only integrity
  check is that the announced `peerID` matches the gossip source peer. When
  `requireAddresses = true`, at least one valid Multiaddr is required, else the announcement
  is rejected. Do not treat announcements as authenticated.

## Dependencies & seams
- `P2PDiscovery` (DiscoveryService), `P2PPlumtree` (gossip), `P2PCore`. The gossip wire
  payload (`PlumtreeDiscoveryAnnouncement`) is JSON.

## Build
- Host: `swift build`. Tests: `swift test --filter PlumtreeDiscovery` (with a timeout).

Last reviewed: 2026-06-25
