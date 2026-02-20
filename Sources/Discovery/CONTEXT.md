# Discovery Layer

## 概要
ピア発見層のプロトコル定義と実装を含むグループ。

## ディレクトリ構造
```
Discovery/
├── P2PDiscovery/     # Protocol定義のみ
├── SWIM/             # P2PDiscoverySWIM
├── MDNS/             # P2PDiscoveryMDNS
├── CYCLON/           # P2PDiscoveryCYCLON
├── Plumtree/         # P2PDiscoveryPlumtree
├── Beacon/           # P2PDiscoveryBeacon
└── WiFiBeacon/       # P2PDiscoveryWiFiBeacon
```

## 設計原則
- **観察ベースの発見**: 直接接続ではなく観察を通じたピア情報収集
- **スコアリング**: 複数の観察から接続候補をランク付け
- **ゴシップベース**: 分散的な情報伝播

## サブモジュール

| ターゲット | 責務 | 依存関係 |
|-----------|------|----------|
| `P2PDiscovery` | DiscoveryServiceプロトコル定義 | P2PCore |
| `P2PDiscoveryMDNS` | mDNSベースのローカル発見 | P2PDiscovery, mDNS |
| `P2PDiscoverySWIM` | SWIMメンバーシップ実装 | P2PDiscovery |
| `P2PDiscoveryCYCLON` | CYCLONピアサンプリング | P2PDiscovery |
| `P2PDiscoveryPlumtree` | Plumtreeアナウンス統合 | P2PDiscovery, P2PPlumtree |
| `P2PDiscoveryBeacon` | BLE/Wi-Fi等の近接ビーコン統合 | P2PDiscovery |
| `P2PDiscoveryWiFiBeacon` | Wi-Fi beaconアダプタ | P2PDiscoveryBeacon |

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
    var observations: AsyncStream<Observation> { get }
    func shutdown() async
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

// 時間減衰: half-life decay (中立値0.5へ漸近)
let decayFactor = pow(0.5, elapsed / halfLife)
let decayed = 0.5 + ((score - 0.5) * decayFactor)
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
| P2PDiscoveryCYCLON | ✅ 実装済み | ランダムピアサンプリング、shuffle、観察イベント |
| P2PDiscoveryPlumtree | ✅ 実装済み | Plumtreeトピック上の自己アナウンス配信と観察変換 |
| Discovery Node capability連携 | ✅ 実装済み | `NodeDiscovery*` hook により register/start/peer stream lifecycle をNodeと統合 |
| P2PDiscoveryBeacon | ✅ 実装済み | 近接観察集約、Bayesian presence、信頼度計算 |
| P2PDiscoveryWiFiBeacon | ✅ 実装済み | Wi-Fi beacon受信をDiscovery観察へ変換 |

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
- 時間ベース減衰（half-life）

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
await composite.shutdown()  // 必須: 内部サービスも停止
```

**重要な制約**:
- CompositeDiscoveryは提供されたサービスの所有権を取得する
- 各サービスインスタンスは1つのCompositeDiscoveryのみが使用すること
- CompositeDiscoveryに追加後は、サービスを直接使用しないこと
- `shutdown()`は必ず呼び出すこと（内部サービスも停止される）

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
- A/AAAAフォールバックではスコープ不明なIPv6リンクローカルを除外（誤接続候補を抑制）
- `dnsaddr` 内の `/ip6/...%zone/...` は保持してパース可能（例: `%en0`）
- 観察の経過時間によるスコアリングなし

### CompositeDiscovery
- 重み付け以外の優先順位付けなし
- `find()`はTaskGroupで並列実行（fail-fastではなく部分失敗許容）
- 失敗サービスのサーキットブレーカーなし

### PlumtreeDiscovery
- Announcement payload は自己申告（署名なし）
- `peerID` と gossip source の一致チェックのみ実施
- `baseScore` は固定値（到達性実績に基づく動的重み付けなし）

## 相互運用性ノート

- mDNS生成アドレスに未解決IPv6が含まれる場合あり
- SWIMメンバーシップとmDNS発見層間でゴシップ共有なし

## テスト実装状況

| テストスイート | ステータス | テスト数 | 説明 |
|--------------|-----------|---------|------|
| `P2PDiscoveryTests` | ✅ 完了 | 279 | Discoveryコア, mDNS/SWIM統合, AddressBook, PeerStore, CompositeDiscovery |
| `BeaconTests` | ✅ 完了 | 205 | 集約パイプライン, 信頼度計算, Presence推定, 永続化, イベント連携 |
| `CYCLONTests` | ✅ 完了 | 27 | PartialView, shuffle, DiscoveryService統合 |
| `PlumtreeDiscoveryTests` | ✅ 完了 | 6 | announce/find/subscribe/TTL/不正入力の検証 |
| `WiFiBeaconTests` | ✅ 完了 | 20 | Wi-Fi beaconアダプタ, ペイロード互換性, フィルタリング |

**合計**: 537テスト（2026-02-14 時点）

## 品質向上TODO

### 高優先度
- [x] **SWIMBridge変換テスト** - 完了: 20テスト
- [x] **PeerIDServiceCodecテスト** - 完了: 44テスト
- [x] **SWIMMembership統合テスト** - 実装済み
- [x] **MDNSDiscovery統合テスト** - 実装済み
- [x] **AddressBookテスト** - 実装済み
- [x] **PeerStoreテスト** - 実装済み

### 中優先度
- [x] **時間ベースのスコア減衰** - `AddressBookConfiguration.observationHalfLife` を追加し、古い観察スコアを半減期ベースで中立値へ減衰
- [x] **ip6zoneのバイナリ相互運用対応** - `MultiaddrProtocol.ip6zone` (code: 42) を実装し `%zone` を `/ip6zone/<zone>/ip6/<addr>` として保持
- [x] **SWIMTransportAdapterメッセージエラーログ** - malformed datagramを silent skip せず debug ログ出力
- [x] **CompositeDiscoveryの並列find()** - 並列実行 + 回帰テスト追加済み

### 低優先度
- [x] **CYCLON実装** - ランダムピアサンプリング（`P2PDiscoveryCYCLON` と `CYCLONTests`）
- [x] **DiscoveryService向けPlumtree統合** - `P2PDiscoveryPlumtree` を追加し、announce/find/subscribe を実装
- [ ] **サーキットブレーカー** - 失敗サービスの一時停止

## 並行処理とイベントパターン

### Actor vs Class+Mutex

| サービス | パターン | 理由 |
|---------|---------|------|
| SWIMMembership | `actor` | 低頻度、ユーザー向けAPI |
| MDNSDiscovery | `actor` | 低頻度、ユーザー向けAPI |
| CYCLONDiscovery | `actor` | 低頻度、ユーザー向けAPI |
| PlumtreeDiscovery | `actor` | 低頻度、ユーザー向けAPI |
| CompositeDiscovery | `final class + Mutex` | イベント転送のみ、内部は軽量処理 |

### イベントパターン

Discovery層のすべてのサービスは **EventBroadcaster（多消費者）** を使用。

- **理由**: 複数の消費者が異なるピアを監視する（`subscribe(to: PeerID)`）
- **実装**: `nonisolated let broadcaster = EventBroadcaster<Observation>()`
- **ライフサイクル**: `deinit` で `broadcaster.shutdown()` 呼び出し

### ライフサイクルメソッド統一

すべてのDiscoveryServiceは `func shutdown() async` を実装すること。

| サービス | 現状 | 修正状況 |
|---------|------|----------|
| SWIMMembership | `func shutdown() async` | ✅ 実装済み |
| MDNSDiscovery | `func shutdown() async` | ✅ 実装済み |
| CYCLONDiscovery | `func shutdown() async` | ✅ 実装済み |
| CompositeDiscovery | `func shutdown() async` | ✅ 実装済み（内部サービスも停止） |

**理由**: 内部で非同期リソース（`await transport.shutdown()`, `await browser.shutdown()`）を停止する必要がある。

## Codex Review (2026-01-18, Updated 2026-02-14)

### Warning
| Issue | Location | Status | Resolution |
|-------|----------|--------|------------|
| ~~Advertised address unroutable~~ | ~~SWIM/SWIMMembership.swift:90-118~~ | ✅ FALSE POSITIVE | Already validated by `resolveAdvertisedHost()`; 0.0.0.0 used for binding only |
| AsyncStream permanently closed | MDNSDiscovery/CompositeDiscovery | ✅ BY DESIGN | Services are single-use; documented in lifecycle section |
| ~~knownServices not cleared on stop~~ | ~~MDNSDiscovery.swift:95-103~~ | ✅ FIXED | `knownServicesByPeerID` / name-index maps and `sequenceNumber` are reset on shutdown |
| ~~Division by zero possible~~ | ~~AddressBook.swift:247-289~~ | ✅ FALSE POSITIVE | All divisions properly guarded; uses weighted sum not division |
| ~~Multiaddr type mismatch~~ | ~~PeerIDServiceCodec.swift:78-97~~ | ✅ FIXED | Now uses `dnsaddr=` TXT attributes per libp2p mDNS spec (2026-02-03) |

### Info
| Issue | Location | Status | Description |
|-------|----------|--------|-------------|
| LRU eviction timing | `P2PDiscovery/PeerStore.swift` | ✅ Fixed | `recordFailure()` でも `touchPeer()` を呼び、失敗記録後に不当にLRU削除される問題を解消 |
| Sequential find() | `P2PDiscovery/CompositeDiscovery.swift` | ✅ Fixed | `find()` は `TaskGroup` で並列照会。回帰テストで並列性を検証 |
| Peer-name privacy divergence | `MDNS/MDNSConfiguration.swift` / `MDNS/MDNSDiscovery.swift` | ✅ Fixed | Default is random peer-name (`peerNameStrategy = .random`); legacy `.peerID` is opt-in compatibility mode |
| Browser error propagation | `MDNS/MDNSDiscovery.swift:193-199` | ✅ Fixed | Browser errors are stored and surfaced via `find()` as `MDNSDiscoveryError.browserError` when no candidate is available |
| Link-local IPv6 fallback ambiguity | `MDNS/PeerIDServiceCodec.swift` | ✅ Mitigated | A/AAAA fallback now skips scope-less link-local IPv6 (`fe80::/10`) to avoid unusable candidates |
| Time-based observation decay | `P2PDiscovery/AddressBook.swift` | ✅ Fixed | Added half-life-based confidence decay (`observationHalfLife`) to reduce stale score bias |
| SWIM malformed message visibility | `SWIM/SWIMTransportAdapter.swift` | ✅ Fixed | Decode failures and missing sender address are now logged at debug level instead of silent skip |

## libp2p mDNS Specification Compliance (2026-02-14)

### TXTRecord Redesign (swift-mdns)

swift-mdnsのTXTRecordを再設計し、libp2p mDNS仕様の複数`dnsaddr`属性に対応。

#### 新しい設計

- **Storage**: DNS wire format (`[String]`) + O(1)インデックス (`[String: [Int]]`)
- **DNS-SD API**: `subscript` - 最初の値のみ返す（RFC 6763準拠）
- **libp2p API**: `values(forKey:)`, `appendValue(_:forKey:)` - 複数値対応

#### 主要なAPI

```swift
// DNS-SD標準（単一値）
txtRecord["dnsaddr"]  // 最初の値のみ

// libp2p拡張（複数値）
txtRecord.values(forKey: "dnsaddr")  // 全ての値
txtRecord.appendValue(addr, forKey: "dnsaddr")  // 追加
txtRecord.setValues(addrs, forKey: "dnsaddr")  // 置換
txtRecord.removeValues(forKey: "dnsaddr")  // 削除
```

### PeerIDServiceCodec仕様準拠 (swift-libp2p)

#### encode() 変更

- 各multiaddrを`dnsaddr=`属性としてTXTレコードに保存
- p2pコンポーネントが欠けている場合は自動追加
- 無効なmultiaddrは静かにスキップ

```swift
// 出力例
dnsaddr=/ip4/192.168.1.1/tcp/4001/p2p/QmPeerId
dnsaddr=/ip6/fe80::1/tcp/4001/p2p/QmPeerId
```

#### decode() 変更

- **優先**: TXTレコードから`dnsaddr`属性を読み取り
- **フォールバック**: `dnsaddr`がない場合はA/AAAA+ポートから再構築（後方互換性）
- p2pコンポーネント検証（不一致はスキップ）
- 無効なmultiaddrは静かにスキップ

#### toObservation() 変更

- decode()と一貫性を保つ
- dnsaddr属性優先、A/AAAAフォールバック

### peer-name戦略（仕様準拠 + 互換モード）

- 既定値は `MDNSPeerNameStrategy.random` で、service instance name はランダム文字列を使用。
- `decode()` / `toObservation()` は service name へ依存せず、`dnsaddr`（優先）→ `pk` → legacy service name の順でPeerIDを推定。
- 互換目的で `MDNSPeerNameStrategy.peerID` を選択可能（明示 opt-in）。

### Multiaddr拡張

`hasPeerID`プロパティを追加:

```swift
let addr = try Multiaddr("/ip4/127.0.0.1/tcp/4001")
addr.hasPeerID  // false

let addrWithP2P = try Multiaddr("/ip4/127.0.0.1/tcp/4001/p2p/QmId")
addrWithP2P.hasPeerID  // true
```

### DCUtR堅牢性改善

無効なmultiaddrをスキップするようにエラーハンドリングを改善:

```swift
// DCUtRProtobuf.swift:80-95
do {
    let addr = try Multiaddr(bytes: Data(data[offset..<fieldEnd]))
    addresses.append(addr)
} catch {
    // Skip invalid multiaddr and continue
}
```

### テスト追加

PeerIDServiceCodecTests.swiftに追加した主なテスト:

1. `encodeDnsaddrAttributes` - dnsaddr属性のエンコード
2. `encodePreservesP2PComponent` - p2pコンポーネントの保持
3. `decodeDnsaddrAttributes` - dnsaddr属性のデコード
4. `decodeSkipsInvalidDnsaddr` - 無効なdnsaddrのスキップ
5. `decodeAddsP2PComponent` - p2pコンポーネントの自動追加
6. `decodeSkipsMismatchedPeerID` - peer ID不一致のスキップ
7. `decodeFallbackToARecords` - A/AAAAフォールバック
8. `decodePrefersDnsaddr` - dnsaddr優先
9. `toObservationDnsaddr` - observationでのdnsaddr使用
10. `toObservationFallback` - observationでのフォールバック
11. `decodeWithOpaqueServiceName` - opaque peer-nameでもdnsaddrで復元
12. `inferPeerIDPrefersDnsaddr` - peerID推定優先順序
13. `inferPeerIDFallbackToServiceName` - legacy互換
14. `encodeCustomServiceName` - service name override

### 影響範囲

- **swift-mdns**: TXTRecord構造体のみ（後方互換性あり）
- **swift-libp2p**: PeerIDServiceCodec, DCUtRProtobuf, Multiaddr
- **破壊的変更**: なし（既存APIはすべて維持）
- **仕様準拠**: libp2p mDNS specificationに既定設定で準拠（legacy peer-name互換モードは任意）

<!-- CONTEXT_EVAL_START -->
## 実装評価 (2026-02-16)

- 総合評価: **A** (91/100)
- 対象ターゲット: `P2PDiscovery`, `P2PDiscoveryBeacon`, `P2PDiscoveryCYCLON`, `P2PDiscoveryMDNS`, `P2PDiscoveryPlumtree`, `P2PDiscoverySWIM`, `P2PDiscoveryWiFiBeacon`
- 実装読解範囲: 68 Swift files / 8960 LOC
- テスト範囲: 51 files / 537 cases / targets 5
- 公開API: types 103 / funcs 101
- 参照網羅率: type 0.8 / func 0.86
- 未参照公開型: 21 件（例: `BootstrapConfiguration`, `BootstrapConnectionProvider`, `BootstrapError`, `BootstrapEvent`, `BootstrapResult`）
- 実装リスク指標: try?=0, forceUnwrap=1, forceCast=0, @unchecked Sendable=0, EventLoopFuture=0, DispatchQueue=0
- 評価所見: 強制アンラップを含む実装がある

### 重点アクション
- 未参照の公開型に対する直接テスト（生成・失敗系・境界値）を追加する。
- 強制アンラップ箇所に前提条件テストを追加し、回帰時に即検出できるようにする。

※ 参照網羅率は「テストコード内での公開API名参照」を基準にした静的評価であり、動的実行結果そのものではありません。

<!-- CONTEXT_EVAL_END -->
