# Plumtree — CONTEXT
Scope/role: Epidemic Broadcast Trees (`P2PPlumtree`). Efficient message dissemination that
combines eager push (tree links) with lazy push (gossip links) for tree repair.

Full messages flow over the eager set (a spanning tree); IHave notifications flow over the
lazy set so missing messages can be repaired by GRAFT. Duplicates trigger PRUNE, moving a
peer from eager to lazy. Routing is high-frequency, so everything is `class + Mutex`.

## Contracts (the load-bearing rules)
- `PlumtreeRouter`, `LazyPushBuffer`, and `PlumtreeService` are all `final class + Mutex`
  (high-frequency routing). Keep this pattern across the module.
- `PlumtreeService` uses `EventBroadcaster` (multi-consumer Pub/Sub): a separate
  `eventBroadcaster` (protocol events) and `messageBroadcaster` (per-topic message
  delivery). `shutdown() async` shuts down both. Do not switch to EventEmitting.

## Invariants (must hold; tests guard them)
- Dedup is fundamental: an unseen GOSSIP is delivered + forwarded to eager peers (excluding
  source) + IHave'd to lazy peers (excluding source), and any pending IHave timer for that
  message is cancelled; a duplicate GOSSIP triggers PRUNE back to the source.
- IHAVE for a not-yet-received message starts an `ihaveTimeout` timer; on timeout it sends
  GRAFT (promoting the peer to eager). GRAFT promotes the peer to eager and re-sends the
  requested message if available; PRUNE demotes to lazy.

## Dependencies & seams
- `P2PProtocols` (ProtocolService, StreamOpener, HandlerRegistry), `P2PCore`
  (PeerID, Multiaddr, Varint, EventBroadcaster), `P2PMux` (MuxedStream).

## Wire protocol notes
- Protocol ID `/plumtree/1.0.0`. Hand-written protobuf (same pattern as GossipSub).
  Note: this `Protocols/Plumtree` is the libp2p stream protocol; `Discovery/Plumtree` is
  the discovery-layer variant.

## Build
- Host: `swift build`. Tests: `swift test --filter Plumtree` (with a timeout).

Last reviewed: 2026-06-25
