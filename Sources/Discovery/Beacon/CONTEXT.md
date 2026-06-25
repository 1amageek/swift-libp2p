# Beacon Discovery — CONTEXT
Scope/role: proximity-aware peer discovery over physical media (BLE, WiFi Direct, LoRa, NFC)
(`P2PDiscoveryBeacon`). A `DiscoveryService` facade over a layered beacon pipeline. Migrated
from the standalone `swift-p2p-discovery` repo and adapted to `P2PCore` types.

Beacon discovery ingests raw beacon sightings from a transport adapter, decodes them
(tiered formats), filters/coordinates scanning, and aggregates them into presence estimates
that become `P2PDiscovery.Observation`s. The pipeline is the structure; the load-bearing
parts are the anti-Sybil/anti-spoof defenses and the variable-length identity wire format.

## Contracts (the load-bearing rules)
- Pipeline layering: L0 Medium (`TransportAdapter` → `RawDiscovery`) → L1 Encoding
  (`BeaconEncoderService`, Tier1/2/3 beacons → `DecodedBeacon`) → L2 Coordination
  (`BeaconFilter`, `ScanCoordinator`, `TrickleTimer`) → L3 Aggregation
  (`AggregationIngest`, `BayesianPresence`, `BeaconPeerStore`) → `BeaconDiscovery` facade.
  The transport adapter is injected (`TransportAdapter` protocol).
- Concurrency: all types are `class + Mutex` (not actor); `BeaconDiscovery` uses
  `EventBroadcaster` (Discovery-layer multi-consumer) and `func shutdown() async`.
- Uses `P2PCore` types: `P2PCore.PeerID` (variable-length multihash, not fixed 32B),
  `P2PCore.KeyPair`, and `Envelope` + `BeaconPeerRecord` (a `SignedRecord`) for confirmed
  records. `BeaconObservation` is named to avoid collision with `P2PDiscovery.Observation`.

## Invariants (must hold; tests guard them)
- Anti-abuse defenses are integral: `MicroPoW` (SHA-256 proof-of-work), `MicroTESLA`
  (delayed-key-disclosure authentication), `PhysicalFingerprint` (Sybil detection),
  `BeaconFilter` (PoW + rate-limit + Sybil). Confirmed peer records are Envelope-signed.
- `BayesianPresence` uses Noisy-OR estimation; `FreshnessFunction` applies medium-specific
  decay; `TrickleTimer` is RFC 6206 adaptive interval. RSSI is smoothed (EMA) and trust is
  medium-specific.

## Dependencies & seams
- `P2PCore` (PeerID, KeyPair, Envelope, Multiaddr), `P2PDiscovery`. Physical media are
  plugged in via `TransportAdapter` implementations (e.g. `P2PDiscoveryWiFiBeacon`); peer
  storage via the `BeaconPeerStore` protocol (`InMemoryBeaconPeerStore` default).

## Wire protocol notes
- Tier 1: 10-byte minimal beacon; Tier 2: 32-byte TESLA beacon; Tier 3: variable-length full
  identity. Tier 3 format:
  `Tag(1B) + PeerIDLen(2B) + PeerID(var) + Nonce(4B) + EnvelopeLen(2B) + Envelope(var)`
  (length-prefixed variable PeerID + Envelope, replacing the old fixed 32-byte PeerID).

## Build
- Host: `swift build`. Tests: `swift test --filter Beacon` (with a timeout).

Last reviewed: 2026-06-25
