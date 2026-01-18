# Package Responsibilities

## Design Philosophy: Modular & Composable

ユーザーは必要な技術だけを選択して組み合わせられる。

**重要な原則:**
- P2PCore は最小限に保つ（太ると破壊的変更が増える）
- Protocol定義と実装を分離
- 実装モジュールは Protocol定義モジュールのみに依存

## Overview

```
┌─────────────────────────────────────────────────────────────┐
│                      User Application                        │
├─────────────────────────────────────────────────────────────┤
│  P2P (統合層 - Protocol依存のみ、実装依存なし)              │
├──────────────┬──────────────┬──────────────┬───────────────┤
│ P2PTransport │ P2PSecurity  │   P2PMux     │ P2PDiscovery  │
│  (Protocol)  │  (Protocol)  │  (Protocol)  │  (Protocol)   │
├──────────────┼──────────────┼──────────────┼───────────────┤
│     TCP      │    Noise     │   Yamux      │    SWIM       │
│     QUIC     │  Plaintext   │   Mplex      │   CYCLON      │
│    Memory    │              │              │   Plumtree    │
├──────────────┴──────────────┴──────────────┴───────────────┤
│                      P2PCore                                 │
│    (最小限の共通抽象: PeerID, Multiaddr, Connection)         │
└─────────────────────────────────────────────────────────────┘

選択例:
├── TCP + Noise + Yamux → Go/Rust互換の標準構成
├── QUIC + Yamux → 高性能構成（SecurityはQUIC内蔵）
├── Memory + Plaintext + Yamux → テスト用
└── TCP + Noise + Yamux + SWIM → フル機能
```

---

## Directory Structure (Plan C: Monorepo + Grouped Targets)

```
swift-libp2p/
Sources/
├── Core/
│   └── P2PCore/                 # 最小限の共通抽象のみ
│       ├── Identity/            # PeerID, PublicKey, KeyPair
│       ├── Addressing/          # Multiaddr
│       ├── Connection/          # RawConnection, SecuredConnection (protocols)
│       └── Utilities/           # Varint, Base58, Multihash
│
├── Transport/
│   ├── P2PTransport/            # Protocol定義のみ (NIO依存なし)
│   ├── TCP/                     # P2PTransportTCP (NIO依存)
│   ├── QUIC/                    # P2PTransportQUIC (将来)
│   └── Memory/                  # P2PTransportMemory (テスト用)
│
├── Security/
│   ├── P2PSecurity/             # Protocol定義のみ
│   ├── Noise/                   # P2PSecurityNoise
│   └── Plaintext/               # P2PSecurityPlaintext (テスト用)
│
├── Mux/
│   ├── P2PMux/                  # Protocol定義のみ
│   ├── Yamux/                   # P2PMuxYamux
│   └── Mplex/                   # P2PMuxMplex (将来)
│
├── Negotiation/
│   └── P2PNegotiation/          # multistream-select
│
├── Discovery/
│   ├── P2PDiscovery/            # Protocol定義のみ
│   ├── SWIM/                    # P2PDiscoverySWIM
│   ├── CYCLON/                  # P2PDiscoveryCYCLON (将来)
│   └── Plumtree/                # P2PDiscoveryPlumtree (将来)
│
└── Integration/
    └── P2P/                     # 統合層 (Protocol依存のみ)

Tests/
├── Core/P2PCoreTests/
├── Transport/P2PTransportTests/
├── Security/P2PSecurityTests/
├── Mux/P2PMuxTests/
├── Negotiation/P2PNegotiationTests/
├── Discovery/P2PDiscoveryTests/
└── Integration/P2PTests/
```

---

## 依存関係グラフ

```
                    ┌─────────────────────────────────────────┐
                    │              P2PCore                     │
                    │  (PeerID, Multiaddr, RawConnection,     │
                    │   SecuredConnection, SecurityRole)       │
                    └─────────────────────────────────────────┘
                                      ▲
          ┌───────────────────────────┼───────────────────────────┐
          │                           │                           │
          │                           │                           │
┌─────────┴─────────┐   ┌─────────────┴───────────┐   ┌──────────┴──────────┐
│   P2PTransport    │   │      P2PSecurity        │   │      P2PMux         │
│   (Transport,     │   │   (SecurityUpgrader)    │   │  (Muxer, MuxedConn, │
│    Listener)      │   │                         │   │   MuxedStream)      │
└─────────┬─────────┘   └─────────────┬───────────┘   └──────────┬──────────┘
          │                           │                           │
          ▼                           ▼                           ▼
┌─────────────────┐     ┌─────────────────────┐     ┌─────────────────────┐
│ P2PTransportTCP │     │  P2PSecurityNoise   │     │   P2PMuxYamux       │
│   (+ NIO)       │     │    (+ Crypto)       │     │                     │
└─────────────────┘     └─────────────────────┘     └─────────────────────┘

                    ┌─────────────────────────────────────────┐
                    │              P2PNegotiation              │
                    │         (multistream-select)             │
                    └─────────────────────────────────────────┘
                                      ▲
                                      │
                    ┌─────────────────┴─────────────────┐
                    │            P2PDiscovery           │
                    │    (DiscoveryService, etc.)       │
                    └─────────────────┬─────────────────┘
                                      │
                                      ▼
                    ┌─────────────────────────────────────────┐
                    │          P2PDiscoverySWIM               │
                    └─────────────────────────────────────────┘

                    ┌─────────────────────────────────────────┐
                    │                 P2P                      │
                    │  (Node, NodeBuilder - Protocol依存のみ)  │
                    └─────────────────────────────────────────┘
```

---

## Package Details

### P2PCore (必須・最小限)

**責務**: 最小限の共通抽象のみ

| カテゴリ | 型 | 責務 |
|---------|-----|------|
| **Identity** | `PeerID` | ピアの一意識別子（公開鍵由来） |
| | `PublicKey` | 公開鍵の表現 |
| | `PrivateKey` | 秘密鍵の表現 |
| | `KeyPair` | 鍵ペア |
| | `KeyType` | 鍵種別（Ed25519, Secp256k1等） |
| **Addressing** | `Multiaddr` | 自己記述型ネットワークアドレス |
| | `MultiaddrProtocol` | アドレスプロトコルコンポーネント |
| **Connection** | `RawConnection` | 生のネットワーク接続 (protocol) |
| | `SecuredConnection` | 暗号化された接続 (protocol) |
| | `SecurityRole` | initiator / responder |
| **Utilities** | `Varint` | 可変長整数エンコーディング |
| | `Multihash` | 自己記述型ハッシュ |
| | `Base58` | Base58エンコーディング |

**依存関係:**
- `swift-crypto` (暗号プリミティブ)
- `swift-log` (ロギング)

**含まないもの:**
- Transport/Security/Mux の Protocol定義（各モジュールへ）
- ネットワーク通信の実装
- 状態管理（ConnectionPool等）

---

### P2PTransport (Protocol定義)

**責務**: Transport抽象の定義のみ（NIO依存なし）

```swift
public protocol Transport: Sendable {
    var protocols: [[String]] { get }
    func dial(_ address: Multiaddr) async throws -> any RawConnection
    func listen(_ address: Multiaddr) async throws -> any Listener
    func canDial(_ address: Multiaddr) -> Bool
}

public protocol Listener: Sendable {
    var localAddress: Multiaddr { get }
    func accept() async throws -> any RawConnection
    func close() async throws
}
```

**依存関係:** P2PCore のみ

---

### P2PTransportTCP (実装)

**責務**: SwiftNIO を使用したTCP実装

**依存関係:**
- P2PTransport
- swift-nio (NIOCore, NIOPosix)

**パス:** `Sources/Transport/TCP`

---

### P2PTransportMemory (実装)

**責務**: テスト用インメモリ実装

**依存関係:** P2PTransport のみ

**パス:** `Sources/Transport/Memory`

---

### P2PSecurity (Protocol定義)

**責務**: Security抽象の定義のみ

```swift
public protocol SecurityUpgrader: Sendable {
    var protocolID: String { get }
    func secure(
        _ connection: any RawConnection,
        localKeyPair: KeyPair,
        as role: SecurityRole,
        expectedPeer: PeerID?
    ) async throws -> any SecuredConnection
}
```

**依存関係:** P2PCore のみ

---

### P2PSecurityNoise (実装)

**責務**: Noise XX パターンの実装

**プロトコルID:** `/noise`

**依存関係:**
- P2PSecurity
- swift-crypto

**パス:** `Sources/Security/Noise`

---

### P2PMux (Protocol定義)

**責務**: Muxer抽象の定義のみ

```swift
public protocol Muxer: Sendable {
    var protocolID: String { get }
    func multiplex(
        _ connection: any SecuredConnection,
        isInitiator: Bool
    ) async throws -> MuxedConnection
}

public protocol MuxedConnection: Sendable {
    var localPeer: PeerID { get }
    var remotePeer: PeerID { get }
    func newStream() async throws -> MuxedStream
    var inboundStreams: AsyncStream<MuxedStream> { get }
    func close() async throws
}

public protocol MuxedStream: Sendable {
    var id: UInt64 { get }
    func read() async throws -> Data
    func write(_ data: Data) async throws
    func close() async throws
}
```

**依存関係:** P2PCore のみ

---

### P2PMuxYamux (実装)

**責務**: Yamux multiplexer の実装

**プロトコルID:** `/yamux/1.0.0`

**依存関係:** P2PMux のみ

**パス:** `Sources/Mux/Yamux`

---

### P2PNegotiation

**責務**: multistream-select プロトコル

```swift
public enum MultistreamSelect {
    public static let protocolID = "/multistream/1.0.0"

    public static func select(
        protocols: [String],
        on stream: AsyncReadWrite
    ) async throws -> String

    public static func handle(
        supported: [String],
        on stream: AsyncReadWrite
    ) async throws -> String
}
```

**依存関係:** P2PCore のみ

---

### P2PDiscovery (Protocol定義)

**責務**: Discovery抽象の定義のみ

```swift
public protocol MembershipService: Sendable {
    func join(bootstrap: [Multiaddr]) async throws
    func leave() async throws
    var members: AsyncStream<MembershipEvent> { get }
}

public protocol PeerSampler: Sendable {
    func sample(count: Int) async throws -> [PeerID]
}

public protocol Disseminator: Sendable {
    func broadcast(_ message: Data, topic: String) async throws
    func subscribe(topic: String) -> AsyncStream<(Data, PeerID)>
}
```

**依存関係:** P2PCore のみ

---

### P2PDiscoverySWIM (実装)

**責務**: SWIM membership protocol の実装

**依存関係:** P2PDiscovery のみ

**パス:** `Sources/Discovery/SWIM`

---

### P2P (統合層)

**責務**: 統合エントリーポイント（Protocol依存のみ、実装依存なし）

```swift
public struct NodeConfiguration: Sendable {
    public var keyPair: KeyPair
    public var listenAddresses: [Multiaddr]
    public var transport: any Transport
    public var security: any SecurityUpgrader
    public var muxer: any Muxer
}

public actor Node {
    public init(configuration: NodeConfiguration)
    public func start() async throws
    public func stop() async
    public func connect(to address: Multiaddr) async throws
}
```

**依存関係:**
- P2PCore
- P2PTransport (Protocol)
- P2PSecurity (Protocol)
- P2PMux (Protocol)
- P2PNegotiation
- P2PDiscovery (Protocol)

**含まないもの:**
- 具体的な実装（TCP, Noise, Yamux等）への依存

---

## Package.swift での指定例

```swift
// Protocol定義モジュール（依存最小）
.target(
    name: "P2PTransport",
    dependencies: ["P2PCore"],
    path: "Sources/Transport/P2PTransport"
),

// 実装モジュール（Protocol定義に依存）
.target(
    name: "P2PTransportTCP",
    dependencies: [
        "P2PTransport",
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"),
    ],
    path: "Sources/Transport/TCP"
),
```

---

## ユーザーの使用例

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/libp2p/swift-libp2p", from: "1.0.0"),
]

// 必要なものだけ選択
.target(
    name: "MyApp",
    dependencies: [
        .product(name: "P2PCore", package: "swift-libp2p"),
        .product(name: "P2PTransportTCP", package: "swift-libp2p"),
        .product(name: "P2PSecurityNoise", package: "swift-libp2p"),
        .product(name: "P2PMuxYamux", package: "swift-libp2p"),
    ]
)
```

```swift
// MyApp.swift
import P2PCore
import P2PTransportTCP
import P2PSecurityNoise
import P2PMuxYamux

let transport = TCPTransport()
let security = NoiseUpgrader()
let muxer = YamuxMuxer()

let node = Node(configuration: .init(
    keyPair: .generateEd25519(),
    listenAddresses: [.tcp(host: "0.0.0.0", port: 4001)],
    transport: transport,
    security: security,
    muxer: muxer
))
```

---

## rust-libp2p との比較

| 観点 | rust-libp2p | swift-libp2p |
|------|-------------|--------------|
| **Core** | `libp2p-core` | `P2PCore` |
| **Swarm** | `libp2p-swarm` | `P2P` (統合層) |
| **Transport** | `libp2p-tcp`, `libp2p-quic` | `P2PTransportTCP`, etc. |
| **Security** | `libp2p-noise`, `libp2p-tls` | `P2PSecurityNoise`, etc. |
| **Muxer** | `libp2p-yamux`, `libp2p-mplex` | `P2PMuxYamux`, etc. |
| **Protocol分離** | trait + impl crate | Protocol module + impl module |
| **非同期** | async-std/tokio | Swift Concurrency (async/await) |
| **状態管理** | Mutex/RwLock | class + OSAllocatedUnfairLock |

---

## Wire Protocol Compatibility

Go/Rust互換のために必須のプロトコルID:

| コンポーネント | プロトコルID |
|---------------|-------------|
| multistream-select | `/multistream/1.0.0` |
| Noise | `/noise` |
| Yamux | `/yamux/1.0.0` |
| Mplex | `/mplex/6.7.0` |
| Identify | `/ipfs/id/1.0.0` |
| Ping | `/ipfs/ping/1.0.0` |
