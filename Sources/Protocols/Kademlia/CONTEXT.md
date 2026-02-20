# P2PKademlia

Kademlia DHT implementation for peer routing and content discovery.

## Overview

Kademlia is a distributed hash table (DHT) that provides:
- **Peer Routing**: Finding peers closest to a given key
- **Value Storage**: Storing and retrieving arbitrary records
- **Provider Discovery**: Advertising and finding content providers

Based on the original Kademlia paper with influences from S/Kademlia, Coral, and BitTorrent DHT.

## Protocol ID

- `/ipfs/kad/1.0.0`

## Dependencies

- `P2PCore` - PeerID, Multiaddr, Varint
- `P2PMux` - MuxedStream
- `P2PProtocols` - ProtocolService, StreamOpener, HandlerRegistry

## Files

| File | Responsibility |
|------|---------------|
| `KademliaProtocol.swift` | Protocol constants (K=20, ALPHA=3) |
| `KademliaError.swift` | Error types |
| `KademliaMessages.swift` | Message types (FindNode, GetValue, etc.) |
| `KademliaProtobuf.swift` | Protobuf encoding/decoding |
| `KademliaKey.swift` | 256-bit key with XOR distance |
| `KBucket.swift` | Single k-bucket (max K entries) |
| `RoutingTable.swift` | 256 k-buckets indexed by distance |
| `RecordStore.swift` | Record store facade (delegates to RecordStorage backend) |
| `ProviderStore.swift` | Provider store facade (delegates to ProviderStorage backend) |
| `KademliaQuery.swift` | Query types and state machine |
| `KademliaService.swift` | Main service (NetworkBehaviour equivalent) |
| `KademliaEvent.swift` | Event types |
| `Storage/RecordStorage.swift` | Protocol for record storage backends |
| `Storage/ProviderStorage.swift` | Protocol for provider storage backends |
| `Storage/InMemoryRecordStorage.swift` | In-memory record storage (default) |
| `Storage/InMemoryProviderStorage.swift` | In-memory provider storage (default) |
| `Storage/FileRecordStorage.swift` | File-based persistent record storage |
| `Storage/FileProviderStorage.swift` | File-based persistent provider storage |
| `PeerLatencyTracker.swift` | Per-peer latency tracking and dynamic timeout |

## Key Concepts

### XOR Distance

Distance between two keys is calculated as:
```
distance(a, b) = XOR(SHA256(a), SHA256(b))
```

The number of leading zeros in the XOR result determines the k-bucket index.

### K-Buckets

- 256 k-buckets (one per bit of SHA-256 output)
- Each bucket holds up to K=20 peers
- Bucket `i` contains peers where `distance` has `i` leading zeros
- Closer peers (smaller distance) are in lower-indexed buckets

### Routing Table

```
Bucket 0: peers with distance prefix 1xxxxxxx... (farthest)
Bucket 1: peers with distance prefix 01xxxxxx...
...
Bucket 255: peers with distance prefix 00...001 (closest)
```

### Query Parameters

| Parameter | Value | Description |
|-----------|-------|-------------|
| K | 20 | Replication factor, bucket size |
| ALPHA | 3 | Parallelism factor for queries |
| BETA | 3 | Number of peers to query simultaneously |

## Message Types

### FIND_NODE (4)
Request closest peers to a key.

```
Request:  { type: FIND_NODE, key: PeerID bytes }
Response: { closerPeers: [Peer] }
```

### GET_VALUE (1)
Retrieve a record by key.

```
Request:  { type: GET_VALUE, key: bytes }
Response: { record: Record?, closerPeers: [Peer] }
```

### PUT_VALUE (0)
Store a record at closest peers.

```
Request:  { type: PUT_VALUE, key: bytes, record: Record }
Response: { key: bytes, record: Record }
```

### ADD_PROVIDER (2)
Advertise as content provider.

```
Request:  { type: ADD_PROVIDER, key: CID, providerPeers: [Peer] }
Response: (none, fire-and-forget)
```

### GET_PROVIDERS (3)
Find content providers.

```
Request:  { type: GET_PROVIDERS, key: CID }
Response: { providerPeers: [Peer], closerPeers: [Peer] }
```

## Wire Protocol (Protobuf)

```protobuf
message Message {
  enum MessageType {
    PUT_VALUE = 0;
    GET_VALUE = 1;
    ADD_PROVIDER = 2;
    GET_PROVIDERS = 3;
    FIND_NODE = 4;
    PING = 5;  // deprecated
  }

  message Peer {
    bytes id = 1;
    repeated bytes addrs = 2;
    enum ConnectionType {
      NOT_CONNECTED = 0;
      CONNECTED = 1;
      CAN_CONNECT = 2;
      CANNOT_CONNECT = 3;
    }
    ConnectionType connection = 3;
  }

  message Record {
    bytes key = 1;
    bytes value = 2;
    string timeReceived = 5;
  }

  MessageType type = 1;
  bytes key = 10;
  Record record = 3;
  repeated Peer closerPeers = 8;
  repeated Peer providerPeers = 9;
}
```

## Query Algorithm

### Iterative Lookup (FIND_NODE / GET_VALUE / GET_PROVIDERS)

1. Initialize candidate list with ALPHA closest known peers
2. Query ALPHA peers in parallel
3. For each response:
   - Add `closerPeers` to candidate list
   - Mark queried peer as "seen"
4. Select next ALPHA unqueried peers from candidates
5. Repeat until:
   - Found K closest peers (all queried)
   - Or found the target value
   - Or no new closer peers

### PUT_VALUE / ADD_PROVIDER

1. Run FIND_NODE to find K closest peers to key
2. Send PUT_VALUE/ADD_PROVIDER to each of K peers
3. Track success/failure for quorum

## Modes

### Server Mode
- Responds to DHT queries
- Stores records and provider information
- Advertises `/ipfs/kad/1.0.0` via Identify

### Client Mode
- Issues queries but doesn't respond
- Useful for resource-constrained nodes
- Does not advertise protocol support

### Client/Server モード
設定（`KademliaConfiguration.mode`）で client/server モードを切り替え可能。Client モード時はインバウンドクエリを拒否する（Go/Rust 互換）。✅ GAP-6 で実装済み。

## Usage

```swift
let dht = KademliaService(
    localPeerID: myPeerID,
    configuration: .init(
        mode: .server,
        cleanupInterval: .seconds(300)  // 5分ごとに期限切れレコード削除
    )
)
await dht.registerHandler(registry: node)

// Start background maintenance (TTL cleanup)
dht.startMaintenance()

// Bootstrap
try await dht.bootstrap(using: node, seeds: bootstrapPeers)

// Find peers
let peers = try await dht.findNode(peerID, using: node)

// Store/retrieve values
try await dht.putValue(key: key, value: data, using: node)
let record = try await dht.getValue(key: key, using: node)

// Provider operations
try await dht.provide(key: contentID, addresses: listenAddrs, using: node)
let providers = try await dht.getProviders(for: contentID, using: node)

// Shutdown (stops maintenance task)
dht.shutdown()
```

## Events

```swift
public enum KademliaEvent {
    // Routing table
    case peerAdded(PeerID, bucket: Int)
    case peerRemoved(PeerID, bucket: Int)
    case peerUpdated(PeerID)

    // Query lifecycle
    case queryStarted(QueryInfo)
    case querySucceeded(QueryInfo, result: QueryResultInfo)
    case queryFailed(QueryInfo, error: String)

    // Records & Providers
    case recordStored(key: Data)
    case recordRetrieved(key: Data, from: PeerID?)
    case providerAdded(key: Data)
    case providersFound(key: Data, count: Int)

    // Service lifecycle
    case started
    case stopped
    case modeChanged(KademliaMode)

    // Maintenance (NEW)
    case maintenanceCompleted(recordsRemoved: Int, providersRemoved: Int)
}
```

## Test Strategy

1. **Unit tests**: Key/distance calculations, k-bucket operations, protobuf encoding
2. **Integration tests**: Multi-node DHT with MemoryTransport
3. **Interop tests**: go-libp2p DHT との FIND_NODE / PUT_VALUE / GET_VALUE / GET_PROVIDERS wire 往復を検証（rust は継続中）

## 既知の制限事項

### レコードストレージ
- ✅ `RecordStore`と`ProviderStore`はプラグイン可能なバックエンドに対応（`RecordStorage`/`ProviderStorage`プロトコル）
- ✅ デフォルトはインメモリ、`FileRecordStorage`/`FileProviderStorage`で永続化可能
- ✅ TTLベースのガベージコレクションは `startMaintenance()` で実装済み

### RecordValidator.Select
- ✅ **実装済み** — `select(key:records:)` メソッドを `RecordValidator` プロトコルに追加 ✅ 2026-01-30
- デフォルト実装は index 0 を返す（既存動作と後方互換）
- `KademliaQuery` が GET_VALUE で複数レコードを収集し `select()` で最良を選択
- `NamespacedValidator` は対応するネームスペースバリデータに委譲
- `SignedRecordValidator` はタイムスタンプ比較で最新を選択

### Client/Server モード制限
- ✅ Client モード時のインバウンドクエリ拒否は実装済み (GAP-6) ✅ 2026-01-28

### 署名付きレコード
- レコード署名フィールドは存在するが検証未実装
- 信頼されたノードからのレコードのみ受け入れ

### クエリ
- ~~クエリタイムアウトは全ピアで均一~~ → `peerTimeout` (10秒) で個別タイムアウト実装済み
- ~~ピアごとのレイテンシ追跡なし~~ → `PeerLatencyTracker` で実装済み（動的タイムアウト計算可能）

## 内部実装詳細

### QueryDelegateImpl
クエリ状態機械は`QueryDelegateImpl`パターンを使用:
```swift
class QueryDelegateImpl: QueryDelegate {
    // クエリ進行のコールバック処理
    // ルーティングテーブル自動更新
}
```

### addPeer自動更新
レスポンス受信時にルーティングテーブルを自動更新

## S/Kademlia (Secure Kademlia)

S/Kademliaは、標準Kademliaにセキュリティ機能を追加したものです。SybilattackやEclipse攻撃への耐性を向上させます。

### 実装済み機能

#### ノードID暗号学的検証 ✅

ノードIDが公開鍵から正しく派生しているかを検証します。攻撃者が任意のノードIDを選択してDHT内の戦略的な位置に配置することを防ぎます。

- `SKademliaValidator.validateNodeID()` - ピアIDと公開鍵の整合性を検証
- `SKademliaConfig.validateNodeIDs` - 検証の有効化/無効化

#### 設定

```swift
// S/Kademlia無効（デフォルト）
let kad = KademliaService(
    localPeerID: myPeerID,
    configuration: .default
)

// S/Kademlia有効（すべてのセキュリティ機能）
let kad = KademliaService(
    localPeerID: myPeerID,
    configuration: .secure
)

// カスタム設定
let skademlia = SKademliaConfig(
    enabled: true,
    validateNodeIDs: true,
    useSiblingBroadcast: true,
    siblingCount: 2,
    useDisjointPaths: true,
    disjointPathCount: 2
)
let kad = KademliaService(
    localPeerID: myPeerID,
    configuration: KademliaConfiguration(skademlia: skademlia)
)
```

#### Sibling Broadcast（兄弟ブロードキャスト）✅

異なる距離帯（bucket index）から追加ピアを選択し、クエリの多様性を確保します。Eclipse攻撃耐性を向上させます。

- 実装状況: ✅ 完了 (2026-02-06)
- `KademliaQuery.selectCandidates` でalphaの最近接ピアに加え、残りのピアをbucketIndexでグループ化しラウンドロビンで`siblingCount`個を追加選択
- `SKademliaConfig.useSiblingBroadcast` で有効化

#### Disjoint Paths（独立経路）✅

複数の独立した初期ピアセットで並列ルックアップを実行し、結果をマージします。単一の悪意あるノードがクエリパス全体を制御することを防止します。

- 実装状況: ✅ 完了 (2026-02-06)
- `KademliaQuery.executeDisjointPaths` で初期ピアを距離順ラウンドロビンでd個のグループに分割し、`withThrowingTaskGroup`で並列実行
- 結果は`mergeResults`でクエリタイプ別にマージ（findNode: 重複排除+距離順、getValue: 最良レコード選択、getProviders: 重複排除）
- `SKademliaConfig.useDisjointPaths` で有効化

## 品質向上TODO

### 高優先度
- [x] **RecordValidator フレームワーク実装** - アプリケーション層でレコード検証可能に ✅ 2026-01-23
  - `RecordValidator` プロトコル、`NamespacedValidator`、`CompositeValidator` など
  - `KademliaConfiguration.recordValidator` で設定
  - `recordRejected` イベントで拒否を通知
- [x] **レコードTTLガベージコレクション** - `cleanupInterval` 設定と `startMaintenance()` で自動クリーンアップ実装 ✅ 2026-01-23
  - **注意**: `startMaintenance()` を明示的に呼び出す必要あり
- [x] **ProviderStore TTL強制** - 自動メンテナンスタスクで期限切れプロバイダを削除 ✅ 2026-01-23

### 中優先度
- [x] **RecordValidator.Select 実装** - 同一キーの複数レコードから最適なものを選択 ✅ 2026-01-30
- [x] **Client モードのインバウンドクエリ拒否** - Go/Rust 互換の動作制限 ✅ 2026-01-28 (GAP-6)
- [x] **永続化ストレージオプション** - `FileRecordStorage`/`FileProviderStorage` で実装 ✅ 2026-01-30
- [x] **ピアごとのタイムアウト** - `peerTimeout` 設定で実装 ✅ 2026-01-23
- [x] **ピアレイテンシ追跡** - `PeerLatencyTracker` で実装、クエリRTT計測・平均レイテンシ・成功率・動的タイムアウト計算 ✅ 2026-02-06
- [x] **クエリ並列度の動的調整** - `enableDynamicAlpha` 設定、`currentAlpha()` でネットワーク状態に応じたALPHA調整 ✅ 2026-02-06
- [ ] **Envelope 統合バリデータ** - P2PCore の Envelope/SignedRecord と統合した署名検証

### 低優先度
- [x] **S/Kademlia基本実装** - ノードID検証、設定フレームワーク ✅ 2026-02-03
  - `SKademliaConfig` - 設定オプション
  - `SKademliaValidator` - ノードID検証ユーティリティ
  - 11個のテストすべてパス
- [x] **S/Kademlia Sibling Broadcast実装** - クエリロジックへの統合 ✅ 2026-02-06
- [x] **S/Kademlia Disjoint Paths実装** - 複数経路クエリ ✅ 2026-02-06
- [x] **レコードリパブリッシュ** - `startRepublish()` でバックグラウンドタスク実行、レコード＆プロバイダの定期的な再配布 ✅ 2026-02-06
- [x] **プロバイダキャッシング** - `getProviders` 結果をローカル `providerStore` にキャッシュ、ネットワーク検索前にキャッシュ確認 ✅ 2026-02-06

## Fixes Applied

### ContinuousClock → Date 永続化修正 (2026-01-31)

**問題**: `FileRecordStorage` と `FileProviderStorage` が `ContinuousClock.Instant` をそのまま JSON にシリアライズしていた。`ContinuousClock.Instant` はモノトニック・プロセス固有のため、プロセス再起動後にデシリアライズしたTTLが無効になる

**解決策**: ウォールクロック `Date`（`timeIntervalSinceReferenceDate`）でタイムスタンプを保存し、ロード時にモノトニック `ContinuousClock.Instant` に変換するヘルパー関数を追加

**修正ファイル**: `Storage/FileRecordStorage.swift`, `Storage/FileProviderStorage.swift`

### ProviderStore.clear() 修正 (2026-01-31)

**問題**: `ProviderStore.clear()` が `backend.cleanup()` を呼んでいたが、`cleanup()` は期限切れレコードのみ削除する。`clear()` の意図は全レコード削除

**解決策**: `ProviderStorage` プロトコルに `removeAll()` メソッドを追加。`InMemoryProviderStorage` と `FileProviderStorage` に実装。`ProviderStore.clear()` を `backend.removeAll()` に修正

**修正ファイル**: `Storage/ProviderStorage.swift`, `Storage/InMemoryProviderStorage.swift`, `Storage/FileProviderStorage.swift`, `ProviderStore.swift`

## References

- [Kademlia Paper](https://pdos.csail.mit.edu/~petar/papers/maymounkov-kademlia-lncs.pdf)
- [libp2p Kademlia Spec](https://github.com/libp2p/specs/tree/master/kad-dht)
- [rust-libp2p kad](https://github.com/libp2p/rust-libp2p/tree/master/protocols/kad)

## テスト実装状況

| テストスイート | テスト数 | 説明 |
|--------------|---------|------|
| `KademliaKeyTests` | 12 | キー作成、距離計算、バリデーション |
| `KBucketTests` | 4 | バケット操作 |
| `RoutingTableTests` | 5 | ルーティングテーブル |
| `ProtobufTests` | 4 | Protobufエンコード/デコード |
| `RecordStoreTests` | 4 | レコード保存、TTL |
| `ProviderStoreTests` | 4 | プロバイダ保存、TTL |
| `InMemoryRecordStorageTests` | 6 | インメモリレコードストレージ |
| `InMemoryProviderStorageTests` | 5 | インメモリプロバイダストレージ |
| `FileRecordStorageTests` | 6 | ファイルベースレコードストレージ |
| `FileProviderStorageTests` | 4 | ファイルベースプロバイダストレージ |
| `RecordStoreCustomBackendTests` | 7 | カスタムバックエンド統合 |
| `KademliaQueryTests` | 5 | クエリ、タイムアウト |
| `KademliaServiceTests` | 6 | サービス初期化、モード |
| `ProtocolInputValidationTests` | 10 | 入力検証 |
| `RecordValidatorTests` | 11 | バリデータ検証 |
| `SKademliaSiblingBroadcastTests` | 8 | Sibling Broadcast選択 |
| `SKademliaDisjointPathsTests` | 15 | Disjoint Paths分割・マージ |
| `PeerLatencyTrackerTests` | 22 | レイテンシ追跡、成功率、タイムアウト計算 |
| `RandomWalkRefreshTests` | 5 | ランダムウォーク、バケットリフレッシュ |
| `ClientModeTests` | 4 | クライアントモード設定 |

**合計: 153テスト** (2026-02-06時点)

## Codex Review (2026-01-18)

### Critical
| Issue | Location | Status | Description |
|-------|----------|--------|-------------|
| ~~Remote crash via malformed key~~ | `KademliaService.swift:283-287`, `KademliaKey.swift:30-41` | ✅ Fixed | Fixed by using `KademliaKey(validating:)` which throws `KademliaKeyError.invalidLength` for non-32-byte keys instead of crashing |

### Warning
| Issue | Location | Status | Description |
|-------|----------|--------|-------------|
| ~~Query timeout never used~~ | `KademliaQuery.swift` | ✅ Fixed | Query timeout is now enforced via TaskGroup race |
| ~~Per-peer send/receive no timeout~~ | `KademliaService.swift:740-766` | ✅ Fixed | Added `peerTimeout` config (10s default), `withPeerTimeout` helper, and guaranteed stream cleanup on timeout |

### Info
| Issue | Location | Status | Description |
|-------|----------|--------|-------------|
| Record republish uses defaultTTL | `RecordStore.swift:147-166` | ⬜ Open | Custom TTL records use defaultTTL for republish timing |

### Tests Added
- `KademliaKeyTests.validatingAccepts32Bytes` - Valid 32-byte input accepted
- `KademliaKeyTests.validatingRejectsShortInput` - 16-byte input rejected with proper error
- `KademliaKeyTests.validatingRejectsLongInput` - 64-byte input rejected with proper error
- `KademliaKeyTests.validatingRejectsEmptyInput` - Empty input rejected with proper error
- `KademliaKeyTests.invalidLengthEquatable` - Error type is Equatable
- `ProtocolInputValidationTests.findNodeInvalidKeyLengthRejected` - FIND_NODE with invalid key rejected
- `ProtocolInputValidationTests.findNodeValidKeyAccepted` - FIND_NODE with valid key accepted
- `ProtocolInputValidationTests.getValueAcceptsArbitraryKeyLength` - GET_VALUE/GET_PROVIDERS accept any length
- `ProtocolInputValidationTests.boundaryCondition31Bytes` - Boundary test for 31 bytes
- `ProtocolInputValidationTests.boundaryCondition33Bytes` - Boundary test for 33 bytes

<!-- CONTEXT_EVAL_START -->
## 実装評価 (2026-02-16)

- 総合評価: **A** (92/100)
- 対象ターゲット: `P2PKademlia`
- 実装読解範囲: 23 Swift files / 6573 LOC
- テスト範囲: 36 files / 306 cases / targets 3
- 公開API: types 61 / funcs 56
- 参照網羅率: type 0.66 / func 0.7
- 未参照公開型: 21 件（例: `DefaultBehavior`, `FileProviderStorageError`, `FileRecordStorageError`, `InsertResult`, `KBucketEntry`）
- 実装リスク指標: try?=0, forceUnwrap=0, forceCast=0, @unchecked Sendable=0, EventLoopFuture=0, DispatchQueue=0
- 評価所見: 重大な静的リスクは検出されず

### 重点アクション
- 未参照の公開型に対する直接テスト（生成・失敗系・境界値）を追加する。

※ 参照網羅率は「テストコード内での公開API名参照」を基準にした静的評価であり、動的実行結果そのものではありません。

<!-- CONTEXT_EVAL_END -->
