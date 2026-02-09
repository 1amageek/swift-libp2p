# P2PDiscoveryBeacon Module

## Purpose

Beacon-based peer discovery for proximity-aware networking over physical media
(BLE, WiFi Direct, LoRa, NFC). Migrated from the standalone `swift-p2p-discovery`
repository and adapted to use `P2PCore` types (`PeerID`, `KeyPair`, `Envelope`,
`Multiaddr`).

## Architecture

The module follows a layered pipeline:

```
L0 Medium (TransportAdapter)
    |
    v  RawDiscovery
L1 Encoding (BeaconEncoderService, Tier1/2/3Beacon)
    |
    v  DecodedBeacon
L2 Coordination (BeaconFilter, ScanCoordinator, TrickleTimer)
    |
    v  BeaconDiscoveryEvent
L3 Aggregation (AggregationIngest, BayesianPresence, BeaconPeerStore)
    |
    v  AggregationResult -> P2PDiscovery.Observation
BeaconDiscovery (DiscoveryService facade)
```

## Key Design Decisions

### Type Replacements (from swift-p2p-discovery)
- `DiscoveryCore.PeerID` (fixed 32B) -> `P2PCore.PeerID` (variable-length multihash)
- `DiscoveryCore.KeyPair` / `LocalIdentity` -> `P2PCore.KeyPair`
- `DiscoveryCore.Signature` -> `Data` (raw bytes)
- `SignedPeerRecord` -> `Envelope` + `BeaconPeerRecord` (implements `SignedRecord`)
- `DiscoveryCore.Observation` -> `BeaconObservation` (avoid collision with `P2PDiscovery.Observation`)

### Tier 3 Wire Format Change
Old format used fixed 32-byte PeerID. New format uses length-prefixed variable PeerID
and Envelope serialization:
```
Tag(1B) + PeerIDLen(2B) + PeerID(var) + Nonce(4B) + EnvelopeLen(2B) + Envelope(var)
```

### Concurrency Model
- All types use `Class + Mutex` (not Actor) per project convention
- `EventBroadcaster` for BeaconDiscovery (Discovery layer = multi-consumer)
- `func stop() async` lifecycle (Discovery layer convention)

## File Organization

### Core Types (from DiscoveryCore)
- `BeaconTier.swift` - Tier enum and tag byte encoding
- `OpaqueAddress.swift` - Transport-specific opaque address (internal)
- `PhysicalFingerprint.swift` - Sybil detection fingerprint
- `FreshnessFunction.swift` - Medium-specific freshness decay
- `BeaconObservation.swift` - Single observation event (renamed from Observation)
- `UnconfirmedSighting.swift` - Tier 1/2 unconfirmed sighting
- `ConfirmedPeerRecord.swift` - Verified peer record with Envelope
- `BeaconPeerRecord.swift` - SignedRecord implementation for Envelope
- `BeaconAddressCodec.swift` - OpaqueAddress <-> Multiaddr conversion

### L1 Encoding
- `Tier1Beacon.swift` - 10-byte minimal beacon
- `Tier2Beacon.swift` - 32-byte TESLA beacon
- `Tier3Beacon.swift` - Variable-length full identity beacon
- `MicroPoW.swift` - SHA-256 proof-of-work
- `MicroTESLA.swift` - Delayed key disclosure authentication
- `EphIDGenerator.swift` - HKDF-based ephemeral ID generation
- `DecodedBeacon.swift` - Decoded beacon result type
- `BeaconEncoderService.swift` - Encoding/decoding facade
- `DataHelpers.swift` - Big-endian integer reading extensions

### L2 Coordination
- `TrickleTimer.swift` - RFC 6206 adaptive interval
- `BeaconFilter.swift` - PoW + rate limit + Sybil filter
- `ScanCoordinator.swift` - Per-medium scan scheduling
- `BLEDiscoveryScheduler.swift` - BLE channel-specific scheduling

### L3 Aggregation
- `AggregationIngest.swift` - Event processing pipeline
- `BayesianPresence.swift` - Noisy-OR presence estimation
- `BeaconPeerStore.swift` - Storage protocol
- `InMemoryBeaconPeerStore.swift` - In-memory implementation
- `RSSISmoother.swift` - EMA RSSI filter
- `TrustCalculator.swift` - Medium-specific trust scoring

### L0 Medium Abstractions
- `MediumCharacteristics.swift` - Physical medium capabilities
- `RawDiscovery.swift` - Raw beacon event
- `TransportAdapter.swift` - Transport abstraction protocol
- `TransportAdapterErrors.swift` - Transport error types

### Service Facade
- `BeaconDiscovery.swift` - Main DiscoveryService implementation
- `BeaconDiscoveryConfiguration.swift` - Configuration struct
