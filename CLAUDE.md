# swift-libp2p Design Principles

> **Project**: swift-libp2p - A modern Swift implementation of the libp2p networking stack
> **Goal**: Wire-protocol compatible with Go/Rust libp2p, designed with modern Swift idioms

## ディレクトリ読み取りルール

**重要**: ディレクトリ配下のコードを読む際は、必ず先にそのディレクトリの`CONTEXT.md`を読むこと。

例:
- `Sources/Transport/` を読む前に → `Sources/Transport/CONTEXT.md`
- `Sources/Security/Noise/` を読む前に → `Sources/Security/Noise/CONTEXT.md`
- `Sources/Core/P2PCore/` を読む前に → `Sources/Core/P2PCore/CONTEXT.md`

---

## Overview

This is a clean-room implementation of libp2p specifications in Swift. We reference the official libp2p specs but do NOT depend on the existing swift-libp2p codebase due to its code quality concerns.

## Core Design Principles

> **設計原則**: async/await を全面採用。EventLoopFuture は使わない。

### 1. Value Types First (struct > class)

```swift
// GOOD: Use struct for data
struct ConnectionState: Sendable {
    let id: ConnectionID
    let localPeer: PeerID
    let remotePeer: PeerID
    var status: Status
}

// BAD: Avoid class for simple data containers
class ConnectionState { ... }  // Don't do this
```

**When to use class:**
- When reference semantics are required for shared mutable state
- SwiftNIO Channel handlers (framework requirement)
- Resource management (connections, streams)

### 2. Concurrency Model: Actor vs Class + Mutex

**使い分けの原則:**

| 基準 | Actor | Class + Mutex |
|-----|-------|---------------|
| **操作頻度** | 低頻度 | 高頻度 |
| **処理時間** | 重い（I/O等） | 軽い |
| **用途** | ユーザー向けAPI | 内部実装 |

**なぜ全てにActorを使わないのか:**
- Actor は全アクセスを直列化 → 高頻度操作でボトルネック
- 呼び出しごとに actor hop のオーバーヘッド
- 独立した操作も直列化されてしまう

**class + mutex の利点:**
- ロックを最小限に → スループット向上
- 必要な部分だけロック、すぐ解放
- 独立した操作は並列実行可能

#### Actor: 低頻度 + 重い処理 + ユーザーAPI

```swift
// GOOD: Node - 操作頻度が低く、実処理時間 >> actor hop
public actor Node {
    // start(), stop(), connect() は頻繁に呼ばれない
    // ネットワークI/Oの時間に比べればhopは無視できる
    public func start() async throws { ... }
    public func stop() async { ... }
    public func connect(to address: Multiaddr) async throws -> PeerID { ... }
}
```

#### Class + Mutex: 高頻度 + 軽い処理 + 内部実装

```swift
import Synchronization

// GOOD: Connection - read/writeは高頻度、ロック最小化が重要
final class TCPConnection: RawConnection, Sendable {
    private let state = Mutex<ConnectionState>(.initial)

    func read() async throws -> Data {
        // ロックは状態確認時のみ、I/O中は解放
    }
}

// GOOD: Pool - 高頻度アクセス、細粒度ロック
final class ConnectionPool: Sendable {
    private let connections = Mutex<[ConnectionID: ConnectionState]>([:])

    func add(_ state: ConnectionState) {
        connections.withLock {
            $0[state.id] = state
        }
        // ロックはすぐ解放、他の操作をブロックしない
    }
}
```

**判断フロー:**
1. 高頻度アクセス? → class + mutex
2. ユーザー向けAPI? → actor
3. 処理時間が長い（I/O等）? → actor でも OK
4. 迷ったら → class + mutex（後からactorに変更は難しい）

### 3. Protocol-Oriented Design

Design around protocols first. Every major component should be defined as a protocol, with implementations provided separately.

```swift
// GOOD: Protocol defines the contract
public protocol Transport: Sendable {
    func dial(_ address: Multiaddr) async throws -> any RawConnection
    func listen(_ address: Multiaddr) async throws -> AsyncStream<any RawConnection>
    func canDial(_ address: Multiaddr) -> Bool
}

public protocol RawConnection: Sendable {
    var localAddress: Multiaddr? { get }
    var remoteAddress: Multiaddr { get }
    func read() async throws -> Data
    func write(_ data: Data) async throws
    func close() async throws
}

// Implementation is separate
public final class TCPTransport: Transport {
    // Implementation details
}

// Protocol composition for extended functionality
public protocol SecureTransport: Transport {
    var securityProtocol: String { get }
}

// BAD: Starting with concrete class
public class TCPTransport {  // No protocol = hard to test/mock
    func dial(_ address: Multiaddr) async throws -> TCPConnection { ... }
}
```

**Protocol Design Rules:**
- Define protocols for all public interfaces
- Use `any` keyword for protocol existentials
- Prefer protocol composition over inheritance
- Keep protocols focused (single responsibility)

### 4. Single Responsibility Per File

Each file should contain exactly one primary type (struct, class, protocol, or enum).

```
GOOD:
├── PeerID.swift           # Contains only struct PeerID
├── PublicKey.swift        # Contains only struct PublicKey
├── PrivateKey.swift       # Contains only struct PrivateKey
├── KeyPair.swift          # Contains only struct KeyPair
├── Transport.swift        # Contains only protocol Transport
├── TCPTransport.swift     # Contains only class TCPTransport

BAD:
├── Identity.swift         # Contains PeerID, PublicKey, PrivateKey, KeyPair
├── Types.swift            # Contains multiple unrelated types
```

**Exceptions:**
- Closely related helper types (e.g., Error enum for a type)
- Protocol + its default extension in same file
- Small private types used only by the main type

### 5. async/await Everywhere

```swift
// GOOD: async/await throughout
public func connect(to peer: PeerID) async throws -> Connection {
    let raw = try await transport.dial(peer.address)
    let secured = try await security.secure(raw)
    return try await muxer.multiplex(secured)
}

// GOOD: Use NIOAsyncChannel for NIO integration
// SwiftNIO 2.x supports async/await natively
let asyncChannel = try await NIOAsyncChannel(wrappingChannelSynchronously: channel)
for try await data in asyncChannel.inbound {
    // Process data
}

// BAD: Don't use EventLoopFuture
func dialInternal(_ address: Multiaddr) -> EventLoopFuture<Channel>  // Don't use
```

### 6. Sendable Compliance

**原則: `Sendable` で済むなら `@unchecked Sendable` は使わない**

Swift 6の`Mutex<T>`を使えば、可変状態があっても`@unchecked Sendable`は不要。

```swift
// GOOD: struct/enumは自動的にSendable（全プロパティがSendableなら）
public struct PeerID: Sendable, Hashable { ... }
public struct Multiaddr: Sendable, Hashable { ... }

// GOOD: protocolはSendableを継承
public protocol Transport: Sendable { ... }

// GOOD: 不変のfinal classはSendableだけでOK
public final class ImmutableConfig: Sendable {
    let timeout: Duration
    let maxConnections: Int
}

// GOOD: Mutex<T>を使えば可変状態があってもSendable
public final class ConnectionManager: Sendable {
    private let connections = Mutex<[ConnectionID: Connection]>([:])

    func add(_ conn: Connection) {
        connections.withLock { $0[conn.id] = conn }
    }
}

// BAD: @unchecked Sendableは基本的に使わない
public final class ConnectionManager: @unchecked Sendable {  // 避ける
    private let lock = OSAllocatedUnfairLock()
    private var connections: [ConnectionID: Connection] = [:]
}
```

#### Mutex + CheckedContinuation パターン

非同期待機が必要な場合、`Mutex<T>` と `CheckedContinuation` を組み合わせる。

**重要**: 状態チェックとcontinuation設定は必ずアトミックに行うこと。

```swift
import Synchronization

final class AsyncBuffer: Sendable {
    private let state = Mutex<State>(State())

    private struct State: Sendable {
        var buffer: [Data] = []
        var isClosed: Bool = false
        var waitingContinuation: CheckedContinuation<Data, any Error>?
    }

    /// データを受信（外部から呼ばれる）
    func receive(_ data: Data) {
        state.withLock { state in
            if let continuation = state.waitingContinuation {
                state.waitingContinuation = nil
                continuation.resume(returning: data)
            } else {
                state.buffer.append(data)
            }
        }
    }

    /// データを読み取り（バッファが空なら待機）
    func read() async throws -> Data {
        // GOOD: 全ての状態チェックをアトミックに行う
        return try await withCheckedThrowingContinuation { continuation in
            state.withLock { s in
                if !s.buffer.isEmpty {
                    continuation.resume(returning: s.buffer.removeFirst())
                } else if s.isClosed {
                    continuation.resume(returning: Data())  // EOF
                } else {
                    s.waitingContinuation = continuation
                }
            }
        }
    }

    // BAD: レース条件あり - 使わないこと
    func readWithRaceCondition() async throws -> Data {
        // 問題1: チェックとcontinuation設定の間にレースがある
        let closed = state.withLock { $0.isClosed }  // ← ここでロック解放
        if closed { return Data() }
        // ↑ この間に close() が呼ばれるとcontinuationが永久にブロック

        return try await withCheckedThrowingContinuation { continuation in
            state.withLock { s in
                // 問題2: 最初のチェックで確認した条件が変わっている可能性
                if !s.buffer.isEmpty {
                    continuation.resume(returning: s.buffer.removeFirst())
                } else {
                    s.waitingContinuation = continuation  // 永久にresumeされない可能性
                }
            }
        }
    }

    func close() {
        state.withLock { s in
            s.isClosed = true
            if let continuation = s.waitingContinuation {
                s.waitingContinuation = nil
                continuation.resume(returning: Data())  // 待機中のreadを解放
            }
        }
    }
}
```

**ポイント:**
- `withLock` 内で `async` 関数を呼ばない
- `CheckedContinuation` を状態に保存して後で resume
- resume は1回だけ（複数回呼ぶとクラッシュ）
- **状態チェックとcontinuation設定は必ず同じロック内で行う**（レース条件防止）

#### AsyncStream の終了ルール

**重要**: `AsyncStream` を公開するサービスは必ず `shutdown()` メソッドを実装し、`continuation.finish()` を呼ぶこと。

```swift
// GOOD: shutdown()でAsyncStreamを正しく終了
public final class MyService: Sendable {
    private let state = Mutex<ServiceState>(ServiceState())

    private struct ServiceState: Sendable {
        var eventContinuation: AsyncStream<MyEvent>.Continuation?
        var eventStream: AsyncStream<MyEvent>?
    }

    public var events: AsyncStream<MyEvent> {
        state.withLock { s in
            if let existing = s.eventStream { return existing }
            let (stream, continuation) = AsyncStream<MyEvent>.makeStream()
            s.eventStream = stream
            s.eventContinuation = continuation
            return stream
        }
    }

    /// サービスをシャットダウンしてイベントストリームを終了
    public func shutdown() {
        state.withLock { s in
            s.eventContinuation?.finish()  // ← 必須！これがないとfor awaitがハング
            s.eventContinuation = nil
            s.eventStream = nil
        }
    }
}

// BAD: shutdown()がないとfor await event in service.eventsが永久にブロック
public final class BadService: Sendable {
    // eventContinuation.finish()を呼ぶ場所がない → テストがハング
}
```

**テストでの使用:**
```swift
@Test("Service emits events")
func testEvents() async throws {
    let service = MyService()

    let eventTask = Task {
        for await event in service.events {
            // イベント処理
            if case .completed = event { break }
        }
    }

    // テスト実行...

    service.shutdown()  // ← 必須！これがないとeventTaskが終了しない
    eventTask.cancel()
}
```

**なぜ必要か:**
- `for await event in stream` は `continuation.finish()` が呼ばれるまでブロックする
- `Task.cancel()` だけでは不十分（AsyncStreamはキャンセルを自動伝播しない）
- `shutdown()` がないとテストプロセスがバックグラウンドで残り続ける

### 7. Explicit Error Handling

```swift
// GOOD: Explicit, typed errors
public enum ConnectionError: Error {
    case timeout(Duration)
    case securityHandshakeFailed(underlying: Error)
    case muxerNegotiationFailed
    case addressUnreachable(Multiaddr)
}

public func connect() async throws -> Connection  // Document which errors

// BAD: Swallowing errors
let addr = try? channel.localAddress?.toMultiaddr()  // Don't swallow
```

### 8. Dependency Injection via Protocols

```swift
// GOOD: Injectable dependencies via protocols
// Node is an actor (outermost layer communicating with external peers)
public actor Node {
    private let transport: any Transport
    private let security: any SecurityUpgrader
    private let muxer: any Muxer

    public init(
        transport: any Transport,
        security: any SecurityUpgrader,
        muxer: any Muxer
    ) {
        self.transport = transport
        self.security = security
        self.muxer = muxer
    }
}

// Factory for convenience
public struct NodeBuilder {
    public static func makeDefault() -> Node {
        Node(
            transport: TCPTransport(),
            security: NoiseUpgrader(),
            muxer: YamuxMuxer()
        )
    }
}

// BAD: Hard-coded dependencies
public actor Node {
    private let transport = TCPTransport()  // Not testable
}
```

## Architecture Layers

```
┌─────────────────────────────────────────────────────────┐
│  Application / Discovery Layer                          │
│  (Observation, SWIM, CYCLON, Plumtree, Scoring)        │
├─────────────────────────────────────────────────────────┤
│  Protocol Negotiation (multistream-select)              │
├─────────────────────────────────────────────────────────┤
│  Stream Multiplexing (Yamux, Mplex)                     │
├─────────────────────────────────────────────────────────┤
│  Security (Noise IK)                                    │
├─────────────────────────────────────────────────────────┤
│  Transport (TCP, QUIC, BLE, LoRa)                       │
├─────────────────────────────────────────────────────────┤
│  Core Types (PeerID, Multiaddr, Envelope)               │
└─────────────────────────────────────────────────────────┘
```

## Module Structure (Plan C: Monorepo + Grouped Targets)

**Design Principles:**
- P2PCore は最小限に（太ると破壊的変更が増える）
- Protocol定義と実装を分離
- 実装は別ターゲットとしてpath指定

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
│   └── Mplex/                   # P2PMuxMplex
│
├── Negotiation/
│   └── P2PNegotiation/          # multistream-select
│
├── Discovery/
│   ├── P2PDiscovery/            # Protocol定義のみ
│   ├── SWIM/                    # P2PDiscoverySWIM
│   ├── CYCLON/                  # P2PDiscoveryCYCLON
│   └── Plumtree/                # P2PDiscoveryPlumtree
│
└── Integration/
    └── P2P/                     # 統合層 (Protocol依存のみ、実装依存なし)

Tests/
├── Core/P2PCoreTests/
├── Transport/P2PTransportTests/
├── Security/P2PSecurityTests/
├── Mux/P2PMuxTests/
├── Negotiation/P2PNegotiationTests/
├── Discovery/P2PDiscoveryTests/
└── Integration/P2PTests/
```

**依存グラフ:**
```
P2PCore ←─┬─ P2PTransport ←── P2PTransportTCP
          ├─ P2PSecurity ←── P2PSecurityNoise
          ├─ P2PMux ←────── P2PMuxYamux
          ├─ P2PNegotiation
          ├─ P2PDiscovery ←─ P2PDiscoverySWIM
          └─ P2P (統合層: Protocol依存のみ)
```

## Related Packages

swift-libp2p エコシステムを構成する関連パッケージ:

### swift-nio-udp

**場所**: `/Users/1amageek/Desktop/swift-nio-udp`

SwiftNIOベースのクロスプラットフォームUDPトランスポート。

```swift
// ユニキャスト (SWIM用)
let transport = NIOUDPTransport(configuration: .unicast(port: 7946))
try await transport.start()
try await transport.send(data, to: address)

// マルチキャスト (mDNS用)
let mdns = NIOUDPTransport(configuration: .multicast(port: 5353))
try await mdns.joinMulticastGroup("224.0.0.251", on: nil)
```

**主要な型:**
- `UDPTransport` - プロトコル定義
- `MulticastCapable` - マルチキャスト拡張プロトコル
- `NIOUDPTransport` - SwiftNIO実装
- `UDPConfiguration` - 設定 (`.unicast()`, `.multicast()`)

### swift-mDNS

**場所**: `/Users/1amageek/Desktop/swift-mDNS`

mDNS/DNS-SDによるローカルネットワークサービス発見。

```swift
// サービスブラウズ
let browser = ServiceBrowser()
for await service in browser.browse(type: "_http._tcp", domain: "local.") {
    print("Found: \(service.name)")
}

// サービス広告
let advertiser = ServiceAdvertiser()
try await advertiser.advertise(service)
```

**用途**: P2PDiscoveryMDNS で利用（ローカルネットワーク内のピア発見）

### swift-SWIM

**場所**: `/Users/1amageek/Desktop/swift-SWIM`

SWIMプロトコル（Scalable Weakly-consistent Infection-style Membership）の実装。

```swift
let transport = SWIMUDPTransport(...)  // swift-nio-udp を使用
let swim = SWIMInstance(
    localMember: Member(id: MemberID(id: "node1", address: "127.0.0.1:7946")),
    config: .default,
    transport: transport
)

swim.start()
try await swim.join(seeds: [seedMemberID])

for await event in swim.events {
    switch event {
    case .memberJoined(let m): print("Joined: \(m)")
    case .memberFailed(let m): print("Failed: \(m)")
    default: break
    }
}
```

**主要な型:**
- `SWIMInstance` - メインactor
- `Member`, `MemberID` - メンバー識別
- `SWIMTransport` - トランスポートプロトコル
- `SWIMEvent` - メンバーシップイベント

**用途**: P2PDiscoverySWIM で利用（分散システムのメンバーシップ管理）

### パッケージ間の依存関係

```
swift-nio-udp (UDP transport layer)
    │
    ├──▶ swift-mDNS (uses MulticastCapable)
    │       │
    │       └──▶ swift-libp2p/P2PDiscoveryMDNS
    │
    └──▶ swift-SWIM (uses UDPTransport)
            │
            └──▶ swift-libp2p/P2PDiscoverySWIM
```

**Package.swift での path 指定例:**
```swift
.target(
    name: "P2PTransportTCP",
    dependencies: ["P2PTransport", ...],
    path: "Sources/Transport/TCP"
)
```

## Reference Implementation: rust-libp2p

**rust-libp2p is the gold standard implementation.** Always refer to it for:
- Wire protocol formats
- Protocol negotiation behavior
- Test vectors
- Architecture patterns

**DeepWiki Reference**: https://deepwiki.com/libp2p/rust-libp2p

### rust-libp2p Architecture (Reference)

```
┌─────────────────────────────────────────────────────────────┐
│  NetworkBehaviour (protocol logic: what/to whom)            │
├─────────────────────────────────────────────────────────────┤
│  Swarm (orchestration, connection pool)                     │
├─────────────────────────────────────────────────────────────┤
│  ConnectionHandler (per-connection protocol state)          │
├─────────────────────────────────────────────────────────────┤
│  StreamMuxer (Yamux/Mplex - logical streams)               │
├─────────────────────────────────────────────────────────────┤
│  Security Upgrade (Noise/TLS)                               │
├─────────────────────────────────────────────────────────────┤
│  Transport (TCP/QUIC/WebSocket)                             │
└─────────────────────────────────────────────────────────────┘
```

### Key Traits Mapping (Rust → Swift)

| rust-libp2p | swift-libp2p | Notes |
|-------------|--------------|-------|
| `Transport` | `Transport` | Establishes connections |
| `StreamMuxer` | `Muxer` | Multiplexes streams |
| `NetworkBehaviour` | `Behaviour` (future) | Protocol logic |
| `ConnectionHandler` | `ConnectionHandler` (future) | Per-connection state |

## Wire Protocol IDs

**Critical for Go/Rust interoperability:**

```swift
// Protocol IDs (MUST match exactly)
enum ProtocolID {
    // Negotiation
    static let multistreamSelect = "/multistream/1.0.0"

    // Security
    static let noise = "/noise"
    static let plaintext = "/plaintext/2.0.0"

    // Multiplexing
    static let yamux = "/yamux/1.0.0"
    static let mplex = "/mplex/6.7.0"

    // Protocols
    static let identify = "/ipfs/id/1.0.0"
    static let identifyPush = "/ipfs/id/push/1.0.0"
    static let ping = "/ipfs/ping/1.0.0"
}
```

## Implementation Notes

### multistream-select

Protocol negotiation happens on every connection and substream:

```
Dialer                          Listener
  |                                |
  |----> /multistream/1.0.0\n ---->|
  |<---- /multistream/1.0.0\n <----|
  |----> /noise\n ---------------->|
  |<---- /noise\n <----------------|
  |     (protocol selected)        |
```

- Messages are newline-delimited (`\n`)
- Length prefix using unsigned varint
- V1Lazy allows 0-RTT for single protocol dialer

### Noise Handshake (XX pattern)

```
Initiator                       Responder
    |                               |
    |----> e ------------------------>|
    |<---- e, ee, s, es <-------------|
    |----> s, se ---------------------->|
    |     (session established)      |
```

- Use X25519 for DH
- Payload includes libp2p public key in handshake
- Derive PeerID from exchanged keys

### Yamux Framing

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|   Version (8) |     Type (8)  |          Flags (16)          |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                        Stream ID (32)                        |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                         Length (32)                          |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

- Version: 0
- Types: Data (0), WindowUpdate (1), Ping (2), GoAway (3)
- Flags: SYN (1), ACK (2), FIN (4), RST (8)

## Reference Specifications

Always refer to the official specs for wire protocol compatibility:

| Component | Spec URL |
|-----------|----------|
| PeerID | https://github.com/libp2p/specs/blob/master/peer-ids/peer-ids.md |
| Multiaddr | https://github.com/multiformats/multiaddr |
| multistream-select | https://github.com/multiformats/multistream-select |
| Noise | https://github.com/libp2p/specs/blob/master/noise/README.md |
| Yamux | https://github.com/hashicorp/yamux/blob/master/spec.md |
| Mplex | https://github.com/libp2p/specs/blob/master/mplex/README.md |
| Signed Envelope | https://github.com/libp2p/specs/blob/master/RFC/0002-signed-envelopes.md |
| Identify | https://github.com/libp2p/specs/blob/master/identify/README.md |

### rust-libp2p Source References

When implementing, cross-reference these rust-libp2p crates:

| Component | Crate | Path |
|-----------|-------|------|
| Core types | `libp2p-core` | `core/` |
| Swarm | `libp2p-swarm` | `swarm/` |
| TCP | `libp2p-tcp` | `transports/tcp/` |
| Noise | `libp2p-noise` | `transports/noise/` |
| Yamux | `libp2p-yamux` | `muxers/yamux/` |
| Identify | `libp2p-identify` | `protocols/identify/` |

## Coding Conventions

### Naming

```swift
// Types: UpperCamelCase
struct PeerID { }
protocol Transport { }
class ConnectionPool { }

// Functions/Properties: lowerCamelCase
func dial(_ address: Multiaddr) async throws -> Connection
var localPeer: PeerID { get }

// Constants: lowerCamelCase
let defaultTimeout: Duration = .seconds(30)

// Private properties: no underscore prefix (use access control)
private var connections: [ConnectionID: Connection]  // GOOD
private var _connections: [ConnectionID: Connection]  // BAD
```

### File Organization

```swift
// One primary type per file
// File name matches type name: PeerID.swift contains struct PeerID

// Extensions for protocol conformance can be in same file
// or in TypeName+ProtocolName.swift if large

// MARK: - comments to organize sections within a file
// MARK: - Public API
// MARK: - Internal
// MARK: - Private
```

### Documentation

```swift
/// Brief description of the type.
///
/// Longer description if needed, explaining the purpose
/// and usage of this type.
///
/// ## Example
/// ```swift
/// let peerID = try PeerID(publicKey: myKey)
/// ```
///
/// - Note: Any important notes
/// - SeeAlso: `PublicKey`, `KeyPair`
public struct PeerID: Sendable {

    /// Creates a PeerID from a public key.
    ///
    /// - Parameter publicKey: The public key to derive the PeerID from
    /// - Throws: `PeerIDError.invalidKey` if the key is malformed
    public init(publicKey: PublicKey) throws { ... }
}
```

## Testing Requirements

### Unit Tests
- Every public API must have unit tests
- Use protocols for dependency injection to enable mocking
- Test both success and error paths
- Use Swift Testing framework (`@Test`, `@Suite`)

### テスト実行ガイドライン

**重要**: テスト実行時は必ず以下のルールに従うこと。

#### 1. タイムアウト設定必須

テストコマンドには必ずタイムアウトを設定する（推奨: 30秒）:

```bash
# 特定のテストターゲットを30秒タイムアウトで実行
swift test --filter TargetName 2>&1 &
PID=$!
sleep 30
if ps -p $PID > /dev/null; then
    echo "TIMEOUT"
    kill $PID
fi
```

#### 2. 細粒度でテストを実行

問題を特定するため、テストは細かく分割して実行:

```bash
# BAD: 全テスト一括実行
swift test

# GOOD: モジュールごとに実行
swift test --filter P2PCoreTests
swift test --filter P2PMuxYamuxTests
swift test --filter P2PSecurityNoiseTests

# GOOD: 特定のテストスイートを実行
swift test --filter "YamuxFrameTests"

# GOOD: 特定のテスト関数を実行
swift test --filter "roundtripGoAwayFrame"
```

#### 3. ハングするテストの調査

テストがタイムアウトした場合:
1. そのモジュール内のテストスイートを個別に実行
2. 問題のスイートが特定できたら、個別テストを実行
3. AsyncStream、Task、continuation の未完了を疑う
4. `.timeLimit()` を追加してテスト自体にタイムアウトを設定

```swift
@Test("Potentially slow test", .timeLimit(.seconds(10)))
func potentiallySlowTest() async throws { ... }
```

#### 4. 並行ビルドの競合回避

SwiftPM は同時に1つしか実行できない:
```bash
# 他のSwiftPMプロセスを確認・停止
pkill -f "swift test"
pkill -f "swift build"
```

### Integration Tests
- Go/Rust interoperability tests are critical
- Test with actual go-libp2p and rust-libp2p nodes
- Verify wire protocol compatibility

### Test Naming

```swift
@Suite("PeerID Tests")
struct PeerIDTests {
    @Test("Create PeerID from Ed25519 public key")
    func createFromEd25519() throws { ... }

    @Test("Fails with invalid data")
    func failsWithInvalidData() throws { ... }
}
```

## Go/Rust Interoperability

The primary goal is wire-protocol compatibility with Go and Rust libp2p implementations.

### Verification Approach

1. **Unit tests**: Verify encoding/decoding matches spec
2. **Integration tests**: Actually connect to Go/Rust nodes
3. **Test vectors**: Use test vectors from libp2p specs where available

### Priority Order for Interop Testing

1. PeerID encoding/decoding
2. Multiaddr encoding/decoding
3. multistream-select negotiation
4. Noise handshake (IK pattern)
5. Yamux stream multiplexing
6. Identify protocol exchange

## Dependencies Policy

### Allowed Dependencies

```swift
// Apple official packages only for core functionality
.package(url: "https://github.com/apple/swift-nio.git", from: "2.91.0"),
.package(url: "https://github.com/apple/swift-crypto.git", from: "4.0.0"),
.package(url: "https://github.com/apple/swift-log.git", from: "1.8.0"),
.package(url: "https://github.com/apple/swift-protobuf.git", from: "1.33.0"),
```

### Minimizing External Dependencies

- Prefer implementing small utilities ourselves over adding dependencies
- Multibase/Multihash: Implement ourselves for control and simplicity
- No dependency on existing swift-libp2p packages

## Platform Support

```swift
platforms: [
    .macOS(.v26),
    .iOS(.v26),
    .tvOS(.v26),
    .watchOS(.v26),
    .visionOS(.v26),
]
```

Requires Swift 6.2+ (swift-tools-version: 6.2).

## Interoperability Testing Strategy

### Test with Real Implementations

rust-libp2p provides interoperability testing infrastructure:

```bash
# Run rust-libp2p test node
cargo run --example ping -- --listen /ip4/127.0.0.1/tcp/4001

# Connect from swift-libp2p
swift run swift-libp2p-example dial /ip4/127.0.0.1/tcp/4001/p2p/<peer-id>
```

### Test Matrix

| Protocol | rust-libp2p | go-libp2p | Priority |
|----------|-------------|-----------|----------|
| TCP + Noise + Yamux | ✓ | ✓ | P0 |
| QUIC | ✓ | ✓ | P1 |
| Identify | ✓ | ✓ | P0 |
| Ping | ✓ | ✓ | P0 |

### Common Interop Issues

1. **Varint encoding**: Ensure unsigned LEB128 format
2. **Protocol ID case sensitivity**: IDs are case-sensitive
3. **Noise prologue**: Must include multistream-select prefix
4. **Yamux window size**: Default 256KB, must handle backpressure
