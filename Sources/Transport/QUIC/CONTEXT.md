# P2PTransportQUIC

QUIC transport for swift-libp2p, using swift-quic.

## Architecture

QUIC is unique among libp2p transports because it provides:
- **Built-in TLS 1.3 security** (no SecurityUpgrader needed)
- **Native stream multiplexing** (no Muxer needed)
- **Integrated congestion control**
- **0-RTT connection establishment**

This means QUIC connections bypass the standard libp2p upgrade pipeline
and return `MuxedConnection` directly.

```
┌─────────────────────────────────────────────────────────┐
│  Node.connect()                                          │
├─────────────────────────────────────────────────────────┤
│  ┌─────────────────┐    ┌─────────────────────────────┐ │
│  │  TCP Transport  │    │  QUIC Transport             │ │
│  │  ↓              │    │  ↓                          │ │
│  │  RawConnection  │    │  (bypass upgrade pipeline)  │ │
│  │  ↓              │    │  ↓                          │ │
│  │  SecurityUpgrade│    │  QUICMuxedConnection        │ │
│  │  ↓              │    │  (already secured + muxed)  │ │
│  │  MuxerUpgrade   │    │                             │ │
│  │  ↓              │    │                             │ │
│  │  MuxedConnection│    │                             │ │
│  └─────────────────┘    └─────────────────────────────┘ │
└─────────────────────────────────────────────────────────┘
```

## Files

| File | Purpose |
|------|---------|
| `QUICTransport.swift` | Transport protocol implementation |
| `QUICMuxedConnection.swift` | MuxedConnection wrapper for QUIC |
| `QUICMuxedStream.swift` | MuxedStream wrapper for QUIC streams |
| `QUICListener.swift` | Listener implementations (standard and secured) |
| `MultiaddrConversion.swift` | Multiaddr ↔ SocketAddress conversion |

## Usage

### Client

```swift
let transport = QUICTransport()

// Dial a QUIC address (bypasses upgrade pipeline)
let connection = try await transport.dialSecured(
    "/ip4/127.0.0.1/udp/4433/quic-v1",
    localKeyPair: keyPair
)

// Open a stream and negotiate protocol
let stream = try await connection.newStream()
// ... multistream-select negotiation ...
```

### Server

```swift
let listener = try await transport.listenSecured(
    "/ip4/0.0.0.0/udp/4433/quic-v1",
    localKeyPair: keyPair
)

for await connection in listener.connections {
    Task {
        for await stream in connection.inboundStreams {
            // Handle stream
        }
    }
}
```

## Multiaddr Format

QUIC addresses use UDP as the underlying transport:
- `/ip4/<ip>/udp/<port>/quic-v1`
- `/ip6/<ip>/udp/<port>/quic-v1`

## PeerID Authentication

libp2p-QUIC uses TLS 1.3 with a custom X.509 certificate extension
(OID 1.3.6.1.4.1.53594.1.1) that contains the peer's public key.

## swift-quic Implementation Status

swift-quic provides full QUIC protocol implementation:

### Completed Features

| Module | Feature | Status |
|--------|---------|--------|
| **QUICCore** | Varint encoding/decoding | ✅ |
| | ConnectionID | ✅ |
| | PacketHeader (Long/Short) | ✅ |
| | All Frame types (19 types) | ✅ |
| | Packet number encoding | ✅ |
| **QUICCrypto** | HKDF key derivation | ✅ |
| | Initial secrets | ✅ |
| | AES-128-GCM AEAD | ✅ |
| | ChaCha20-Poly1305 AEAD | ✅ |
| | Header protection (AES/ChaCha20) | ✅ |
| | Cross-platform support (Apple/Linux) | ✅ |
| **TLS 1.3** | Full handshake state machine | ✅ |
| | X.509 certificate validation | ✅ |
| | EKU/SAN/Name Constraints | ✅ |
| | Session resumption (PSK) | ✅ |
| | 0-RTT early data | ✅ |
| **QUICConnection** | Connection state machine | ✅ |
| | Packet number space management | ✅ |
| | Connection ID management | ✅ |
| **QUICStream** | DataStream (send/receive) | ✅ |
| | StreamManager (multiplexing) | ✅ |
| | FlowController | ✅ |
| | STOP_SENDING/RESET_STREAM | ✅ |
| **QUICRecovery** | RTT estimation | ✅ |
| | Loss detection | ✅ |
| | ACK management | ✅ |

### Pending Features

| Feature | Status |
|---------|--------|
| libp2p TLS certificate extension | ⏳ Phase 3 |
| Congestion control (CUBIC/NewReno) | ⏳ |
| Priority scheduling | ⏳ |
| Public API integration (QUICClient, QUICListener) | ⏳ Phase 7 |
| rust-libp2p/go-libp2p interop testing | ⏳ Phase 4 |

## P2PTransportQUIC Implementation Status

- [x] Phase 1: Basic structure with MockTLS
  - [x] QUICTransport
  - [x] QUICMuxedConnection
  - [x] QUICMuxedStream
  - [x] QUICListener
  - [x] MultiaddrConversion
- [ ] Phase 2: Node integration
  - [ ] P2P.swift QUIC bypass logic
  - [ ] acceptLoop() QUIC handling
- [ ] Phase 3: libp2p TLS
  - [ ] Libp2pTLSProvider (swift-quic TLS integration)
  - [ ] X.509 certificate extension (OID 1.3.6.1.4.1.53594.1.1)
  - [ ] PeerID verification
- [ ] Phase 4: Interoperability
  - [ ] rust-libp2p testing
  - [ ] go-libp2p testing

## Dependencies

```
P2PTransportQUIC
├── P2PTransport (Transport, Listener protocols)
├── P2PCore (PeerID, Multiaddr, KeyPair)
├── P2PMux (MuxedConnection, MuxedStream protocols)
└── QUIC (swift-quic package)
    ├── QUICCore
    ├── QUICCrypto
    ├── QUICConnection
    ├── QUICStream
    ├── QUICRecovery
    └── QUICTransport
```

## References

- [libp2p QUIC Specification](https://github.com/libp2p/specs/tree/master/quic)
- [libp2p TLS Specification](https://github.com/libp2p/specs/blob/master/tls/tls.md)
- [RFC 9000: QUIC](https://www.rfc-editor.org/rfc/rfc9000.html)
- [RFC 9001: Using TLS to Secure QUIC](https://www.rfc-editor.org/rfc/rfc9001.html)
- [RFC 9002: Loss Detection and Congestion Control](https://www.rfc-editor.org/rfc/rfc9002.html)
