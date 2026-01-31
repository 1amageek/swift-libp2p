# P2PTransportWebRTC

WebRTC Direct transport for swift-libp2p, using swift-webrtc.

## Architecture

WebRTC Direct is similar to QUIC in that it provides:
- **Built-in DTLS 1.2 security** (no SecurityUpgrader needed)
- **SCTP-based data channel multiplexing** (no Muxer needed)
- **UDP-based transport** (NAT traversal friendly)

This means WebRTC Direct connections bypass the standard libp2p upgrade pipeline
and return `MuxedConnection` directly.

```
┌─────────────────────────────────────────────────────────┐
│  Node.connect()                                          │
├─────────────────────────────────────────────────────────┤
│  ┌─────────────────┐    ┌─────────────────────────────┐ │
│  │  TCP Transport  │    │  WebRTC Transport           │ │
│  │  ↓              │    │  ↓                          │ │
│  │  RawConnection  │    │  (bypass upgrade pipeline)  │ │
│  │  ↓              │    │  ↓                          │ │
│  │  SecurityUpgrade│    │  WebRTCMuxedConnection      │ │
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
| `WebRTCTransport.swift` | SecuredTransport implementation (dialSecured/listenSecured) |
| `WebRTCSecuredListener.swift` | SecuredListener that yields pre-secured connections |
| `WebRTCMuxedConnection.swift` | MuxedConnection wrapper over WebRTCConnection |
| `WebRTCMuxedStream.swift` | MuxedStream wrapper over DataChannel |
| `WebRTCUDPSocket.swift` | UDP socket manager with address-based routing |
| `WebRTCUDPHandler.swift` | NIO ChannelInboundHandler for UDP datagrams |
| `WebRTCMultiaddrConversion.swift` | SocketAddress ↔ Multiaddr conversion |

## Usage

### Client

```swift
let transport = WebRTCTransport()

// Dial a WebRTC Direct address (bypasses upgrade pipeline)
let connection = try await transport.dialSecured(
    "/ip4/127.0.0.1/udp/4001/webrtc-direct/certhash/<base64-multihash>",
    localKeyPair: keyPair
)

// Open a stream and negotiate protocol
let stream = try await connection.newStream()
// ... multistream-select negotiation ...
```

### Server

```swift
let listener = try await transport.listenSecured(
    "/ip4/0.0.0.0/udp/4001/webrtc-direct",
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

## Internal Architecture

### UDP → DTLS → SCTP → DataChannel Pipeline

```
              Incoming UDP Datagram
                      │
                      ▼
         ┌────────────────────────┐
         │  WebRTCUDPHandler      │  NIO ChannelInboundHandler
         │  (channelRead)         │
         └───────────┬────────────┘
                     │
                     ▼
         ┌────────────────────────┐
         │  WebRTCUDPSocket       │  Address-based routing
         │  (handleDatagram)      │
         └───────────┬────────────┘
                     │ addressKey lookup
                     ▼
         ┌────────────────────────┐
         │  WebRTCConnection      │  Protocol demux (RFC 5764 §5.1.2)
         │  (receive)             │
         └───────────┬────────────┘
              ┌──────┴──────┐
              ▼             ▼
         STUN (0-3)    DTLS (20-63)
              │             │
              ▼             ▼
         ICE Lite      DTLSConnection
                            │
                            ▼ (after handshake)
                     ┌──────────────┐
                     │ SCTP decode  │
                     └──────┬───────┘
                     ┌──────┴──────┐
                     ▼             ▼
                   DCEP     Application Data
                     │             │
                     ▼             ▼
              DataChannel    DataHandler
              (new stream)   (stream.deliver)
```

### Dial Mode (1:1 Socket)

Each `dialSecured()` creates a dedicated ephemeral-port UDP socket.
The socket routes all incoming datagrams to a single WebRTCConnection.
The MuxedConnection owns the socket and closes it on `close()`.

### Listen Mode (1:N Shared Socket)

`listenSecured()` binds a single UDP socket on the requested port.
Incoming datagrams are routed by remote address (`addressKey`):
- Known peers → existing WebRTCConnection
- Unknown peers → `onNewPeer` callback → `WebRTCListener.acceptConnection()`

The socket is owned by `WebRTCSecuredListener`, not individual connections.
When a connection closes, its route is removed via `onClose` callback.

## Multiaddr Format

WebRTC Direct addresses use UDP as the underlying transport:
- `/ip4/<ip>/udp/<port>/webrtc-direct`
- `/ip4/<ip>/udp/<port>/webrtc-direct/certhash/<base64-multihash>`
- `/ip6/<ip>/udp/<port>/webrtc-direct/certhash/<base64-multihash>`

The `certhash` component contains a multihash-encoded SHA-256 fingerprint
of the DTLS certificate, used for certificate verification during dial.

## PeerID Authentication

WebRTC Direct uses DTLS 1.2 with a self-signed X.509 certificate containing
a custom extension (OID 1.3.6.1.4.1.53594.1.1) that embeds the peer's
public key, following the same scheme as libp2p-QUIC TLS 1.3.

The extension format (SignedKey):
```
SignedKey {
  public_key: PublicKey (protobuf-encoded)
  signature: bytes (signed over "libp2p-tls-handshake:" + certificate)
}
```

After the DTLS handshake completes, the remote certificate is available
and the PeerID is extracted via `LibP2PCertificate.extractPeerID()`.

## Address Routing

`SocketAddress.addressKey` provides a stable string key for the routing table:
- Uses `ipAddress` (derived from the sockaddr struct) rather than `host`
- Format: `"192.168.1.1:4001"` (IPv4) or `"[::1]:4001"` (IPv6)

This distinction is important because `SocketAddress(ipAddress:port:)` sets
`host` to empty string, while NIO-received addresses populate it from the kernel.

## Implementation Status

### Completed Features

| Component | Feature | Status |
|-----------|---------|--------|
| **WebRTCTransport** | dialSecured() | Done |
| | listenSecured() | Done |
| | canDial()/canListen() | Done |
| **WebRTCMuxedConnection** | newStream() | Done |
| | acceptStream() | Done |
| | inboundStreams | Done |
| | startForwarding() | Done |
| | Data delivery pipeline | Done |
| **WebRTCMuxedStream** | read()/write() | Done |
| | closeWrite()/closeRead() | Done |
| | close() | Done |
| **WebRTCSecuredListener** | connections stream | Done |
| | startAccepting() | Done |
| | Handshake wait + PeerID extraction | Done |
| **WebRTCUDPSocket** | Address-based routing | Done |
| | Dial mode (1:1) | Done |
| | Listen mode (1:N) | Done |

### Pending Features

| Feature | Status |
|---------|--------|
| ICE candidate exchange | Pending |
| NAT traversal (TURN relay) | Pending |
| rust-libp2p interop testing | Pending |
| go-libp2p interop testing | Pending |

## Dependencies

```
P2PTransportWebRTC
├── P2PTransport (Transport, Listener protocols)
├── P2PCore (PeerID, Multiaddr, KeyPair)
├── P2PMux (MuxedConnection, MuxedStream protocols)
├── P2PCertificate (LibP2PCertificate, OID extension)
└── WebRTC (swift-webrtc package)
    ├── DTLSCore (DTLS 1.2 certificates, handshake)
    ├── DTLSRecord (DTLS record layer)
    ├── STUNCore (STUN message parsing)
    ├── ICELite (ICE Lite agent)
    ├── SCTPCore (SCTP association)
    └── DataChannel (WebRTC data channels, DCEP)
```

## Test Status

| Test File | Tests | Description |
|-----------|-------|-------------|
| `WebRTCTransportTests.swift` | 4 | Transport address validation |
| `WebRTCMultiaddrTests.swift` | 5 | Multiaddr parsing and encoding |
| `WebRTCMuxedConnectionTests.swift` | 4 | Connection lifecycle |
| `WebRTCMuxedStreamTests.swift` | 5 | Stream read/write/close |
| `WebRTCE2ETests.swift` | 7 | Full E2E over real UDP |

**Total: 25 tests**

## References

- [libp2p WebRTC Direct Specification](https://github.com/libp2p/specs/blob/master/webrtc/webrtc-direct.md)
- [libp2p TLS Specification](https://github.com/libp2p/specs/blob/master/tls/tls.md)
- [RFC 8831: WebRTC Data Channels](https://www.rfc-editor.org/rfc/rfc8831.html)
- [RFC 8832: WebRTC Data Channel Establishment Protocol](https://www.rfc-editor.org/rfc/rfc8832.html)
- [RFC 6347: DTLS 1.2](https://www.rfc-editor.org/rfc/rfc6347.html)
- [RFC 4960: SCTP](https://www.rfc-editor.org/rfc/rfc4960.html)
