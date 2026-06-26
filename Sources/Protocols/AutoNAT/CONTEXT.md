# AutoNAT — CONTEXT
Scope/role: AutoNAT v1 + v2 (`P2PAutoNAT`). Detects whether a node is publicly reachable by
asking peers to dial it back. Read this before changing dial-back, rate limiting, or
amplification defenses.

A node asks several peers to dial its addresses; consistent success means public,
consistent failure means behind-NAT. The dangerous surface is the server side: dial-back
is an amplification vector, so the server is heavily rate-limited and address-validated.

## Contracts (the load-bearing rules)
- v1 (`AutoNATService`) combines client and server. v2 server handling is centralized in
  `AutoNATv2Service.handleIncomingStream(context:dialer:)` and is EventEmitting
  (single-consumer); do not add a separate server-side handler path.
- The server dialer is injected (`dialer` closure); local addresses come from a
  `getLocalAddresses` closure. Do not hard-wire the swarm into the service.

## Invariants (must hold; tests guard them)
- **Amplification defenses are mandatory on the server.** It only dials addresses whose IP
  matches the requesting client's observed IP, rate-limits dial-back per peer and globally,
  and may require a peer-ID match (`requirePeerIDMatch`, default true). Bounds:
  `maxRequestsPerPeer`/`rateLimitWindow`, `maxConcurrentDialsPerPeer`,
  `maxConcurrentDialsGlobal`, `maxGlobalRequests`, `rateLimitBackoff`, optional
  `allowedPortRange`. Rejections surface `dialRequestRejected`; never silently dial.
- **v2 uses nonce-based verification**: the server proves it actually connected by echoing
  a per-request nonce over the dial-back stream. Expired nonces are cleaned up; per-server
  cooldown (default 30s) prevents amplification.
- IPv6 normalization strips zone identifiers, validates characters, and rejects multiple
  `::` (a malformed-address acceptance bug otherwise).
- NAT status determination requires ≥ `minProbes` (default 3) consistent responses;
  confidence grows with agreement. `NATStatus` is `unknown` / `publicReachable(addr)` /
  `privateBehindNAT`.

## Dependencies & seams
- `P2PCore` (PeerID, Multiaddr, Varint), `P2PMux` (MuxedStream), `P2PProtocols`.
- Integrates with Circuit Relay + DCUtR: `privateBehindNAT` triggers relay reservation and
  DCUtR hole punching.

## Wire protocol notes
- v1: `/libp2p/autonat/1.0.0`. Protobuf `Message` with DIAL/DIAL_RESPONSE; DialResponse
  status OK(0)/E_DIAL_ERROR(100)/E_DIAL_REFUSED(101)/E_BAD_REQUEST(200)/E_INTERNAL_ERROR(300).
- v2: `/libp2p/autonat/2/dial-request` + `/libp2p/autonat/2/dial-back`. DialRequest carries
  `address` + `fixed64 nonce` (8-byte LE); DialBack echoes the nonce.

## Build
- Host: `swift build`. Tests: `swift test --filter AutoNAT` (with a timeout).

Last reviewed: 2026-06-25
