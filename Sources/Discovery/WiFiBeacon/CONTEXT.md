# WiFiBeacon — CONTEXT
Scope/role: WiFi beacon transport adapter (`P2PDiscoveryWiFiBeacon`). The reference
`TransportAdapter` for Beacon discovery: sends/receives beacon payloads over UDP multicast
on the LAN. No OS-specific radio APIs (CoreBluetooth/MultipeerConnectivity) — NIO UDP only.

`WiFiBeaconAdapter` conforms to `P2PDiscoveryBeacon.TransportAdapter` and carries beacon
payloads in a small framed UDP-multicast packet. It exists to exercise the beacon pipeline
without OS-specific hardware.

## Contracts (the load-bearing rules)
- Concurrency: `class + Mutex` (Transport-layer convention). `discoveries` is single-consumer
  (EventEmitting); `shutdown() async` finishes the continuation and clears the stream.

## Invariants (must hold; tests guard them)
- Frame magic `0x50 0x32` ("P2") lets non-P2P traffic be rejected immediately. Max payload
  512B (`MediumCharacteristics.wifiDirect`); total 8B header + 512B = 520B stays within MTU.
- Defaults: multicast group `239.2.0.1` (RFC 2365 Organization-Local Scope), port `9876`
  (IANA-unregistered), transmit interval 5s (matches BeaconDiscovery's default
  `beaconRateLimit`), loopback off (own-beacon receipt is unnecessary outside tests).

## Dependencies & seams
- `P2PDiscoveryBeacon` (`TransportAdapter`, `RawDiscovery`, `OpaqueAddress`), `P2PCore`
  (PeerID, Multiaddr), `NIOUDPTransport` (UDP multicast).

## Wire protocol notes
- `WiFiBeaconFrame`: `Magic "P2"(2B) | Version(1B) | Flags(1B) | PayloadLen(2B) |
  Reserved(2B) | Payload(NB)`.

## Build
- Host: `swift build`. Tests: `swift test --filter WiFiBeacon` (with a timeout).

Last reviewed: 2026-06-25
