# P2PNAT — CONTEXT
Scope/role: NAT port-mapping service (`P2PNAT`). UPnP IGD + NAT-PMP support for opening
inbound ports, integrated with AutoNAT/Traversal. Read this before changing the
handler-fallback order or the cross-platform socket abstractions.

`NATPortMapper` is the facade (EventEmitting) that discovers a gateway and requests port
mappings through a `NATProtocolHandler` (UPnP first, then NAT-PMP). The cross-platform
plumbing (gateway detection, local IP, UDP sockets) is the fiddly part.

## Contracts (the load-bearing rules)
- `NATPortMapper` conforms to `EventEmitting`; one responsibility per file. Handlers are
  tried in order — UPnP IGD → NAT-PMP — as the fallback chain.
- `UDPSocket` is `~Copyable` RAII (closes the fd on deinit); shared helpers
  (`UDPSocket`, `extractXMLTagValue`) deduplicate UPnP/NAT-PMP code.

## Invariants (must hold; tests guard them)
- Mappings auto-renew before expiry.
- Cross-platform behavior is explicit (no silent platform divergence): gateway detection via
  `NWPath.gateways` on Apple and `/proc/net/route` on Linux; UDP sockets are POSIX
  everywhere with Darwin/Glibc type differences bridged by `#if`. On iOS, NAT-PMP/PCP is
  unavailable (no public gateway-IP API) and the mapper falls back to UPnP (SSDP multicast).
- Known limits (documented, not bugs): `shutdown()` does NOT release gateway mappings (they
  expire by lease); the gateway cache has no TTL (recreate the instance on network change).

## Dependencies & seams
- `P2PCore`. Network framework (Apple) / POSIX. Pluggable `NATProtocolHandler` (UPnP,
  NAT-PMP).

## Wire protocol notes
- UPnP IGD: SSDP discovery (UDP multicast 239.255.255.250:1900) → HTTP device description →
  SOAP AddPortMapping. NAT-PMP (RFC 6886): gateway = default gateway IP; external address via
  Opcode 0; port mapping via Opcode 1 (UDP) / 2 (TCP).

## Build
- Host: `swift build`. Tests: `swift test --filter P2PNAT` (with a timeout). Unit tests are
  limited to non-network-I/O cases.

Last reviewed: 2026-06-25
