# Discovery Layer

## 概要
ピア発見層のプロトコル定義と実装を含むグループ。

## ディレクトリ構造
```
Discovery/
├── P2PDiscovery/     # Protocol定義のみ
├── SWIM/             # P2PDiscoverySWIM
├── CYCLON/           # P2PDiscoveryCYCLON（将来実装）
└── Plumtree/         # P2PDiscoveryPlumtree（将来実装）
```

## 設計原則
- **観察ベースの発見**: 直接接続ではなく観察を通じたピア情報収集
- **スコアリング**: 複数の観察から接続候補をランク付け
- **ゴシップベース**: 分散的な情報伝播

## サブモジュール

| ターゲット | 責務 | 依存関係 |
|-----------|------|----------|
| `P2PDiscovery` | DiscoveryServiceプロトコル定義 | P2PCore |
| `P2PDiscoverySWIM` | SWIMメンバーシップ実装 | P2PDiscovery |
| `P2PDiscoveryCYCLON` | CYCLONピアサンプリング | P2PDiscovery |
| `P2PDiscoveryPlumtree` | Plumtreeゴシップ | P2PDiscovery |

## 主要なプロトコル

```swift
/// 観察情報
public struct Observation: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case announcement   // 自己アナウンス
        case reachable      // 到達可能の観察
        case unreachable    // 到達不能の観察
    }
    
    public let subject: PeerID
    public let observer: PeerID
    public let kind: Kind
    public let hints: [Multiaddr]
    public let timestamp: UInt64
    public let sequenceNumber: UInt64
}

/// スコア付き候補
public struct ScoredCandidate: Sendable {
    public let peerID: PeerID
    public let addresses: [Multiaddr]
    public let score: Double
}

/// 発見サービス
public protocol DiscoveryService: Sendable {
    func announce(addresses: [Multiaddr]) async throws
    func find(peer: PeerID) async throws -> [ScoredCandidate]
    func subscribe(to peer: PeerID) -> AsyncStream<Observation>
    func knownPeers() async -> [PeerID]
}
```

## スコアリングロジック

### 概念的な重み（実際の実装は異なる）
```swift
// 観察の信頼度
let announcementWeight = 1.0    // 自己申告
let reachableWeight = 2.0       // 第三者による到達確認
let unreachableWeight = -1.5    // 到達不能
```

### 実際の実装

#### AddressBookスコアリング
```swift
// 設定可能な重み付け
transportPriorityWeight: 0.4    // トランスポート優先度 (TCP > QUIC > UDP)
connectionSuccessWeight: 0.4    // 接続成功履歴
lastSeenWeight: 0.2             // 最後に見た時刻

// 時間減衰: linear decay
let decay = 1.0 - (elapsed / ttl)  // 注: 指数減衰ではない
```

#### SWIMスコアリング（ステータスベース）
```swift
alive: 1.0      // 生存確認済み
suspect: 0.5    // 疑わしい
dead: 0.0       // 死亡
```

#### mDNSスコアリング（静的）
```swift
base: 0.5                           // ベーススコア
+0.2 if fully resolved              // 完全解決済み
+0.2 if has addresses               // アドレスあり
+0.1 if both IPv4 and IPv6          // デュアルスタック
// 最大: 1.0（キャップ）
```

## プロトコル概要

### SWIM (Scalable Weakly-consistent Infection-style Membership)
- メンバーシップ管理
- 障害検出
- ゴシップベースの伝播

### CYCLON
- ランダムピアサンプリング
- オーバーレイネットワーク維持

### Plumtree
- 効率的なブロードキャスト
- Eager + Lazy push

## 実装ステータス

| モジュール | ステータス | 説明 |
|-----------|----------|------|
| P2PDiscovery | ✅ 実装済み | プロトコル定義 |
| CompositeDiscovery | ✅ 実装済み | 複数サービス合成 |
| P2PDiscoverySWIM | ✅ 実装済み | swift-SWIM統合 |
| P2PDiscoveryMDNS | ✅ 実装済み | ローカルネットワーク発見 |
| PeerStore (in-memory) | ✅ 実装済み | LRUキャッシュ、最大1000ピア、TTLベースGC |
| AddressBook | ✅ 実装済み | スコアリング、優先順位付け |
| Bootstrap | ✅ 実装済み | シードピア接続 |
| PeerStore TTL-based GC | ✅ 実装済み | `expiresAt`フィールド、`cleanup()`、`startGC()`/`stopGC()` |
| ProtoBook | ✅ 実装済み | Go互換API、`MemoryProtoBook`（`Mutex`ベース） |
| KeyBook | ✅ 実装済み | PeerID検証付き、`MemoryKeyBook`（`Mutex`ベース） |
| P2PDiscoveryCYCLON | ❌ 未実装 | ランダムピアサンプリング |
| P2PDiscoveryPlumtree | ❌ 未実装 | ゴシップベースブロードキャスト |

## 追加コンポーネント

### AddressBook（インテリジェントアドレス優先順位付け）
```swift
public protocol AddressBook: Sendable {
    func addAddress(_ address: Multiaddr, for peer: PeerID) async
    func recordSuccess(_ address: Multiaddr, for peer: PeerID) async
    func recordFailure(_ address: Multiaddr, for peer: PeerID) async
    func sortedAddresses(for peer: PeerID) async -> [Multiaddr]
}
```
デフォルト実装: `DefaultAddressBook`
- トランスポートタイプ優先度
- 接続成功履歴
- 時間ベース減衰（linear）

### PeerStore（ピア情報ストレージ）
```swift
public protocol PeerStore: Sendable {
    func addPeer(_ peerID: PeerID) async
    func getPeer(_ peerID: PeerID) async -> PeerInfo?
    func addAddresses(_ addresses: [Multiaddr], for peer: PeerID) async
    // ...
}
```
デフォルト実装: `MemoryPeerStore`（LRUキャッシュ、最大1000ピア）

### Bootstrap（シードピア接続）
```swift
public struct BootstrapConfiguration: Sendable {
    public var seedPeers: [Multiaddr]
    public var minPeers: Int
    public var autoRefresh: Bool
    public var refreshInterval: Duration
}
```
デフォルト実装: `DefaultBootstrap`
- 初期シードピア接続
- 自動定期ブートストラップ（オプション）
- 並行接続試行

### CompositeDiscovery
複数の発見サービスを組み合わせる:
```swift
let composite = CompositeDiscovery(services: [
    (swimService, weight: 1.0),
    (mdnsService, weight: 0.8)
])
await composite.start()
// ... 使用 ...
await composite.stop()  // 必須: 内部サービスも停止
```

**重要な制約**:
- CompositeDiscoveryは提供されたサービスの所有権を取得する
- 各サービスインスタンスは1つのCompositeDiscoveryのみが使用すること
- CompositeDiscoveryに追加後は、サービスを直接使用しないこと
- `stop()`は必ず呼び出すこと（内部サービスも停止される）

### SWIMの追加型
- `SWIMMembership` - DiscoveryService実装
- `SWIMBridge` - SWIM型変換ユーティリティ
- `SWIMTransportAdapter` - NIOUDPTransportアダプター

### mDNSの追加型
- `MDNSDiscovery` - DiscoveryService実装
- `MDNSConfiguration` - 設定（サービスタイプ: `_p2p._udp`、クエリ間隔: 120秒等）
- `PeerIDServiceCodec` - PeerID↔mDNSサービス変換

## 既知の制限事項

### SWIMMembership
- `announce()`はSWIMメンバーシップに影響しない（`join()`が必要）
- 時間ベースのスコア減衰なし
- サスペンド/離脱タイムアウト設定なし

### MDNSDiscovery
- ローカルネットワークセグメントに限定
- IPv6リンクローカルアドレスのスコープID未対応
- 観察の経過時間によるスコアリングなし

### CompositeDiscovery
- 重み付け以外の優先順位付けなし
- `find()`は順次実行（並列ではない）
- 失敗サービスのサーキットブレーカーなし

## 相互運用性ノート

- mDNS生成アドレスに未解決IPv6が含まれる場合あり
- SWIMメンバーシップとmDNS発見層間でゴシップ共有なし

## テスト実装状況

| テスト | ステータス | テスト数 | 説明 |
|-------|----------|---------|------|
| DiscoveryTests | ✅ 完了 | 34 | Observation、ScoredCandidate、CompositeDiscovery |
| SWIMBridgeTests | ✅ 完了 | 20 | 型変換、イベントマッピング |
| PeerIDServiceCodecTests | ✅ 完了 | 44 | エンコード/デコード、スコアリング |
| PeerStoreGCTests | ✅ 完了 | 10 | TTL、GC、期限切れフィルタリング |
| ProtoBookTests | ✅ 完了 | 8 | set/add/remove/supports/peers |
| KeyBookTests | ✅ 完了 | 8 | set/get/mismatch/extraction/remove |
| SWIMMembershipTests | ❌ なし | 0 | 統合テストが必要 |
| MDNSDiscoveryTests | ❌ なし | 0 | 統合テストが必要 |
| AddressBookTests | ❌ なし | 0 | 追加推奨 |

**合計**: 124テスト実装済み

## 品質向上TODO

### 高優先度
- [x] **SWIMBridge変換テスト** - 完了: 20テスト
- [x] **PeerIDServiceCodecテスト** - 完了: 44テスト
- [ ] **SWIMMembership統合テスト** - 機能テスト未実装
- [ ] **MDNSDiscovery統合テスト** - 機能テスト未実装
- [ ] **AddressBookテスト** - 追加推奨
- [ ] **PeerStoreテスト** - 追加推奨

### 中優先度
- [ ] **時間ベースのスコア減衰** - 古い観察の信頼度低下
- [ ] **IPv6リンクローカルスコープID対応** - mDNSでの正確なアドレス処理
- [ ] **SWIMTransportAdapterメッセージエラーログ** - 現在はsilent skip
- [ ] **CompositeDiscoveryの並列find()** - 現在は順次実行

### 低優先度
- [ ] **CYCLON実装** - ランダムピアサンプリング
- [ ] **Plumtree実装** - 効率的なブロードキャスト
- [ ] **サーキットブレーカー** - 失敗サービスの一時停止

## 並行処理とイベントパターン

### Actor vs Class+Mutex

| サービス | パターン | 理由 |
|---------|---------|------|
| SWIMMembership | `actor` | 低頻度、ユーザー向けAPI |
| MDNSDiscovery | `actor` | 低頻度、ユーザー向けAPI |
| CYCLONDiscovery | `actor` | 低頻度、ユーザー向けAPI |
| CompositeDiscovery | `final class + Mutex` | イベント転送のみ、内部は軽量処理 |

### イベントパターン

Discovery層のすべてのサービスは **EventBroadcaster（多消費者）** を使用。

- **理由**: 複数の消費者が異なるピアを監視する（`subscribe(to: PeerID)`）
- **実装**: `nonisolated let broadcaster = EventBroadcaster<Observation>()`
- **ライフサイクル**: `deinit` で `broadcaster.shutdown()` 呼び出し

### ライフサイクルメソッド統一

すべてのDiscoveryServiceは `func stop() async` を実装すること。

| サービス | 現状 | 修正状況 |
|---------|------|----------|
| SWIMMembership | `func stop() async` | ✅ そのまま |
| MDNSDiscovery | `func stop() async` | ✅ そのまま |
| CYCLONDiscovery | `func stop() async` | ✅ `async` 追加完了 |
| CompositeDiscovery | `func stop() async` | ✅ `async` 追加、内部サービス停止を実装完了 |

**理由**: 内部で非同期リソース（`await transport.stop()`, `await browser.stop()`）を停止する必要がある。

## Codex Review (2026-01-18, Updated 2026-02-03)

### Warning
| Issue | Location | Status | Resolution |
|-------|----------|--------|------------|
| ~~Advertised address unroutable~~ | ~~SWIM/SWIMMembership.swift:90-118~~ | ✅ FALSE POSITIVE | Already validated by `resolveAdvertisedHost()`; 0.0.0.0 used for binding only |
| AsyncStream permanently closed | MDNSDiscovery/CompositeDiscovery | ✅ BY DESIGN | Services are single-use; documented in lifecycle section |
| ~~knownServices not cleared on stop~~ | ~~MDNSDiscovery.swift:95-103~~ | ✅ FIXED | `knownServices.removeAll()` already present; `sequenceNumber` reset added to all Discovery services |
| ~~Division by zero possible~~ | ~~AddressBook.swift:247-289~~ | ✅ FALSE POSITIVE | All divisions properly guarded; uses weighted sum not division |
| Multiaddr type mismatch | PeerIDServiceCodec.swift:78-97 | ℹ️ ACCEPTABLE | mDNS advertises all possible connection methods per libp2p spec |

### Info
| Issue | Location | Description |
|-------|----------|-------------|
| LRU eviction timing | `P2PDiscovery/PeerStore.swift:351-364` | `recordFailure` doesn't call `touchPeer`; failed peers evicted early |
| Sequential find() | `P2PDiscovery/CompositeDiscovery.swift:110-125` | Services queried sequentially; parallel execution would improve latency |
| Fingerprinting surface | `MDNS/PeerIDServiceCodec.swift:36-48` | mDNS broadcasts PeerID allowing LAN device enumeration |
| Browser errors silently ignored | `MDNS/MDNSDiscovery.swift:177-190` | Errors from ServiceBrowser are logged but not propagated |
