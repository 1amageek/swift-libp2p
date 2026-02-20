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
│   ├── ConnectionPool.swift      # 接続プール（内部、isLimited 対応）
│   ├── ConnectionState.swift     # 接続状態マシン
│   ├── ConnectionLimits.swift    # 接続制限設定
│   ├── ConnectionGater.swift     # 接続フィルタリング
│   ├── HealthMonitor.swift       # ヘルスモニタリング
│   ├── BackoffStrategy.swift    # リトライ遅延計算 (exponential/constant/linear)
│   ├── ReconnectionPolicy.swift # 再接続ポリシー
│   └── ...
├── Dial/                     # ダイヤル戦略
│   ├── DefaultDialRanker.swift       # アドレスランキング（リレーグループ対応）
│   └── SmartDialer.swift             # ランク付き並行ダイヤル
├── Traversal/                # 接続経路オーケストレーション
│   ├── TraversalCoordinator.swift       # Mechanism 実行調停
│   ├── TraversalMechanism.swift         # 経路メカニズム抽象
│   └── Policies/DefaultTraversalPolicy.swift  # デフォルト優先順位ポリシー
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
    public func connectionTrimReport() -> ConnectionTrimReport
    public var supportedProtocols: [String] { get }
    public var events: AsyncStream<NodeEvent> { get }

    // Lifecycle
    public func start() async throws
    public func shutdown() async

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
- `gated`, `trimmed`, `trimmedWithContext`, `trimConstrained`, `healthCheckFailed`, `reconnectionFailed`
- `trimmedWithContext` で構造化 `ConnectionTrimmedContext`（rank/tags/idle/direction）を提供し、`trimmed(reason:)` は後方互換として維持
- `trimConstrained` は `target/selected/trimmable/active` を通知し、トリム不足を監視可能

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

## Traversal アーキテクチャ

### コンポーネント構成

```
Node (actor)
 ├── TraversalCoordinator (Class+Mutex, EventEmitting)
 │    ├── LocalDirectMechanism  — ローカル経路優先
 │    ├── DirectMechanism       — 直接IP経路
 │    ├── HolePunchMechanism    — AutoNAT + DCUtR
 │    ├── RelayMechanism        — Relay フォールバック
 │    ├── TraversalHintProvider — 外部ヒント注入（mesh等）
 │    └── TraversalPolicy       — 候補順序/フォールバック制御
 └── ConnectionPool
      └── isLimited flag     — リレー接続の識別
```

### イベントフロー

```
AddressBook + HintProviders
  → TraversalCoordinator.collectCandidates()
  → TraversalPolicy.order()
  → stage-by-stage attempts (local/ip/holePunch/relay)
  → first success wins (other in-flight attempts are cancelled)
```

### ファイル構成

```
Sources/Integration/P2P/
└── Traversal/
    ├── TraversalConfiguration.swift      # Orchestration 設定
    ├── TraversalCoordinator.swift        # メカニズム調停
    ├── TraversalMechanism.swift          # メカニズム抽象
    ├── TraversalHintProvider.swift       # 外部候補ヒント
    ├── TraversalPolicy.swift             # 優先順位・フォールバック
    ├── Mechanisms/*.swift                # Direct/Local/HolePunch/Relay 実装
    └── Policies/DefaultTraversalPolicy.swift
```

### NodeConfiguration 拡張

```swift
public struct NodeConfiguration: Sendable {
    // ... 既存フィールド ...
    public let traversal: TraversalConfiguration?  // traversal 設定
}
```

### 依存モジュール (Traversal 関連)

- `P2PAutoNAT` — AutoNAT v2 プローブ
- `P2PCircuitRelay` — Circuit Relay v2 クライアント/サーバー
- `P2PDCUtR` — Direct Connection Upgrade through Relay
- `P2PNAT` — NAT デバイス検出、ポートマッピング

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
   - `events` は遅延初期化され、最初にアクセスされるまでイベントは破棄される

4. **アップグレードパイプラインの抽象化**
   - `ConnectionUpgrader` プロトコルで抽象化
   - `NegotiatingUpgrader` がデフォルト実装

### Event Stream挙動

- `Node.events` は最初のアクセス時に `AsyncStream.makeStream()` で生成される（lazy）。
- 2回目以降の `events` アクセスは同一ストリームを返す（`_events` を再利用）。
- `emit(_:)` は `eventContinuation` が存在する場合のみ `yield` するため、購読前イベントは保持されない。
- `shutdown()` 時に `eventContinuation.finish()` を呼び、`eventContinuation = nil` / `_events = nil` へリセットする。
- `shutdown()` 後に再度 `events` を参照すると新しいストリームが再生成される。

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

Nodeは`DiscoveryService`に対して以下を行う:
1. 起動時に capability protocol を検出し、必要ならハンドラ登録・start を実行  
   - `NodeDiscoveryHandlerRegistrable` → `registerHandler(registry:)`
   - `NodeDiscoveryStartableWithOpener` → `start(using: StreamOpener)`
   - `NodeDiscoveryStartable` → `start()`
2. 接続時に capability protocol を検出し、必要なら専用ストリームを接続
   - `NodeDiscoveryPeerStreamService` の `discoveryProtocolID` で `newStream` を開き、`handlePeerConnected` を通知
3. 切断時に `handlePeerDisconnected` を通知

auto-connect自体はリアクティブ:
1. 起動直後に `knownPeers()` を1回評価
2. 以降は `observations` ストリームを購読して接続判断
3. クールダウンは`await`前にアトミック設定（競合防止）

### アイドルチェックタスク

`idleTimeout / 2`間隔で実行し、以下を実行:
1. **アイドル接続のクローズ**: `idleTimeout`間活動のない接続を切断
2. **制限超過時のトリム**: `connectionCount > highWatermark`なら`lowWatermark`までトリム
   - `ConnectionTrimReport` を先に取得し、`selected < target` の場合は制約状態を警告ログ出力
   - 同時に `trimConstrained` イベントを発火し、監視側で集計可能
   - 可能な場合は `trimmedWithContext` を発火し、監視側が文字列パース不要で利用可能
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
├── ResourceManagerTests.swift      # 51テスト (system/peer/protocol スコープ, tracked stream 解放, 制限超過)
├── P2PTests.swift                  # 27テスト (Node, Config, Upgrader, Events, buffered negotiation, trim/report API)
├── ConnectionPoolTests.swift       # 25テスト (add/remove, limits, tags, protection, trim priority/report)
├── NodeE2ETests.swift              # 18テスト (memory transport full-stack, protocols, limits, trim events)
├── DiscoveryIntegrationTests.swift # 2テスト (discovery capability hooks: register/start/peer stream/shutdown)
├── IdentifyIntegrationTests.swift # 4テスト (identify handlers登録, peerConnected/Disconnected通知, shutdown連動)
├── ReconnectionPolicyTests.swift   # 16テスト (config presets, shouldReconnect, delay)
├── HealthMonitorTests.swift        # 11テスト (monitoring lifecycle, timeout, callback)
├── ObservedAddressManagerTests.swift # 11テスト (観測アドレス集約, dedupe, decay)
├── BackoffStrategyTests.swift      # 11テスト (exponential, constant, linear, jitter, presets)
├── BlackHoleDetectorTests.swift    # 10テスト (black-hole検出, 状態遷移, 閾値制御)
└── DialRankerTests.swift           # 6テスト (候補アドレス優先順位付け)
```

**合計: 188テスト** (2026-02-14時点。E2Eテスト含む)

## 未実装機能

| 機能 | 説明 |
|------|------|
| ~~Early Muxer Negotiation~~ | ✅ 実装済み — `EarlyMuxerNegotiating` プロトコルで TLS ALPN にmuxerヒントを含め、muxerネゴシエーション RTT を省略 |
| ~~Resource Manager (multi-scope)~~ | ✅ 実装済み — `ResourceManager` プロトコル + `DefaultResourceManager` (system/peer/protocol 3スコープ)。`ResourceTrackedStream` でストリーム解放を自動追跡。51テスト |
| ~~V1 Lazy Negotiation~~ | ✅ 実装済み — `ConnectionUpgrader` の initiator 側で `negotiateLazy()` を使用。1 RTT 削減 |

## 品質向上TODO

### 高優先度
- [x] **Early Muxer Negotiation** - TLS ALPN でmuxerヒントを渡し、muxerネゴシエーションを省略
- [x] **UpgradeError/NodeErrorの包括的テスト** - `P2PTests` に UpgradeError の到達経路テスト（noMuxers/connectionClosed/messageTooLarge/invalidVarint）と NodeError の関連値保持テストを追加
- [x] **再接続ロジックのユニットテスト** - ReconnectionPolicyTests + BackoffStrategyTests ✅ 2026-02-06

### 中優先度
- [x] **Resource Manager** - マルチスコープのリソース制限 ✅ 2026-01-30 (GAP-9)
- [x] **接続トリムアルゴリズムの検証テスト** - `ConnectionPoolTests` に watermark / protected / tags / oldest activity / grace period の回帰テストを追加
- [x] **イベントストリームの挙動ドキュメント化** - lazy初期化、購読前イベント破棄、shutdown時finish/resetを明記
- [x] **Discovery capability統合** - Node起動/接続/切断ライフサイクルに discovery の optional hook を接続（register/start/peer stream/shutdown）
- [x] **Identify Push Node統合** - `NodeConfiguration.identifyService` でハンドラ登録・peerConnected/Disconnected通知・shutdown連動 ✅

### 低優先度
- [x] **グレース期間の強制確認** - `ConnectionPoolTests.trimIfNeeded does not trim connections within grace period` で検証
- [x] **トリムアルゴリズム検査API** - `ConnectionTrimReport` と `Node.connectionTrimReport()` を追加。`trimIfNeeded()` と共有ロジックで候補・除外理由・選定順を可視化

## Fixes Applied

### ResourceTrackedStream 3スコープ解放修正 (2026-01-31)

**問題**: `ResourceTrackedStream` が 2スコープ（system + peer）の `releaseStream(peer:direction:)` のみ呼んでいた。Protocol スコープのリソース解放が漏れていた

**解決策**: `negotiatedProtocolID` パラメータを追加。Protocol ID が設定されている場合は 3スコープ（system + peer + protocol）の `releaseStream(protocolID:peer:direction:)` を呼び出す

**修正ファイル**: `Resource/ResourceTrackedStream.swift`

### V1 Lazy Negotiation 有効化 (2026-01-30)

**変更**: `ConnectionUpgrader` の initiator 側で `MultistreamSelect.negotiate()` を `MultistreamSelect.negotiateLazy()` に変更。Security negotiation と Muxer negotiation の2箇所。Responder 側は変更不要（V1 Lazy は V1 と後方互換）

**修正ファイル**: `ConnectionUpgrader.swift`

### Stream negotiation remainder継承修正 (2026-02-14)

**問題**: `Node.newStream` / inbound handler が multistream-select 中の先読みバイトを保持せず、アプリケーション層の先頭データを取りこぼす可能性があった

**解決策**: `BufferedStreamReader.drainRemainder()` と `BufferedMuxedStream` を追加し、`NegotiationResult.remainder` と合わせて次段の `MuxedStream` に確実に引き継ぐ

**修正ファイル**: `P2P.swift`

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

<!-- CONTEXT_EVAL_START -->
## 実装評価 (2026-02-16)

- 総合評価: **A** (92/100)
- 対象ターゲット: `P2P`
- 実装読解範囲: 30 Swift files / 6434 LOC
- テスト範囲: 11 files / 188 cases / targets 1
- 公開API: types 46 / funcs 60
- 参照網羅率: type 0.63 / func 0.75
- 未参照公開型: 17 件（例: `AllowAllGater`, `Candidate`, `CompositeGater`, `ConnectionDirection`, `ConnectionID`）
- 実装リスク指標: try?=0, forceUnwrap=0, forceCast=0, @unchecked Sendable=0, EventLoopFuture=0, DispatchQueue=0
- 評価所見: 重大な静的リスクは検出されず

### 重点アクション
- 未参照の公開型に対する直接テスト（生成・失敗系・境界値）を追加する。

※ 参照網羅率は「テストコード内での公開API名参照」を基準にした静的評価であり、動的実行結果そのものではありません。

<!-- CONTEXT_EVAL_END -->
