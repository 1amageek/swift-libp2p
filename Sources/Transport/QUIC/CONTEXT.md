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
| `QUICMuxedConnection.swift` | MuxedConnection wrapper with StreamChannel |
| `QUICMuxedStream.swift` | MuxedStream wrapper for QUIC streams |
| `QUICListener.swift` | Listener implementations (standard and secured) |
| `MultiaddrConversion.swift` | Multiaddr ↔ SocketAddress conversion |
| `TLS/SwiftQUICTLSProvider.swift` | libp2p TLS 1.3 provider |
| `TLS/LibP2PCertificateHelper.swift` | X.509 certificate generation |
| `QUICHolePunch.swift` | NAT traversal coordinator for QUIC hole punching |

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

### Stream Close Behavior

QUIC streams have distinct close operations:

| Method | Behavior | Use Case |
|--------|----------|----------|
| `closeWrite()` | Send FIN frame | Done writing, allow peer to finish |
| `closeRead()` | Send STOP_SENDING | Abort reading (data may be lost) |
| `close()` | Send FIN only | Graceful close (recommended) |
| `reset()` | Send RESET_STREAM | Abort immediately (data lost) |

**Important**: `close()` only sends FIN, not STOP_SENDING. This ensures pending
data is delivered before the stream closes. Use `reset()` for abrupt termination.

## Internal Architecture

### StreamChannel Pattern

`QUICMuxedConnection` uses a `StreamChannel` to buffer and distribute streams:

```
┌─────────────────────────────────────────────────────────┐
│  QUICMuxedConnection                                     │
├─────────────────────────────────────────────────────────┤
│                                                          │
│  quicConnection.incomingStreams                         │
│         │                                                │
│         ▼                                                │
│  ┌─────────────────┐                                    │
│  │ startForwarding │ ◄── wraps streams as QUICMuxedStream│
│  └────────┬────────┘                                    │
│           │                                              │
│           ▼                                              │
│  ┌─────────────────┐                                    │
│  │  StreamChannel  │ ◄── thread-safe buffer + waiters   │
│  └────────┬────────┘                                    │
│           │                                              │
│     ┌─────┴─────┐                                       │
│     ▼           ▼                                       │
│  inboundStreams  acceptStream()                         │
│  (AsyncStream)   (single stream)                        │
│                                                          │
└─────────────────────────────────────────────────────────┘
```

Both `inboundStreams` and `acceptStream()` consume from the same `StreamChannel`.
Use ONE pattern per connection, not both.

## Multiaddr Format

QUIC addresses use UDP as the underlying transport:
- `/ip4/<ip>/udp/<port>/quic-v1`
- `/ip6/<ip>/udp/<port>/quic-v1`

## PeerID Authentication

libp2p-QUIC uses TLS 1.3 with a custom X.509 certificate extension
(OID 1.3.6.1.4.1.53594.1.1) that contains the peer's public key.

The extension format (SignedKey):
```
SignedKey {
  public_key: PublicKey (protobuf-encoded)
  signature: bytes (signed over "libp2p-tls-handshake:" + certificate)
}
```

## swift-quic API

swift-quic provides `QUICConnectionProtocol` with:

```swift
public protocol QUICConnectionProtocol: Sendable {
    var localAddress: SocketAddress? { get }
    var remoteAddress: SocketAddress { get }
    var currentRemoteAddress: SocketAddress { get }  // connection migration対応
    var isEstablished: Bool { get }

    func openStream() async throws -> any QUICStreamProtocol
    func openUniStream() async throws -> any QUICStreamProtocol

    /// Stream of incoming streams (single-consumer)
    var incomingStreams: AsyncStream<any QUICStreamProtocol> { get }

    func close(error: UInt64?) async
}
```

**Note**: There is no `acceptStream()` method. Use `incomingStreams` to receive
streams initiated by the remote peer.

## Implementation Status

### Completed Features

| Component | Feature | Status |
|-----------|---------|--------|
| **QUICTransport** | dialSecured() | ✅ |
| | listenSecured() | ✅ |
| | canDial()/canListen() | ✅ |
| **QUICMuxedConnection** | StreamChannel buffering | ✅ |
| | newStream() | ✅ |
| | acceptStream() | ✅ |
| | inboundStreams | ✅ |
| | Multiple streams per connection | ✅ |
| **QUICMuxedStream** | read()/write() | ✅ |
| | closeWrite()/closeRead() | ✅ |
| | close()/reset() | ✅ |
| **QUICListener** | connections stream | ✅ |
| | startAccepting() | ✅ |
| **TLS** | SwiftQUICTLSProvider | ✅ |
| | libp2p certificate extension | ✅ |
| | PeerID verification | ✅ |
| | Ed25519/ECDSA support | ✅ |

### Recently Completed

| Feature | Status | Notes |
|---------|--------|-------|
| 0-RTT connection establishment | ✅ | `ClientSessionCache`でセッションチケットをキャッシュ、`dialSecured`で自動的に0-RTTを試行 |
| Connection migration | ✅ | `QUICEndpoint.processIncomingPacket`でアドレス変更検出、`QUICMuxedConnection.remoteAddress`を動的プロパティ化 |
| QUIC hole punching | ✅ | `QUICHolePunchCoordinator`でNAT traversalタイミング制御、アドレス検証、メトリクス追跡 |

### Interop Status

| Feature | Status | Notes |
|---------|--------|-------|
| rust-libp2p interop baseline | ✅ | `Tests/Interop/Existing/RustInteropTests.swift` で connect/identify/ping 等を検証 |
| go-libp2p interop baseline | ✅ | `Tests/Interop/Existing/GoLibp2pInteropTests.swift` で connect/identify/ping 等を検証 |
| プロトコル別 interop スイート | ✅ | `Tests/Interop/Protocols/PingInteropTests.swift`, `IdentifyInteropTests.swift` |
| 高負荷・障害注入 interop | ⏳ | パケットロス/再順序/長時間運用のマトリクスは継続 |

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

## テスト実装状況

| テストファイル | テスト数 | 説明 |
|--------------|---------|------|
| `SwiftQUICTLSProviderTests.swift` | 12 | TLSプロバイダ、証明書検証 |
| `QUICTransportTests.swift` | 8 | トランスポート接続、マルチアドレス |
| `QUICE2ETests.swift` | 20 | E2E接続、マルチストリーム |
| `MultiaddrConversionTests.swift` | 8 | アドレス変換 |
| `QuickDebugTest.swift` | 7 | デバッグ用テスト |
| `QUICHolePunchTests.swift` | 29 | ホールパンチ設定、アドレス検証、エラー、並行安全性 |

**合計: 84テスト** (2026-02-08時点)

## References

- [libp2p QUIC Specification](https://github.com/libp2p/specs/tree/master/quic)
- [libp2p TLS Specification](https://github.com/libp2p/specs/blob/master/tls/tls.md)
- [RFC 9000: QUIC](https://www.rfc-editor.org/rfc/rfc9000.html)
- [RFC 9001: Using TLS to Secure QUIC](https://www.rfc-editor.org/rfc/rfc9001.html)
- [RFC 9002: Loss Detection and Congestion Control](https://www.rfc-editor.org/rfc/rfc9002.html)

<!-- CONTEXT_EVAL_START -->
## 実装評価 (2026-02-16)

- 総合評価: **A** (92/100)
- 対象ターゲット: `P2PTransportQUIC`
- 実装読解範囲: 10 Swift files / 2133 LOC
- テスト範囲: 37 files / 234 cases / targets 4
- 公開API: types 15 / funcs 31
- 参照網羅率: type 0.6 / func 0.68
- 未参照公開型: 6 件（例: `CertificateMaterial`, `FailingTLSProvider`, `QUICListener`, `QUICMuxedStream`, `QUICSecuredListener`）
- 実装リスク指標: try?=0, forceUnwrap=0, forceCast=0, @unchecked Sendable=0, EventLoopFuture=0, DispatchQueue=0
- 評価所見: 重大な静的リスクは検出されず

### 重点アクション
- 未参照の公開型に対する直接テスト（生成・失敗系・境界値）を追加する。

※ 参照網羅率は「テストコード内での公開API名参照」を基準にした静的評価であり、動的実行結果そのものではありません。

<!-- CONTEXT_EVAL_END -->
