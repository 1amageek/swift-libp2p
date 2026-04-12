# swift-libp2p

A modern Swift implementation of the [libp2p](https://libp2p.io/) networking stack with wire-protocol compatibility with Go and Rust implementations. Built on Swift Concurrency (async/await, actors) for safe, high-performance peer-to-peer networking.

## Features

### Transport
TCP (SwiftNIO), QUIC (RFC 9000), WebSocket, WebRTC Direct (DTLS + SCTP), WebTransport, Memory (testing)

### Security
Noise XX (X25519 + ChaChaPoly + SHA256), TLS 1.3, Private Network (PSK + XSalsa20), Plaintext (testing)

### Multiplexing
Yamux (flow control, keep-alive), Mplex, QUIC/SCTP native multiplexing

### Discovery
SWIM membership, mDNS, CYCLON random sampling, Plumtree gossip, Beacon (BLE/WiFi/LoRa proximity)

### Protocols
Identify, Ping, GossipSub v1.1/v1.2, Kademlia DHT (S/Kademlia), Plumtree, Circuit Relay v2, AutoNAT, DCUtR, Rendezvous, HTTP

### NAT Traversal
Traversal Coordinator (local direct -> direct IP -> hole punch -> relay fallback), UPnP + NAT-PMP

## Requirements

- Swift 6.2+
- macOS 26+ / iOS 26+ / tvOS 26+ / watchOS 26+ / visionOS 26+

## Installation

```swift
dependencies: [
    .package(url: "https://github.com/1amageek/swift-libp2p.git", from: "0.1.0")
]
```

`P2P` module re-exports common dependencies (batteries-included):

```swift
.target(name: "YourApp", dependencies: ["P2P"])
```

Or pick individual modules:

```swift
.target(name: "YourApp", dependencies: [
    "P2PCore",
    "P2PTransportTCP",
    "P2PSecurityNoise",
    "P2PMuxYamux",
    "P2PProtocols"
])
```

## Quick Start

```swift
import P2P

let node = Node(configuration: NodeConfiguration(
    keyPair: .generateEd25519(),
    listenAddresses: [Multiaddr("/ip4/0.0.0.0/tcp/4001")!],
    transports: [TCPTransport()],
    security: [NoiseUpgrader()],
    muxers: [YamuxMuxer()]
))

try await node.start()
print("Listening as \(node.peerID)")

// Connect to a remote peer
let peer = try await node.connect(
    to: Multiaddr("/ip4/192.168.1.100/tcp/4001/p2p/12D3KooW...")!
)

// Open a stream
let stream = try await node.newStream(to: peer, protocol: "/chat/1.0.0")
try await stream.write(Data("Hello!".utf8))
```

## Current Status

The public surface is now split into two layers:

- `P2P`: batteries-included facade with `Node`, `Service`, `Discovery`, and the `P2PComponentBuilder` result builder
- `P2PRuntime`: expert-facing runtime APIs such as `ConnectionProvider` and `RuntimeConfiguration`

Current refactor goals:

- runtime-facing connections are unified behind `ConnectionProvider`
- service composition is explicit through `ServicePipeline`
- discovery composition is explicit through `DiscoveryPipeline`
- payload paths are normalized on `ByteBuffer`

## Architecture

### Layer Stack

```
┌─────────────────────────────────────────────────────────────┐
│  Application                                                │
│  (GossipSub, Kademlia, your protocols)                      │
├─────────────────────────────────────────────────────────────┤
│  P2P facade                                                 │
│  Node / P2PComponentBuilder(result builder)                 │
├─────────────────────────────────────────────────────────────┤
│  P2PRuntime                                                 │
│  NodeRuntime / Swarm / ConnectionPool / Traversal           │
│  ServicePipeline / DiscoveryPipeline                        │
├─────────────────────────────────────────────────────────────┤
│  Runtime connection contract                                │
│  ConnectionProvider / ConnectionAcceptor / Candidate        │
├─────────────────────────────────────────────────────────────┤
│  Protocol Negotiation (multistream-select)                  │
├─────────────────────────────────────────────────────────────┤
│  Stream Multiplexing          Yamux, Mplex                  │
├─────────────────────────────────────────────────────────────┤
│  Security                     Noise, TLS 1.3, Pnet          │
├─────────────────────────────────────────────────────────────┤
│  Transport      TCP, QUIC, WebSocket, WebRTC, WebTransport  │
├─────────────────────────────────────────────────────────────┤
│  NAT Traversal  Circuit Relay v2, AutoNAT, DCUtR            │
├─────────────────────────────────────────────────────────────┤
│  Core           PeerID, Multiaddr, KeyPair, Events          │
└─────────────────────────────────────────────────────────────┘
```

### Composition Model

- `Node` is the facade composition root
- `NodeRuntime` owns startup ordering, listeners, swarm startup, and discovery auto-connect
- `ServicePipeline` resolves service components into lifecycle services, inbound handlers, peer observers, discovery sources, and listen-address contributors
- `DiscoveryPipeline` owns child discovery services and their startup hooks

### Data Plane

The payload path is designed around `ByteBuffer`.

- transports, security wrappers, muxers, and stream I/O exchange `ByteBuffer`
- control-plane codecs may still use `Data`
- crypto and native adapter boundaries may still require `Data`
- `DataPathCopyGuardTests` prevents new `Data(buffer:)` / `ByteBuffer(bytes:)` bridges from re-entering runtime-facing paths

This keeps hot-path payload movement on `ByteBuffer` while isolating unavoidable `Data` conversions to protocol and crypto boundaries. The currently allowed exceptions are the Noise decrypt boundary, the plaintext handshake protobuf decode, and legacy `MplexFrame` convenience APIs.

### Connection Flow

```
connect(to: Multiaddr)
  │
  ├─ Traversal Coordinator (stage-by-stage)
  │    ├─ 1. Local Direct (same LAN)
  │    ├─ 2. Direct IP
  │    ├─ 3. Hole Punch (AutoNAT + DCUtR)
  │    └─ 4. Relay (Circuit Relay v2)
  │
  ├─ ConnectionProvider.dial()
  │    ├─ transport -> security -> mux pipeline
  │    └─ or native secured provider (QUIC/WebRTC/WebTransport)
  │
  ├─ ConnectionPool.add()
  ├─ Swarm emits .peerConnected (fire-and-forget)
  ├─ Node event loop -> PeerObserver dispatch
  └─ Node emits NodeEvent.peerConnected
```

## Module Structure

### Core

| Module | Description |
|--------|-------------|
| `P2PCore` | PeerID, Multiaddr, KeyPair, EventBroadcaster, Varint, Multihash |
| `P2PNegotiation` | multistream-select v1 (+ 0-RTT lazy) |
| `P2PNAT` | NAT device detection, UPnP + NAT-PMP port mapping |
| `P2PRuntime` | runtime contracts such as `ConnectionProvider` and `RuntimeConfiguration` |

### Transport

| Module | Description |
|--------|-------------|
| `P2PTransport` | Transport / Listener / RawConnection protocols |
| `P2PTransportTCP` | SwiftNIO-based TCP |
| `P2PTransportQUIC` | QUIC (0-RTT, connection migration) |
| `P2PTransportWebSocket` | WebSocket (HTTP/1.1 upgrade) |
| `P2PTransportWebRTC` | WebRTC Direct (DTLS 1.2 + SCTP) |
| `P2PTransportWebTransport` | WebTransport over QUIC |
| `P2PTransportMemory` | In-memory transport for testing |

### Security

| Module | Description |
|--------|-------------|
| `P2PSecurity` | `SecurityUpgrader`, `SecureChannel` |
| `P2PSecurityNoise` | Noise XX (X25519 + ChaChaPoly + SHA256) |
| `P2PSecurityTLS` | TLS 1.3 with libp2p certificate extension |
| `P2PPnet` | Private Network (PSK + XSalsa20, go-libp2p compatible) |
| `P2PSecurityPlaintext` | Plaintext (testing only) |
| `P2PCertificate` | X.509 certificate generation/verification |

### Multiplexing

| Module | Description |
|--------|-------------|
| `P2PMux` | Muxer / `StreamSession` / `StreamChannel` protocols |
| `P2PMuxYamux` | Yamux (256KB window, flow control, keep-alive) |
| `P2PMuxMplex` | Mplex |

### Discovery

| Module | Description |
|--------|-------------|
| `P2PDiscovery` | discovery services, address books, peer stores, `DiscoveryPipeline` |
| `P2PDiscoverySWIM` | SWIM membership (swift-SWIM integration) |
| `P2PDiscoveryMDNS` | mDNS local network discovery |
| `P2PDiscoveryCYCLON` | CYCLON random peer sampling |
| `P2PDiscoveryPlumtree` | Plumtree gossip-based discovery |
| `P2PDiscoveryBeacon` | BLE / WiFi / LoRa proximity discovery |
| `P2PDiscoveryWiFiBeacon` | WiFi beacon adapter (UDP multicast) |

### Protocols

| Module | Description |
|--------|-------------|
| `P2PProtocols` | capability protocols, service roles, `ServicePipeline` |
| `P2PIdentify` | Peer information exchange (+ Push) |
| `P2PPing` | Connection liveness check |
| `P2PGossipSub` | Pub/Sub messaging (v1.1 scoring + v1.2 IDONTWANT) |
| `P2PKademlia` | DHT (S/Kademlia, latency tracking, persistent storage) |
| `P2PPlumtree` | Epidemic Broadcast Trees |
| `P2PCircuitRelay` | Relay v2 (client + server) |
| `P2PAutoNAT` | NAT reachability detection |
| `P2PDCUtR` | Direct Connection Upgrade through Relay |
| `P2PRendezvous` | Namespace-based peer discovery |
| `P2PHTTP` | HTTP semantics over libp2p |

### Integration

| Module | Description |
|--------|-------------|
| `P2PRuntime` | expert-facing runtime layer |
| `P2P` | facade layer with `Node` and the `P2PComponentBuilder` result builder |

## Benchmark Snapshot

Current release benchmark snapshot from the in-tree benchmark harness:

### Noise Crypto

- encrypt 32B: `1621.57 ns/op`
- encrypt 256B: `1896.24 ns/op`
- decrypt 256B: `2317.60 ns/op`
- roundtrip 1KB: `5877.08 ns/op`

### Data Path

- `Memory + Plaintext + Yamux connect`: `49644.06 ns/op`
- `Memory + Noise + Yamux connect`: `569969.08 ns/op`
- `Memory + TLS + Yamux connect`: `1429667.75 ns/op`
- `Memory + Plaintext + Yamux roundtrip 1KB`: `12.00 MiB/s`
- `Memory + Noise + Yamux roundtrip 1KB`: `23.18 MiB/s`
- `Memory + TLS + Yamux roundtrip 1KB`: `36.28 MiB/s`
- `Memory + Noise + Yamux roundtrip 32KB`: `86.04 MiB/s`

Production-readiness gate:

```bash
scripts/production-gate.sh
scripts/production-gate.sh --include-benchmarks
```

This gate runs the runtime-facing copy guard, the public `Node` DSL tests,
and the Node end-to-end suite. With `--include-benchmarks`, it also runs the
release benchmark snapshot for `DataPathBenchmarks` and `NoiseCryptoBenchmarks`.

## Configuration

### Node Configuration

```swift
let node = Node(configuration: NodeConfiguration(
    keyPair: .generateEd25519(),
    listenAddresses: [Multiaddr("/ip4/0.0.0.0/tcp/4001")!],
    transports: [TCPTransport()],
    security: [NoiseUpgrader()],
    muxers: [YamuxMuxer()],
    pool: PoolConfiguration(
        limits: .init(maxConnections: 100, maxConnectionsPerPeer: 2),
        reconnectionPolicy: .default,
        idleTimeout: .seconds(300)
    )
))
```

### Services

Services are composed explicitly via `ServicePipeline` or `Node { ... }`:

```swift
let node = Node(
    keyPair: .generateEd25519(),
    listenAddresses: [Multiaddr("/ip4/0.0.0.0/tcp/4001")!],
    transports: [TCPTransport()],
    security: [NoiseUpgrader()],
    muxers: [YamuxMuxer()]
) {
    GossipSub()
    Kademlia()
}

try await node.start()
```

### Production Profile

For a safer default operating profile, use `.production`:

```swift
let node = Node(
    profile: .production,
    keyPair: .generateEd25519(),
    listenAddresses: [Multiaddr("/ip4/0.0.0.0/tcp/4001")!],
    transports: [TCPTransport()],
    security: [NoiseUpgrader()],
    muxers: [YamuxMuxer()]
) {
    Identify()
    GossipSub()
}
```

The production profile enables resource accounting and production-oriented
pool and health-check defaults. It also rejects `PlaintextUpgrader`.

You can also validate a node before startup:

```swift
do {
    try await node.start(validating: .production, behavior: .strict)
} catch let error as NodeStartValidationError {
    print("validation errors:", error.validation.errors)
    print("validation warnings:", error.validation.warnings)
}
```

The intended release path is:

1. compose with `Node(profile: .production) { ... }`
2. start with `try await node.start(validating: .production, behavior: .strict)`
3. run `scripts/production-gate.sh --include-benchmarks` before shipping

Reusable groups can be modeled directly as `NodeGroup` values:

```swift
let chatStack = NodeGroup {
    Identify()
    GossipSub()
    MDNS()
}

let node = Node {
    chatStack
}
```

If you want a custom type, conform to `NodeComponent` and forward to `NodeGroup`:

```swift
struct MetricsStack: NodeComponent {
    let ping = PingService()

    var nodeGroup: NodeGroup {
        NodeGroup {
            Service(ping)
                .handlesInboundStreams()
        }
    }
}
```

### Discovery with Auto-Connect

```swift
let node = Node(
    keyPair: .generateEd25519(),
    listenAddresses: [Multiaddr("/ip4/0.0.0.0/tcp/4001")!],
    transports: [TCPTransport()],
    security: [NoiseUpgrader()],
    muxers: [YamuxMuxer()],
    discoveryConfig: .autoConnectEnabled
) {
    Identify()
    MDNS()
    SWIM()
}
```

## Events

```swift
// Node events
Task {
    for await event in node.events {
        switch event {
        case .peerConnected(let peer):
            print("Connected: \(peer)")
        case .peerDisconnected(let peer):
            print("Disconnected: \(peer)")
        case .newListenAddr(let addr):
            print("Listening on: \(addr)")
        default: break
        }
    }
}

// Service events (e.g., GossipSub — EventBroadcaster, multi-consumer)
Task {
    for await event in gossipsub.events {
        switch event {
        case .messageReceived(let msg):
            print("Message on \(msg.topic): \(msg.data)")
        default: break
        }
    }
}
```

## Concurrency Model

| Pattern | When | Examples |
|---------|------|---------|
| `actor` | I/O heavy, user-facing API | Node, Swarm, HealthMonitor |
| `class + Mutex<T>` | High-frequency, sync access | ConnectionPool, PeerStore |
| `struct` | Data containers | NodeConfiguration, SwarmEvent |

### Event Patterns

| Pattern | Consumers | Examples |
|---------|-----------|---------|
| `EventEmitting` (single) | One `for await` loop | Ping, Identify, AutoNAT, Kademlia |
| `EventBroadcaster` (multi) | Multiple independent loops | GossipSub, SWIM, mDNS, Node |

## Wire Protocol Compatibility

| Protocol | Protocol ID | Specification |
|----------|-------------|---------------|
| multistream-select | `/multistream/1.0.0` | [spec](https://github.com/multiformats/multistream-select) |
| TLS 1.3 | `/tls/1.0.0` | [spec](https://github.com/libp2p/specs/blob/master/tls/tls.md) |
| Noise | `/noise` | [spec](https://github.com/libp2p/specs/blob/master/noise/README.md) |
| Yamux | `/yamux/1.0.0` | [spec](https://github.com/hashicorp/yamux/blob/master/spec.md) |
| Mplex | `/mplex/6.7.0` | [spec](https://github.com/libp2p/specs/blob/master/mplex/README.md) |
| Identify | `/ipfs/id/1.0.0` | [spec](https://github.com/libp2p/specs/blob/master/identify/README.md) |
| Ping | `/ipfs/ping/1.0.0` | [spec](https://github.com/libp2p/specs/blob/master/ping/README.md) |
| Circuit Relay v2 | `/libp2p/circuit/relay/0.2.0/hop` | [spec](https://github.com/libp2p/specs/blob/master/relay/circuit-v2.md) |
| GossipSub | `/meshsub/1.1.0` | [spec](https://github.com/libp2p/specs/blob/master/pubsub/gossipsub/gossipsub-v1.1.md) |
| Kademlia | `/ipfs/kad/1.0.0` | [spec](https://github.com/libp2p/specs/blob/master/kad-dht/README.md) |
| AutoNAT | `/libp2p/autonat/1.0.0` | [spec](https://github.com/libp2p/specs/blob/master/autonat/README.md) |
| DCUtR | `/libp2p/dcutr` | [spec](https://github.com/libp2p/specs/blob/master/relay/DCUtR.md) |
| Plumtree | `/plumtree/1.0.0` | [paper](https://asc.di.fct.unl.pt/~jleitao/pdf/srds07-leitao.pdf) |
| CYCLON | `/cyclon/1.0.0` | [paper](https://link.springer.com/article/10.1007/s10922-005-4441-x) |
| WebRTC Direct | `/webrtc-direct` | [spec](https://github.com/libp2p/specs/blob/master/webrtc/webrtc-direct.md) |

## Testing

```bash
# Build
swift build

# Run specific test suite (always use timeout)
swift test --filter P2PTests 2>&1 &
PID=$!; sleep 120; kill $PID 2>/dev/null; wait $PID 2>/dev/null

# Interoperability tests (requires Docker)
swift test --filter Interop
```

## Dependencies

| Package | Purpose |
|---------|---------|
| [swift-nio](https://github.com/apple/swift-nio) | Network I/O |
| [swift-crypto](https://github.com/apple/swift-crypto) | Cryptographic primitives |
| [swift-certificates](https://github.com/apple/swift-certificates) | X.509 handling |
| [swift-asn1](https://github.com/apple/swift-asn1) | ASN.1 encoding |
| [swift-log](https://github.com/apple/swift-log) | Logging |
| [swift-atomics](https://github.com/apple/swift-atomics) | Lock-free primitives |
| [swift-tls](https://github.com/1amageek/swift-tls) | TLS 1.3 (pure Swift) |
| [swift-quic](https://github.com/1amageek/swift-quic) | QUIC (RFC 9000) |
| [swift-webrtc](https://github.com/1amageek/swift-webrtc) | WebRTC Direct |

## References

- [libp2p Specifications](https://github.com/libp2p/specs)
- [go-libp2p](https://github.com/libp2p/go-libp2p)
- [rust-libp2p](https://github.com/libp2p/rust-libp2p)

## License

MIT License
