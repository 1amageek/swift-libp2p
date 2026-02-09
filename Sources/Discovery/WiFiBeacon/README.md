# P2PDiscoveryWiFiBeacon

A WiFi beacon transport adapter using UDP multicast. Reference implementation of the `TransportAdapter` protocol.

## Overview

Broadcasts and receives beacon payloads over a local WiFi network using standard UDP multicast. No OS-specific APIs (CoreBluetooth, MultipeerConnectivity, etc.) required — only SwiftNIO.

## Installation

Add the dependency in `Package.swift`:

```swift
.product(name: "P2PDiscoveryWiFiBeacon", package: "swift-libp2p")
```

## Quick Start

### Standalone Usage

```swift
import P2PDiscoveryWiFiBeacon
import P2PDiscoveryBeacon

// 1. Create an adapter
let adapter = WiFiBeaconAdapter()

// 2. Start broadcasting a beacon payload
let payload = Data([0xD0, 0x12, 0x34, 0xAA, 0xBB, 0xCC, 0x00, 0x00, 0x01, 0x02])
try await adapter.startBeacon(payload)

// 3. Receive beacons from other nodes
Task {
    for await discovery in adapter.discoveries {
        print("Received from \(discovery.mediumID): \(discovery.payload.count) bytes")
    }
}

// 4. Stop broadcasting (receiving continues)
await adapter.stopBeacon()

// 5. Full shutdown
await adapter.shutdown()
```

### Integration with BeaconDiscovery

```swift
import P2PDiscoveryBeacon
import P2PDiscoveryWiFiBeacon
import P2PCore

// Create adapter
let wifiAdapter = WiFiBeaconAdapter(configuration: WiFiBeaconConfiguration(
    transmitInterval: .seconds(3)
))

// Create BeaconDiscovery
let keyPair = KeyPair.generateEd25519()
let beaconConfig = BeaconDiscoveryConfiguration(keyPair: keyPair, store: store)
let beaconDiscovery = BeaconDiscovery(configuration: beaconConfig)
beaconDiscovery.start()

// Receive: adapter -> BeaconDiscovery
Task {
    for await discovery in wifiAdapter.discoveries {
        beaconDiscovery.processDiscovery(discovery)
    }
}

// Transmit: encode payload via BeaconDiscovery, then broadcast
let encoder = BeaconEncoderService()
let beaconPayload = try encoder.encodeTier1(
    ephID: ephID,
    capabilities: capabilities,
    teslaMAC: mac
)
try await wifiAdapter.startBeacon(beaconPayload)
```

## Configuration

Customize behavior with `WiFiBeaconConfiguration`:

```swift
let config = WiFiBeaconConfiguration(
    multicastGroup: "239.2.0.1",    // Multicast group (RFC 2365)
    port: 9876,                      // UDP port
    networkInterface: "en0",         // Interface to bind (nil = all)
    transmitInterval: .seconds(5),   // Broadcast interval
    loopback: false                  // Receive own beacons (for testing)
)
let adapter = WiFiBeaconAdapter(configuration: config)
```

| Parameter | Default | Description |
|-----------|---------|-------------|
| `multicastGroup` | `"239.2.0.1"` | RFC 2365 Organization-Local Scope |
| `port` | `9876` | UDP port number |
| `networkInterface` | `nil` | `nil` = all interfaces |
| `transmitInterval` | `.seconds(5)` | Beacon broadcast interval |
| `loopback` | `false` | Set `true` to receive own beacons (for testing) |

## Wire Format

```
WiFi Beacon Frame (8 + N bytes):
+--------+--------+---------+-------+
| Magic (2B)      | Version | Flags |
| 0x50 0x32 ("P2")| 0x01    | 0x00  |
+--------+--------+---------+-------+
| Payload Length (2B, big-endian)    |
+------------------------------------+
| Reserved (2B, 0x00 0x00)          |
+------------------------------------+
| Beacon Payload (N bytes)           |
+------------------------------------+
```

- **Magic** `0x50 0x32` ("P2"): immediately rejects non-P2P traffic
- **Max payload**: 512 bytes (`MediumCharacteristics.wifiDirect.maxBeaconSize`)
- **Total**: up to 520 bytes (fits within standard MTU)

## TransportAdapter Protocol

`WiFiBeaconAdapter` conforms to `TransportAdapter`:

```swift
public protocol TransportAdapter: Sendable {
    var mediumID: String { get }
    var characteristics: MediumCharacteristics { get }
    func startBeacon(_ payload: Data) async throws
    func stopBeacon() async
    var discoveries: AsyncStream<RawDiscovery> { get }
    func shutdown() async
}
```

### Lifecycle

```
init -> startBeacon(_:) -> [broadcasting + receiving] -> stopBeacon() -> [receiving only] -> shutdown()
               ^                                              |
               +-------------- startBeacon(_:) ---------------+  (restartable)
```

- `startBeacon(_:)`: starts transmit + receive. If already transmitting, restarts with the new payload.
- `stopBeacon()`: stops transmitting only. Receiving continues.
- `shutdown()`: releases all resources. Instance cannot be reused.

### Errors

| Error | Condition |
|-------|-----------|
| `TransportAdapterError.beaconTooLarge` | Payload exceeds 512 bytes |
| `TransportAdapterError.mediumNotAvailable` | `startBeacon(_:)` called after `shutdown()` |
| `WiFiBeaconError.bindFailed` | UDP socket bind or multicast join failed |

## Implementing Your Own Adapter

`WiFiBeaconAdapter` serves as a reference implementation of `TransportAdapter`. When building adapters for other media (BLE, LoRa, etc.), follow these guidelines:

1. Use the **Class + Mutex** pattern (not Actor)
2. **`discoveries`** uses the single-consumer pattern (returns the same stream)
3. **`shutdown()`** must call both `continuation.finish()` and set `stream = nil`
4. **Reject operations after shutdown** via an `isShutdown` flag
5. **`deinit`** should also release resources (safety net for missed shutdown)

```swift
public final class MyBLEAdapter: TransportAdapter, Sendable {
    public let mediumID: String = "ble"
    public let characteristics: MediumCharacteristics = .ble

    private let state: Mutex<AdapterState>

    public var discoveries: AsyncStream<RawDiscovery> {
        state.withLock { s in
            if let existing = s.discoveryStream { return existing }
            if s.isShutdown {
                let (stream, continuation) = AsyncStream<RawDiscovery>.makeStream()
                continuation.finish()
                return stream
            }
            let (stream, continuation) = AsyncStream<RawDiscovery>.makeStream()
            s.discoveryStream = stream
            s.discoveryContinuation = continuation
            return stream
        }
    }

    public func shutdown() async {
        let continuation = state.withLock { s in
            let c = s.discoveryContinuation
            s.discoveryContinuation = nil
            s.discoveryStream = nil
            s.isShutdown = true
            return c
        }
        // Release media-specific resources here
        continuation?.finish()
    }
}
```

## Testing

```bash
swift test --filter P2PDiscoveryWiFiBeaconTests
```

Tests run on a single machine using loopback multicast (`loopback: true`). No actual multi-device discovery is performed.

## Dependencies

- **P2PDiscoveryBeacon**: `TransportAdapter` protocol, `RawDiscovery`, `OpaqueAddress`
- **P2PCore**: `PeerID`, `Multiaddr`
- **NIOUDPTransport**: UDP multicast send/receive
