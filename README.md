# swift-libp2p

A modern Swift implementation of the [libp2p](https://libp2p.io/) networking stack, designed for wire-protocol compatibility with Go and Rust implementations.

## Features

- **Transport Layer**: TCP (SwiftNIO), QUIC (RFC 9000/9001), Memory for testing
- **Security Layer**: Noise Protocol (XX pattern), QUIC TLS 1.3, Plaintext for testing
- **Multiplexing**: Yamux stream multiplexer, QUIC native multiplexing
- **Protocol Negotiation**: multistream-select 1.0
- **Identity**: Ed25519/ECDSA P-256 keys, PeerID derivation
- **Addressing**: Full Multiaddr support
- **Discovery**: SWIM membership, mDNS local discovery
- **NAT Traversal**: Circuit Relay v2, AutoNAT, DCUtR hole punching
- **Standard Protocols**: Identify, Ping, GossipSub, Kademlia DHT

## Requirements

- Swift 6.2+
- macOS 15+ / iOS 18+ / tvOS 18+ / watchOS 11+ / visionOS 2+

## Installation

Add swift-libp2p to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/example/swift-libp2p.git", from: "0.1.0")
]
```

Then add the necessary targets:

```swift
.target(
    name: "YourApp",
    dependencies: [
        "P2P",
        "P2PTransportTCP",
        "P2PSecurityNoise",
        "P2PMuxYamux"
    ]
)
```

## Quick Start

```swift
import P2P
import P2PTransportTCP
import P2PSecurityNoise
import P2PMuxYamux

// Create a node
let keyPair = KeyPair.generateEd25519()
let config = NodeConfiguration(
    keyPair: keyPair,
    listenAddresses: [Multiaddr("/ip4/0.0.0.0/tcp/4001")!],
    transports: [TCPTransport()],
    security: [NoiseUpgrader()],
    muxers: [YamuxMuxer()],
    limits: ConnectionLimits(maxConnections: 100)
)

let node = Node(configuration: config)

// Register protocol handler
await node.handle("/chat/1.0.0") { stream in
    // Handle incoming chat messages
    let data = try await stream.read()
    print("Received: \(String(data: data, encoding: .utf8)!)")
}

// Start the node
try await node.start()
print("Node started with PeerID: \(await node.peerID)")

// Connect to a peer
let remotePeer = try await node.connect(
    to: Multiaddr("/ip4/192.168.1.100/tcp/4001/p2p/12D3KooW...")!
)

// Open a stream
let stream = try await node.newStream(to: remotePeer, protocol: "/chat/1.0.0")
try await stream.write(Data("Hello!".utf8))
```

## Architecture

```
+-----------------------------------------------------------+
|  Application Layer                                         |
|  (Your protocols, GossipSub, Kademlia DHT, SWIM Discovery)|
+-----------------------------------------------------------+
|  Protocol Negotiation (multistream-select)                |
+-----------------------------------------------------------+
|  Stream Multiplexing (Yamux)                              |
+-----------------------------------------------------------+
|  Security Layer (Noise XX)                                |
+-----------------------------------------------------------+
|  Transport Layer (TCP, Memory, Circuit Relay)             |
+-----------------------------------------------------------+
|  NAT Traversal (Circuit Relay v2, AutoNAT, DCUtR)         |
+-----------------------------------------------------------+
|  Core Types (PeerID, Multiaddr, KeyPair)                  |
+-----------------------------------------------------------+
```

## Module Structure

| Module | Description |
|--------|-------------|
| `P2PCore` | Core types: PeerID, Multiaddr, KeyPair, EventEmitting |
| `P2PTransport` | Transport protocol definition |
| `P2PTransportTCP` | TCP transport implementation (SwiftNIO) |
| `P2PTransportQUIC` | QUIC transport implementation (RFC 9000) |
| `P2PTransportMemory` | In-memory transport for testing |
| `P2PSecurity` | Security protocol definition |
| `P2PSecurityNoise` | Noise Protocol implementation |
| `P2PSecurityPlaintext` | Plaintext security for testing |
| `P2PMux` | Muxer protocol definition |
| `P2PMuxYamux` | Yamux multiplexer implementation |
| `P2PNegotiation` | multistream-select protocol |
| `P2PDiscovery` | Discovery protocol definition |
| `P2PDiscoverySWIM` | SWIM membership protocol |
| `P2PDiscoveryMDNS` | mDNS local network discovery |
| `P2P` | Integration layer (Node, ConnectionPool) |
| `P2PProtocols` | Protocol service definitions |
| `P2PIdentify` | Identify protocol |
| `P2PPing` | Ping protocol |
| `P2PCircuitRelay` | Circuit Relay v2 for NAT traversal |
| `P2PGossipSub` | GossipSub pubsub protocol |
| `P2PKademlia` | Kademlia DHT implementation |
| `P2PAutoNAT` | AutoNAT protocol for NAT detection |
| `P2PDCUtR` | Direct Connection Upgrade through Relay |

## Wire Protocol Compatibility

This implementation follows the official libp2p specifications for wire-protocol compatibility:

| Protocol | Protocol ID | Specification |
|----------|-------------|---------------|
| multistream-select | `/multistream/1.0.0` | [spec](https://github.com/multiformats/multistream-select) |
| Noise | `/noise` | [spec](https://github.com/libp2p/specs/blob/master/noise/README.md) |
| Yamux | `/yamux/1.0.0` | [spec](https://github.com/hashicorp/yamux/blob/master/spec.md) |
| Identify | `/ipfs/id/1.0.0` | [spec](https://github.com/libp2p/specs/blob/master/identify/README.md) |
| Ping | `/ipfs/ping/1.0.0` | [spec](https://github.com/libp2p/specs/blob/master/ping/README.md) |
| Circuit Relay v2 | `/libp2p/circuit/relay/0.2.0/hop`, `/libp2p/circuit/relay/0.2.0/stop` | [spec](https://github.com/libp2p/specs/blob/master/relay/circuit-v2.md) |
| GossipSub | `/meshsub/1.1.0` | [spec](https://github.com/libp2p/specs/blob/master/pubsub/gossipsub/gossipsub-v1.1.md) |
| Kademlia DHT | `/ipfs/kad/1.0.0` | [spec](https://github.com/libp2p/specs/blob/master/kad-dht/README.md) |
| AutoNAT | `/libp2p/autonat/1.0.0` | [spec](https://github.com/libp2p/specs/blob/master/autonat/README.md) |
| DCUtR | `/libp2p/dcutr` | [spec](https://github.com/libp2p/specs/blob/master/relay/DCUtR.md) |

## Design Principles

### Modern Swift Idioms

- **async/await everywhere**: No EventLoopFuture, pure Swift concurrency
- **Value types first**: struct over class where appropriate
- **Sendable compliance**: Thread-safe by design using `Mutex<T>`
- **Protocol-oriented**: All major components defined as protocols

### Concurrency Model

| Use Case | Pattern |
|----------|---------|
| User-facing APIs | `actor` |
| High-frequency internal state | `class + Mutex<T>` |
| Data containers | `struct` |

### EventEmitting Pattern

All services that expose `AsyncStream<Event>` conform to the `EventEmitting` protocol:

```swift
// Services implement EventEmitting protocol
public final class MyService: EventEmitting, Sendable {
    public var events: AsyncStream<MyEvent> { ... }
    public func shutdown() { ... }  // Required: terminates event stream
}

// Safe usage with automatic cleanup
try await withEventEmitter(myService) { service in
    for await event in service.events {
        // Handle events
    }
}
// shutdown() called automatically
```

**Important**: Always call `shutdown()` when done with a service to prevent `for await` from hanging.

### Dependency Injection

All components are injected via protocols:

```swift
let node = Node(configuration: NodeConfiguration(
    keyPair: myKeyPair,
    transports: [TCPTransport()],      // Injectable
    security: [NoiseUpgrader()],       // Injectable
    muxers: [YamuxMuxer()]             // Injectable
))
```

## Configuration

### Connection Limits

```swift
let limits = ConnectionLimits(
    maxConnections: 100,
    maxConnectionsPerPeer: 2,
    idleTimeout: .seconds(60)
)
```

### Reconnection Policy

```swift
let policy = ReconnectionPolicy(
    enabled: true,
    maxAttempts: 5,
    backoff: .exponential(base: .seconds(1), factor: 2.0, maxDelay: .seconds(60))
)
```

### Connection Gating

```swift
let gater = ConnectionGater(
    allowlist: [trustedPeerID],
    denylist: [blockedPeerID],
    customFilter: { peer, direction in
        // Custom filtering logic
        return true
    }
)
```

## Events

All event-emitting services follow the `EventEmitting` protocol pattern:

```swift
// Node events
for await event in await node.events {
    switch event {
    case .peerConnected(let peer):
        print("Connected to \(peer)")
    case .peerDisconnected(let peer):
        print("Disconnected from \(peer)")
    case .listenError(let addr, let error):
        print("Listen error on \(addr): \(error)")
    case .connectionError(let peer, let error):
        print("Connection error: \(error)")
    }
}

// Service events (e.g., GossipSub)
let gossipsub = GossipSubService(...)
Task {
    for await event in gossipsub.events {
        switch event {
        case .messageReceived(let topic, let message):
            print("Received on \(topic): \(message)")
        case .peerJoined(let topic, let peer):
            print("\(peer) joined \(topic)")
        default: break
        }
    }
}

// Don't forget to shutdown when done!
gossipsub.shutdown()
```

## QUIC Transport

QUIC provides built-in encryption (TLS 1.3) and native stream multiplexing:

```swift
import P2PTransportQUIC

// QUIC transport with libp2p certificate
let quicTransport = QUICTransport(configuration: .init(
    certificateProvider: .libp2p(keyPair: keyPair)
))

// Listen on QUIC
let listener = try await quicTransport.listen(
    Multiaddr("/ip4/0.0.0.0/udp/4001/quic-v1")!
)

// Dial with QUIC
let connection = try await quicTransport.dial(
    Multiaddr("/ip4/192.168.1.100/udp/4001/quic-v1/p2p/12D3KooW...")!
)
```

**Benefits of QUIC**:
- 0-RTT connection establishment
- Native stream multiplexing (no Yamux needed)
- Built-in TLS 1.3 security
- Connection migration support

## NAT Traversal with Circuit Relay

Circuit Relay v2 enables peers behind NATs to communicate through public relay nodes.

### Making a Reservation

A peer behind NAT makes a reservation on a public relay to receive incoming connections:

```swift
import P2PCircuitRelay

let client = RelayClient()
await client.registerHandler(registry: node)

// Reserve a slot on the relay
let reservation = try await client.reserve(on: relayPeerID, using: node)
print("Reserved until: \(reservation.expiration)")
print("Relay addresses: \(reservation.addresses)")
```

### Connecting Through a Relay

Another peer can connect to the NAT'd peer through the relay:

```swift
// Connect to target through relay
let connection = try await client.connectThrough(
    relay: relayPeerID,
    to: targetPeerID,
    using: node
)

// Use the relayed connection
try await connection.write(Data("Hello through relay!".utf8))
```

### Running a Relay Server

To run a public relay node:

```swift
let server = RelayServer(configuration: .init(
    maxReservations: 128,
    maxCircuitsPerPeer: 16,
    reservationDuration: .seconds(3600)
))

await server.registerHandler(
    registry: node,
    opener: node,
    localPeer: node.peerID,
    getLocalAddresses: { node.listenAddresses }
)
```

### Relayed Addresses

Relayed addresses use the `p2p-circuit` protocol:

```
/ip4/1.2.3.4/tcp/4001/p2p/{relay-peer-id}/p2p-circuit/p2p/{target-peer-id}
```

## Testing

### Unit Tests

```bash
swift test
```

### Integration Tests with Other Implementations

```bash
# Start a rust-libp2p node
cargo run --example ping -- --listen /ip4/127.0.0.1/tcp/4001

# Connect from swift-libp2p
swift run swift-libp2p-example dial /ip4/127.0.0.1/tcp/4001/p2p/<peer-id>
```

## Dependencies

- [swift-nio](https://github.com/apple/swift-nio) - Network I/O
- [swift-crypto](https://github.com/apple/swift-crypto) - Cryptographic primitives
- [swift-log](https://github.com/apple/swift-log) - Logging
- [swift-protobuf](https://github.com/apple/swift-protobuf) - Protocol Buffers
- [swift-quic](https://github.com/example/swift-quic) - QUIC protocol (RFC 9000)
- [swift-SWIM](https://github.com/example/swift-SWIM) - SWIM membership protocol
- [swift-mDNS](https://github.com/example/swift-mDNS) - mDNS/DNS-SD discovery

## Contributing

Contributions are welcome! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## References

- [libp2p Specifications](https://github.com/libp2p/specs)
- [rust-libp2p](https://github.com/libp2p/rust-libp2p) - Reference implementation
- [go-libp2p](https://github.com/libp2p/go-libp2p)
- [SWIM Paper](https://www.cs.cornell.edu/projects/Quicksilver/public_pdfs/SWIM.pdf)

## License

MIT License
