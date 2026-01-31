# P2P Integration Layer

## 概要
swift-libp2pの統合エントリーポイント。Protocol依存のみ、実装依存なし。

## 責務
- Nodeのライフサイクル管理
- 接続の確立と管理（Connection-levelネゴシエーション含む）
- プロトコルハンドラの登録
- ストリームの作成とルーティング
- イベント通知

## 依存関係
- `P2PCore`
- `P2PTransport` (Protocol)
- `P2PSecurity` (Protocol)
- `P2PMux` (Protocol)
- `P2PNegotiation`
- `P2PDiscovery` (Protocol)

**含まないもの:**
- 具体的な実装（TCP, Noise, Yamux等）への依存

---

## ファイル構成

```
Sources/Integration/P2P/
├── P2P.swift                 # Node, NodeConfiguration, NodeEvent, DiscoveryConfiguration
├── ConnectionUpgrader.swift  # 接続アップグレードパイプライン (V1 Lazy対応)
├── Connection/               # 接続管理コンポーネント
│   ├── ConnectionPool.swift      # 接続プール（内部）
│   ├── ConnectionState.swift     # 接続状態マシン
│   ├── ConnectionLimits.swift    # 接続制限設定
│   ├── ConnectionGater.swift     # 接続フィルタリング
│   ├── HealthMonitor.swift       # ヘルスモニタリング
│   └── ...
└── Resource/                 # リソース管理 (GAP-9)
    ├── ResourceManager.swift             # ResourceManager プロトコル
    ├── DefaultResourceManager.swift      # デフォルト実装 (system/peer/protocol 3スコープ)
    ├── ResourceLimitsConfiguration.swift # リソース制限設定
    ├── ResourceSnapshot.swift            # スナップショット型
    ├── ResourceTrackedStream.swift       # 自動リソース解放ストリーム
    └── ScopeLimits.swift                 # スコープ別制限値
```

## 主要な型

| 型名 | 状態 | 説明 |
|-----|------|------|
| `Node` | ✅ Done | P2Pノードactor |
| `NodeConfiguration` | ✅ Done | ノード設定（全コンポーネント含む） |
| `NodeEvent` | ✅ Done | イベント通知 |
| `ConnectionUpgrader` | ✅ Done | アップグレードパイプライン抽象 |
| `NegotiatingUpgrader` | ✅ Done | multistream-select実装 |
| `UpgradeResult` | ✅ Done | アップグレード結果 |

---

## API

### NodeConfiguration
```swift
public struct NodeConfiguration: Sendable {
    public let keyPair: KeyPair
    public let listenAddresses: [Multiaddr]
    public let transports: [any Transport]      // 優先順
    public let security: [any SecurityUpgrader] // 優先順
    public let muxers: [any Muxer]              // 優先順
    public let pool: PoolConfiguration          // 接続プール設定
    public let healthCheck: HealthMonitorConfiguration?  // ヘルスチェック（nil=無効）
    public let discovery: (any DiscoveryService)?        // ディスカバリサービス
    public let discoveryConfig: DiscoveryConfiguration   // 自動接続設定
}
```

### DiscoveryConfiguration
```swift
public struct DiscoveryConfiguration: Sendable {
    public var autoConnect: Bool              // 自動接続の有効/無効
    public var maxAutoConnectPeers: Int       // 最大自動接続数
    public var autoConnectMinScore: Double    // 自動接続の最小スコア
    public var reconnectCooldown: Duration    // 再接続クールダウン
}
```

### Node
```swift
public actor Node {
    public init(configuration: NodeConfiguration)

    public var peerID: PeerID { get }
    public var connectedPeers: [PeerID] { get }
    public var connectionCount: Int { get }
    public var supportedProtocols: [String] { get }
    public var events: AsyncStream<NodeEvent> { get }

    // Lifecycle
    public func start() async throws
    public func stop() async

    // Protocol handlers
    public func handle(_ protocolID: String, handler: @escaping StreamHandler)

    // Connections
    public func connect(to address: Multiaddr) async throws -> PeerID
    public func disconnect(from peer: PeerID) async
    public func connection(to peer: PeerID) -> MuxedConnection?

    // Streams
    public func newStream(to peer: PeerID, protocol: String) async throws -> MuxedStream
}
```

### NodeEvent
```swift
public enum NodeEvent: Sendable {
    case peerConnected(PeerID)
    case peerDisconnected(PeerID)
    case listenError(Multiaddr, any Error)
    case connectionError(PeerID?, any Error)
    case connection(ConnectionEvent)  // 詳細な接続イベント
}
```

### ConnectionEvent
接続の詳細なライフサイクルイベント（`Connection/ConnectionEvent.swift` 参照）:
- `connected`, `disconnected`, `reconnecting`, `reconnected`
- `gated`, `trimmed`, `healthCheckFailed`, `reconnectionFailed`

### ConnectionUpgrader
```swift
public protocol ConnectionUpgrader: Sendable {
    func upgrade(
        _ raw: any RawConnection,
        localKeyPair: KeyPair,
        role: SecurityRole,
        expectedPeer: PeerID?
    ) async throws -> UpgradeResult
}

public struct UpgradeResult: Sendable {
    public let connection: MuxedConnection
    public let securityProtocol: String
    public let muxerProtocol: String
}
```

## エラー型

### NodeError
```swift
public enum NodeError: Error, Sendable {
    case noSuitableTransport(Multiaddr)      // アドレスをサポートするTransportがない
    case notConnected(PeerID)                // 指定ピアに接続なし
    case protocolNegotiationFailed(String)   // プロトコル選択失敗
    case streamClosed                        // 予期しないストリーム終了
    case connectionLimitReached              // 接続制限到達
    case connectionGated(ConnectionGateStage)// ゲーターが接続を拒否
    case nodeNotRunning                      // ノード未起動
}
```

### UpgradeError
```swift
public enum UpgradeError: Error, Sendable {
    case noSecurityUpgraders                 // セキュリティプロトコル未設定
    case noMuxers                            // Muxer未設定
    case securityNegotiationFailed(String)   // セキュリティネゴシエーション失敗
    case muxerNegotiationFailed(String)      // Muxerネゴシエーション失敗
    case connectionClosed                    // アップグレード中に接続切断
}
```

---

## 接続フロー

```
1. connect(to: Multiaddr)
   ↓
2. Transport.dial() → RawConnection
   ↓
3. ConnectionUpgrader.upgrade()
   ├── multistream-select (Security)
   ├── SecurityUpgrader.secure() → SecuredConnection
   ├── multistream-select (Mux)
   └── Muxer.multiplex() → MuxedConnection
   ↓
4. Store in connection pool
   ↓
5. Emit NodeEvent.peerConnected
   ↓
6. Start inbound stream handler
```

---

## ユーザー使用例

```swift
import P2P
import P2PTransportTCP
import P2PSecurityNoise
import P2PMuxYamux

// 設定は初期化時に完結
let node = Node(configuration: NodeConfiguration(
    keyPair: .generateEd25519(),
    listenAddresses: [try! Multiaddr("/ip4/0.0.0.0/tcp/4001")],
    transports: [TCPTransport()],
    security: [NoiseUpgrader()],      // 優先順で複数指定可
    muxers: [YamuxMuxer()],
    pool: PoolConfiguration(
        limits: ConnectionLimits(highWatermark: 50)
    ),
    healthCheck: .default
))

// プロトコルハンドラ登録
await node.handle("/chat/1.0.0") { stream in
    // Handle chat stream
}

// イベント監視
Task {
    for await event in await node.events {
        switch event {
        case .peerConnected(let peer):
            print("Connected: \(peer)")
        case .peerDisconnected(let peer):
            print("Disconnected: \(peer)")
        default:
            break
        }
    }
}

// 開始
try await node.start()

// 接続
let remotePeer = try await node.connect(to: serverAddress)

// ストリーム作成（プロトコルネゴシエーション付き）
let stream = try await node.newStream(to: remotePeer, protocol: "/chat/1.0.0")
try await stream.write(Data("Hello".utf8))
```

---

## 設計原則

1. **設定は初期化時に完結**
   - `use()` メソッドは廃止
   - `NodeConfiguration` で全コンポーネントを指定

2. **Connection-levelネゴシエーション**
   - Security/Muxer選択にmultistream-selectを使用
   - 優先順位はconfigurationの配列順

3. **イベント駆動**
   - `events` AsyncStreamで状態変化を通知
   - 接続/切断イベントをリアルタイムで取得可能

4. **アップグレードパイプラインの抽象化**
   - `ConnectionUpgrader` プロトコルで抽象化
   - `NegotiatingUpgrader` がデフォルト実装

---

## デフォルト実装

明示的に設定されない場合:
- **PeerStore**: `MemoryPeerStore`（P2PDiscoveryから）
- **AddressBook**: `DefaultAddressBook`（P2PDiscoveryから）
- **ConnectionGater**: `AllowAllGater`（暗黙的 - フィルタリングなし）

## Bootstrap統合

設定時、Nodeは`DefaultBootstrap`を初期化:
1. 起動時に設定されたシードピアへ接続
2. オプションで自動定期ブートストラップを維持
3. `PeerStore`を使用してピアアドレスを永続化

```swift
public struct BootstrapConfiguration: Sendable {
    public var seedPeers: [Multiaddr]      // 初期接続先
    public var minPeers: Int               // 最小ピア数
    public var autoRefresh: Bool           // 自動リフレッシュ
    public var refreshInterval: Duration   // リフレッシュ間隔
    public var connectTimeout: Duration    // 接続タイムアウト
}
```

## 実装ノート

### 並行性モデル: Actor + Mutex

Node層は推奨される並行性パターンを実証:
- **Node**: Actor（低頻度操作、O(1)オーバーヘッドは許容）
- **ConnectionPool**: 内部classとMutex（高頻度操作）

これにより、公開APIはシンプルに保ちつつ（actor保証）、内部状態アクセスのスループットを維持。

### NodePingProvider（内部）
`HealthMonitor`がNodeを通じてpingできるようにする内部アダプター。
- Nodeへの弱参照を保持（循環参照防止）
- `PingService`（P2PPing）を使用

### 自動接続ループ (Discovery統合)

discoveryタスクは継続的なポーリングループを維持（5秒間隔）:
1. discoveryサービスから既知のピアを取得
2. 未接続でクールダウン中でないピアに対して:
   - autoConnectMinScoreの閾値をチェック
   - 接続を試行
   - ピアにreconnectCooldownを設定
3. maxAutoConnectPeersの制限を確認

クールダウンは`await`の前にアトミックに設定（競合防止）。

### アイドルチェックタスク

`idleTimeout / 2`間隔で実行し、以下を実行:
1. **アイドル接続のクローズ**: `idleTimeout`間活動のない接続を切断
2. **制限超過時のトリム**: `connectionCount > highWatermark`なら`lowWatermark`までトリム
3. **古いエントリのクリーンアップ**: 失敗/切断エントリを削除

### 再接続フロー

接続が閉じられた場合（リモートまたはローカル）:
1. **再接続ポリシーをチェック**: localClose, gated, limitExceededでは再接続しない
2. **再接続をスケジュール**: 状態を`.reconnecting(attempt, nextAttempt)`に更新
3. **再接続を実行**: 初期接続と同じ方法でダイアル＆アップグレード
4. **失敗時**: ポリシーを再チェック、許可されれば次の再試行をスケジュール

## テスト

```
Tests/Integration/P2PTests/
└── P2PTests.swift  # 13テスト
    ├── NodeConfiguration tests
    ├── Node initialization tests
    ├── ConnectionUpgrader tests
    ├── NodeEvent tests
    └── Multiaddr extension tests
```

## 未実装機能

| 機能 | 説明 |
|------|------|
| ~~Early Muxer Negotiation~~ | ✅ 実装済み — `EarlyMuxerNegotiating` プロトコルで TLS ALPN にmuxerヒントを含め、muxerネゴシエーション RTT を省略 |
| ~~Resource Manager (multi-scope)~~ | ✅ 実装済み — `ResourceManager` プロトコル + `DefaultResourceManager` (system/peer/protocol 3スコープ)。`ResourceTrackedStream` でストリーム解放を自動追跡。51テスト |
| ~~V1 Lazy Negotiation~~ | ✅ 実装済み — `ConnectionUpgrader` の initiator 側で `negotiateLazy()` を使用。1 RTT 削減 |

## 品質向上TODO

### 高優先度
- [x] **Early Muxer Negotiation** - TLS ALPN でmuxerヒントを渡し、muxerネゴシエーションを省略
- [ ] **UpgradeError/NodeErrorの包括的テスト** - エラーパステスト追加
- [ ] **再接続ロジックのユニットテスト** - ポリシーとバックオフのテスト

### 中優先度
- [x] **Resource Manager** - マルチスコープのリソース制限 ✅ 2026-01-30 (GAP-9)
- [ ] **接続トリムアルゴリズムの検証テスト** - タグ、保護、優先度のテスト
- [ ] **イベントストリームの挙動ドキュメント化** - 最初のアクセスでストリーム作成

### 低優先度
- [ ] **グレース期間の強制確認** - 現在未検証
- [ ] **トリムアルゴリズム検査API** - デバッグ/監視用

## Fixes Applied

### ResourceTrackedStream 3スコープ解放修正 (2026-01-31)

**問題**: `ResourceTrackedStream` が 2スコープ（system + peer）の `releaseStream(peer:direction:)` のみ呼んでいた。Protocol スコープのリソース解放が漏れていた

**解決策**: `negotiatedProtocolID` パラメータを追加。Protocol ID が設定されている場合は 3スコープ（system + peer + protocol）の `releaseStream(protocolID:peer:direction:)` を呼び出す

**修正ファイル**: `Resource/ResourceTrackedStream.swift`

### V1 Lazy Negotiation 有効化 (2026-01-30)

**変更**: `ConnectionUpgrader` の initiator 側で `MultistreamSelect.negotiate()` を `MultistreamSelect.negotiateLazy()` に変更。Security negotiation と Muxer negotiation の2箇所。Responder 側は変更不要（V1 Lazy は V1 と後方互換）

**修正ファイル**: `ConnectionUpgrader.swift`

## Codex Review (2026-01-18) - UPDATED 2026-01-22

### Warning (RESOLVED)
| Issue | Location | Description | Status |
|-------|----------|-------------|--------|
| Dictionary mutation | `ConnectionPool.swift:512-555` | `cleanupStaleEntries` uses two-pass pattern: collect IDs first, then remove | ✅ Fixed |
| Unbounded buffer | `P2P.swift:1210-1294` | `BufferedStreamReader` has `maxMessageSize=64KB` + proper VarintError handling | ✅ Fixed |
| No max frame size | `ConnectionUpgrader.swift:283-357` | `readBuffered` checks `buffer.count > maxMessageSize` before reading | ✅ Fixed |

**Resolution Details:**
1. **ConnectionPool.cleanupStaleEntries()**: Two-pass pattern - first collects IDs to remove, then removes them (avoids iteration mutation)
2. **BufferedStreamReader**: `VarintError.overflow` and `.valueExceedsIntMax` return `.invalidData(error)` which is thrown; buffer size checked before each read
3. **ConnectionUpgrader**: Both `readBuffered` and `readBufferedSecured` check `buffer.count > Self.maxMessageSize` before appending; `extractMessage` validates varint-decoded length

### Info
| Issue | Location | Description | Priority |
|-------|----------|-------------|----------|
| Unstructured per-stream tasks | `P2P.swift:962` | Each inbound stream spawns `Task` with no backpressure; task proliferation possible | Low |
| Timeout relies on cooperative cancel | `Connection/HealthMonitor.swift:257` | If `pingProvider.ping` ignores cancellation, I/O continues; concurrent pings accumulate | Low |

These Info-level items are improvement opportunities, not bugs. They can be addressed in future sprints.
