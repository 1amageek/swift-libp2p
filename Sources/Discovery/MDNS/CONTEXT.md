# mDNS Discovery — CONTEXT
Scope/role: LAN peer discovery via mDNS (RFC 6762) / DNS-SD (RFC 6763)
(`P2PDiscoveryMDNS`). A `DiscoveryService` whose reach is limited to the same link.

`MDNSDiscovery` advertises and browses libp2p peers over Multicast DNS via the swift-mDNS
Tier-1 facade. It follows the Discovery-layer conventions (actor + EventBroadcaster +
async `shutdown`). The subtle part is that mDNS goodbyes do not give value-level
add/remove distinction, which constrains what observations may be emitted.

## Contracts (the load-bearing rules)
- `MDNSDiscovery` is an `actor` (low-frequency, user-facing), uses
  `EventBroadcaster<PeerObservation>` (Discovery-layer multi-consumer), and matches its
  sibling pattern (`SWIMMembership`/`CYCLONDiscovery`).
- PeerID inference order: `dnsaddr` (preferred) → `pk` → legacy service name. The design does
  NOT depend on the service instance name, so `peerNameStrategy = .random` (the default)
  still recovers the PeerID; `.peerID` is an opt-in compatibility mode.

## Invariants (must hold; tests guard them)
- **Upsert-only; never synthesize `.unreachable`.** The facade re-sends the last
  `MDNSService` value even on a goodbye (TTL 0), with no value-level way to tell add/update
  from remove. To avoid fabricating events the service emits only `.announcement`/`.reachable`
  and keeps `knownServicesByPeerID` as an upsert-only cache.
- `shutdown()` is idempotent: cancels the forwarding task, stops browser/responder, resets
  internal maps + `sequenceNumber`; `deinit` calls `broadcaster.shutdown()` (idempotent).
- A/AAAA fallback skips scope-less link-local IPv6 (`fe80::/10`) to avoid unusable
  candidates; `/ip6/...%zone/...` zone identifiers are preserved through parsing.

## Dependencies & seams
- swift-mDNS Tier-1 facade (`import MDNS`): `MDNSBrowser`/`MDNSResponder` (auto-start via
  `browse`/`advertise`), `MDNSService`/`MDNSDiscoveries`, `MDNSError`. `P2PCore` (PeerID,
  Multiaddr). `PeerIDServiceCodec` maps PeerID ↔ mDNS service using `dnsaddr=` TXT attributes
  (libp2p spec), with A/AAAA + port as a back-compat fallback.

## Wire protocol notes
- Service type `_p2p._udp`, query interval ~120s. libp2p mDNS spec: each multiaddr is a
  `dnsaddr=` TXT attribute (multiple allowed), p2p component auto-added; invalid multiaddrs
  skipped.

## Build
- Host: `swift build`. Tests: `swift test --filter MDNS` (with a timeout).

Last reviewed: 2026-06-25
