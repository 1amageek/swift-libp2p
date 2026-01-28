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
| `RecordStore.swift` | Protocol and in-memory implementation |
| `ProviderStore.swift` | Provider record storage |
| `KademliaRecord.swift` | DHT record type |
| `KademliaQuery.swift` | Query types and state machine |
| `KademliaService.swift` | Main service (NetworkBehaviour equivalent) |
| `KademliaEvent.swift` | Event types |

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

### ⚠️ 制限事項: Client/Server モード
設定（`KademliaConfiguration.mode`）は存在するが、現在の実装では **client モードでもクエリへの応答を制限しない**。モード設定はプロトコルの advertise 有無にのみ影響する。Go/Rust 実装では client モード時にインバウンドクエリを拒否するが、この動作は未実装。

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
3. **Interop tests**: Connect to rust-libp2p/go-libp2p DHT nodes

## 既知の制限事項

### レコードストレージ
- `RecordStore`と`ProviderStore`はメモリのみ（❌ 永続化ストレージ未実装）
- ✅ TTLベースのガベージコレクションは `startMaintenance()` で実装済み

### RecordValidator.Select
- ❌ **未実装** — 同一キーに複数のレコードがある場合の最適レコード選択機能
- Go/Rust 実装では `Select(key, records)` で最適なレコードを選ぶが、本実装は `Validate` のみ

### Client/Server モード制限
- ⚠️ Client モード設定はプロトコル advertise の有無にのみ影響
- Client モード時のインバウンドクエリ拒否は未実装

### 署名付きレコード
- レコード署名フィールドは存在するが検証未実装
- 信頼されたノードからのレコードのみ受け入れ

### クエリ
- ~~クエリタイムアウトは全ピアで均一~~ → `peerTimeout` (10秒) で個別タイムアウト実装済み
- ピアごとのレイテンシ追跡なし（動的タイムアウト調整なし）

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
- [ ] **RecordValidator.Select 実装** - 同一キーの複数レコードから最適なものを選択
- [ ] **Client モードのインバウンドクエリ拒否** - Go/Rust 互換の動作制限
- [ ] **永続化ストレージオプション** - SQLite/ファイルベース
- [x] **ピアごとのタイムアウト** - `peerTimeout` 設定で実装 ✅ 2026-01-23
- [ ] **ピアレイテンシ追跡** - 過去のレスポンス時間に基づく動的タイムアウト調整
- [ ] **クエリ並列度の動的調整** - ネットワーク状態に応じたALPHA調整
- [ ] **Envelope 統合バリデータ** - P2PCore の Envelope/SignedRecord と統合した署名検証

### 低優先度
- [ ] **S/Kademliaの完全実装** - Sybil攻撃耐性向上
- [ ] **レコードリパブリッシュ** - 定期的なレコード再配布
- [ ] **プロバイダキャッシング** - 頻繁に要求されるCIDのキャッシュ

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
| `KademliaQueryTests` | 5 | クエリ、タイムアウト |
| `KademliaServiceTests` | 6 | サービス初期化、モード |
| `ProtocolInputValidationTests` | 10 | 入力検証 |
| `RecordValidatorTests` | 11 | バリデータ検証 |

**合計: 65テスト** (2026-01-23時点)

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
