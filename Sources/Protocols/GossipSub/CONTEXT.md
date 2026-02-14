# P2PGossipSub

## 概要

GossipSub は libp2p の Pub/Sub プロトコル実装。FloodSub を拡張し、各トピックで部分的なメッシュネットワークを維持することで、スケーラビリティと帯域効率を向上させる。

## 責務

- トピックベースの Publish/Subscribe メッセージング
- メッシュネットワークの維持管理
- ゴシッププロトコルによる効率的なメッセージ伝播
- ピアスコアリングによる信頼性管理

## Protocol IDs

- `/meshsub/1.1.0` - GossipSub v1.1
- `/meshsub/1.2.0` - GossipSub v1.2 (IDONTWANT support)
- `/floodsub/1.0.0` - FloodSub 互換 (後方互換性)

## 依存関係

- `P2PCore` (PeerID, Multiaddr)
- `P2PMux` (MuxedStream)
- `P2PProtocols` (ProtocolService, StreamOpener, HandlerRegistry)

---

## ファイル構成

```
Sources/Protocols/GossipSub/
├── CONTEXT.md                    # このファイル
│
├── GossipSubService.swift        # メインサービス (ProtocolService実装)
├── GossipSubConfiguration.swift  # 設定パラメータ
├── GossipSubEvent.swift          # イベント定義
├── GossipSubError.swift          # エラー定義
│
├── Core/
│   ├── Topic.swift               # トピック型
│   ├── Message.swift             # Pub/Sub メッセージ
│   ├── MessageID.swift           # メッセージ識別子
│   └── Subscription.swift        # サブスクリプション管理
│
├── Router/
│   ├── GossipSubRouter.swift     # メイン状態機械 (class + Mutex)
│   ├── MeshState.swift           # メッシュ状態
│   ├── PeerState.swift           # ピアごとの状態
│   └── MessageCache.swift        # メッセージキャッシュ (IHAVE/IWANT用)
│
├── Scoring/
│   ├── PeerScorer.swift          # ピアスコアリング (Sybil/スパム防御)
│   └── TopicScoreParams.swift    # Per-topic スコアリングパラメータ (v1.1)
│
├── Heartbeat/
│   └── HeartbeatManager.swift    # 定期メンテナンス処理
│
└── Wire/
    ├── GossipSubRPC.swift        # RPC メッセージ型
    ├── ControlMessage.swift      # 制御メッセージ (GRAFT/PRUNE/IHAVE/IWANT)
    └── GossipSubProtobuf.swift   # Protobuf エンコード/デコード
```

---

## 主要な型

| 型名 | 説明 |
|-----|------|
| `GossipSubService` | プロトコルサービス実装 (ユーザーAPI) |
| `GossipSubConfiguration` | メッシュパラメータ等の設定 |
| `GossipSubRouter` | コア状態管理 (class + Mutex) |
| `PeerScorer` | ピアスコアリング (スパム/Sybil防御) |
| `PeerScorerConfig` | スコアリング設定 |
| `TopicScoreParams` | Per-topicスコアリングパラメータ (v1.1) |
| `Topic` | トピック識別子 |
| `Message` | Pub/Subメッセージ |
| `MessageID` | メッセージ一意識別子 |
| `GossipSubRPC` | ワイヤープロトコルRPCメッセージ |
| `ControlMessage` | 制御メッセージ (GRAFT/PRUNE等) |
| `GossipSubEvent` | イベント通知 |
| `GossipSubError` | エラー型 |

---

## Wire Protocol

### Protobuf Schema

```protobuf
message RPC {
  repeated SubOpts subscriptions = 1;
  repeated Message publish = 2;
  optional ControlMessage control = 3;
}

message SubOpts {
  optional bool subscribe = 1;
  optional string topicid = 2;
}

message Message {
  optional bytes from = 1;
  optional bytes data = 2;
  optional bytes seqno = 3;
  required string topic = 4;
  optional bytes signature = 5;
  optional bytes key = 6;
}

message ControlMessage {
  repeated ControlIHave ihave = 1;
  repeated ControlIWant iwant = 2;
  repeated ControlGraft graft = 3;
  repeated ControlPrune prune = 4;
  // v1.2: repeated ControlIDontWant idontwant = 5;
}

message ControlIHave {
  optional string topicID = 1;
  repeated bytes messageIDs = 2;
}

message ControlIWant {
  repeated bytes messageIDs = 1;
}

message ControlGraft {
  optional string topicID = 1;
}

message ControlPrune {
  optional string topicID = 1;
  repeated PeerInfo peers = 2;  // v1.1: Peer Exchange
  optional uint64 backoff = 3;  // v1.1: Backoff period
}
```

### Message Flow

**Publish:**
```
Publisher                Mesh Peers              Non-Mesh Peers
    |                        |                        |
    |--- Message ----------->|                        |
    |                        |--- Message ----------->|
    |                        |--- IHAVE (gossip) --->|
    |                        |                        |
    |                        |<-- IWANT (if needed) --|
    |                        |--- Message ----------->|
```

**Subscribe:**
```
Node                     Mesh Peers
    |                        |
    |--- SUBSCRIBE --------->|  (SubOpts)
    |<-- GRAFT --------------|  (join mesh)
    |--- GRAFT ------------->|  (confirm mesh)
```

**Heartbeat (every 1s):**
```
1. Mesh Maintenance
   - If |mesh| < D_low: Add peers (GRAFT)
   - If |mesh| > D_high: Remove peers (PRUNE)

2. Fanout Maintenance
   - Remove stale entries (> fanout_ttl)
   - Ensure D peers in active fanouts

3. Gossip Emission
   - Select D_lazy peers not in mesh
   - Send IHAVE for cached message IDs
```

---

## メッシュパラメータ

| パラメータ | 説明 | デフォルト |
|-----------|------|-----------|
| D | ターゲットメッシュ次数 | 6 |
| D_low | メッシュ追加閾値 | 4 |
| D_high | メッシュ削除閾値 | 12 |
| D_lazy | ゴシップ次数 | 6 |
| D_out | 最小アウトバウンド接続 | 2 |
| heartbeat_interval | ハートビート間隔 | 1秒 |
| fanout_ttl | ファンアウトTTL | 60秒 |
| mcache_len | キャッシュ長 (heartbeats) | 5 |
| mcache_gossip | ゴシップ対象キャッシュ長 | 3 |
| seen_ttl | 既読メッセージTTL | 2分 |

---

## アーキテクチャ

### 設計原則

**class + Mutex パターン採用理由:**
- メッセージルーティングは超高頻度操作
- Actor の直列化オーバーヘッドを回避
- 独立した操作 (publish/subscribe/mesh管理) の並列実行が重要
- ロックを最小範囲に限定してスループット向上

### コンポーネント関係

```
┌─────────────────────────────────────────────────────────────┐
│  GossipSubService (public API - ProtocolService)            │
│  - subscribe(topic)                                         │
│  - unsubscribe(topic)                                       │
│  - publish(topic, data)                                     │
│  - messages(for: topic) -> AsyncStream<Message>            │
├─────────────────────────────────────────────────────────────┤
│  GossipSubRouter (class + Mutex - internal state machine)   │
│  - MeshState: [Topic: Set<PeerID>]                         │
│  - PeerState: [PeerID: PeerInfo]                           │
│  - MessageCache: LRU cache for IHAVE/IWANT                  │
│  - SeenCache: Bloom filter or Set for deduplication        │
├─────────────────────────────────────────────────────────────┤
│  HeartbeatManager (Task - periodic maintenance)             │
│  - Mesh maintenance (GRAFT/PRUNE)                          │
│  - Fanout cleanup                                           │
│  - Gossip emission (IHAVE)                                  │
├─────────────────────────────────────────────────────────────┤
│  Wire Protocol (GossipSubRPC, GossipSubProtobuf)           │
│  - Protobuf encoding/decoding                               │
│  - RPC message handling                                     │
└─────────────────────────────────────────────────────────────┘
```

### 状態遷移

**ピア状態:**
```
Unknown -> Connected -> Subscribed -> Meshed -> Pruned -> Disconnected
                           |                      ^
                           +----------------------+
                              (re-graft after backoff)
```

**トピック状態:**
```
Not Subscribed -> Subscribed (in mesh) -> Fanout (publish only) -> Not Subscribed
```

---

## API

### 基本使用

```swift
let gossipsub = GossipSubService(configuration: .init(
    meshDegree: 6,
    heartbeatInterval: .seconds(1)
))

// Handler 登録
await gossipsub.registerHandler(registry: node)

// Subscribe
let subscription = try await gossipsub.subscribe(to: "my-topic")

// Receive messages
for await message in subscription.messages {
    print("Received: \(message.data)")
}

// Publish
try await gossipsub.publish(to: "my-topic", data: myData, using: node)

// Unsubscribe
await gossipsub.unsubscribe(from: "my-topic")
```

### イベント監視

```swift
for await event in gossipsub.events {
    switch event {
    case .subscribed(let topic):
        print("Subscribed to \(topic)")
    case .unsubscribed(let topic):
        print("Unsubscribed from \(topic)")
    case .messageReceived(let topic, let message):
        print("Message on \(topic)")
    case .peerJoinedMesh(let peer, let topic):
        print("\(peer) joined mesh for \(topic)")
    case .peerLeftMesh(let peer, let topic):
        print("\(peer) left mesh for \(topic)")
    }
}
```

---

## Go/Rust 相互運用

### 検証項目

1. **Protobuf互換性**: メッセージのエンコード/デコードが一致
2. **メッシュ形成**: GRAFT/PRUNEでメッシュが正しく形成される
3. **メッセージ伝播**: PublishしたメッセージがSubscriberに到達
4. **ゴシップ**: IHAVE/IWANTでキャッシュからメッセージ取得

### テストベクトル

rust-libp2p の gossipsub テストを参照:
- `protocols/gossipsub/src/behaviour/tests/`
- `protocols/gossipsub/src/protocol.rs`

---

## テスト

```
Tests/Protocols/GossipSubTests/
├── Core/
│   ├── TopicTests.swift
│   ├── MessageTests.swift
│   └── MessageIDTests.swift
├── Router/
│   ├── GossipSubRouterTests.swift
│   ├── MeshStateTests.swift
│   └── MessageCacheTests.swift
├── Scoring/
│   └── PeerScorerTests.swift        # スコアリングテスト (34テスト: グローバル21 + Per-topic13)
├── Wire/
│   ├── GossipSubProtobufTests.swift
│   └── ControlMessageTests.swift
├── GossipSubServiceTests.swift
└── GossipSubInteropTests.swift    # Go/Rust相互運用
```

---

## 既知の制限事項

### メッセージ署名
- 署名検証は実装済み、デフォルトで有効
- 未署名メッセージは拒否（StrictSignモード）
- 2020年以前のレガシー実装との互換性は非対応

### ピアスコアリング
- ~~概要では言及されているが完全未実装~~ ✅ 2026-01-23 実装
- バックオフ追跡実装済み
- 各種ペナルティ追跡実装済み（詳細は下記）
- ✅ **per-topic scoring 実装済み** — P1(Time in Mesh), P2(First Message Deliveries), P3(Mesh Message Delivery Deficit), P3b(Mesh Failure Penalty), P4(Invalid Messages) ✅ 2026-01-30

### IDONTWANT (v1.2)
- ✅ データモデル（`ControlMessage.IDontWant`）
- ✅ protobuf encode/decode（`GossipSubProtobuf` field 5: `ControlIDontWant`）
- ✅ `PeerState.dontWantMessages` で受信済みメッセージの追跡
- ✅ `GossipSubRouter.sendIDontWant()` で v1.2 ピアへの送信
- ✅ `GossipSubRouter.handleIDontWants()` で受信処理

### バッファ制限
- RPCサイズ: 最大5MB
- バッファオーバーフロー保護あり

## 追加の実装詳細

### SeenCache
重複排除用のキャッシュ:
- TTLベースのメッセージID追跡
- Bloomフィルタまたは単純なSetで実装

### ピア方向追跡
各ピアのinbound/outbound方向を追跡:
- メッシュバランシングに使用
- D_out制約の強制

---

## 品質向上TODO

### 高優先度
- [x] **メッセージ署名検証の実装** - `validateSignatures=true`(デフォルト)で署名検証実行、`verifySignature()`で検証 ✅ 2026-01-18
- [x] **ピアスコアリングの実装** - 完全なスコアリングシステム実装 ✅ 2026-01-23
  - IWANT重複追跡（過剰リクエスト検出）
  - メッセージ配信率追跡（最初の配信ボーナス、低配信率ペナルティ）
  - IPコロケーション追跡（Sybil攻撃防御）
  - スコア減衰機能
  - グレイリストによるメッシュ除外
- [ ] **GossipSubRouterテストの追加** - メッシュ管理ロジックの検証
- [ ] **MessageCacheテストの追加** - IHAVE/IWANTキャッシュ動作検証

### 中優先度
- [x] **IDONTWANT protobuf encode/decode** - ControlIDontWant のワイヤーフォーマット実装（v1.2 完全サポート）
- [x] **Per-topic scoring** - トピックごとのスコアリングパラメータ（v1.1 仕様準拠）✅ 2026-01-30
- [ ] **Peer Exchange検証** - PRUNEメッセージのピア情報交換テスト
- [ ] **バックオフ期間の強制テスト** - PRUNE後の再GRAFT防止
- [ ] **ハートビートタイミングテスト** - 1秒間隔の正確性検証

### 低優先度
- [ ] **FloodSub後方互換性テスト** - `/floodsub/1.0.0`との互換性
- [ ] **大規模メッシュシミュレーション** - 100+ノードでのスケーラビリティ
- [ ] **メッセージ重複検出の最適化** - BloomフィルタによるSeenCache改善

---

## 参照

- [GossipSub v1.0 Spec](https://github.com/libp2p/specs/blob/master/pubsub/gossipsub/gossipsub-v1.0.md)
- [GossipSub v1.1 Spec](https://github.com/libp2p/specs/blob/master/pubsub/gossipsub/gossipsub-v1.1.md)
- [rust-libp2p gossipsub](https://github.com/libp2p/rust-libp2p/tree/master/protocols/gossipsub)
- [go-libp2p-pubsub](https://github.com/libp2p/go-libp2p-pubsub)

## Codex Review (2026-01-18, Updated 2026-02-14)

### Warning
| Issue | Location | Status | Description |
|-------|----------|--------|-------------|
| Signature validation not enforced | `GossipSubConfiguration.swift` | ✅ Fixed | Default `strictSignatureVerification=false` allowed unsigned spoofed messages. Changed default to `true` |
| Non-cryptographic hash in MessageID | `Core/MessageID.swift` | ✅ N/A | Already uses SHA-256 (cryptographic hash), not Swift Hasher |

### Info
| Issue | Location | Status | Description |
|-------|----------|--------|-------------|
| Publish doesn't enforce maxMessageSize | `Router/GossipSubRouter.swift` | ✅ Fixed | `publish()` 冒頭で `configuration.maxMessageSize` を検証し、超過時は `messageTooLarge` を返す。`routerPublishRejectsOversizedData` で回帰確認 |

## Fixes Applied

### Signature Validation Enforcement (2026-01-18)

**問題**: `strictSignatureVerification=false`がデフォルトで、署名のないなりすましメッセージが受け入れられていた

**解決策**:
1. `strictSignatureVerification`のデフォルトを`true`に変更（セキュアデフォルト）
2. ドキュメントを改善して署名検証オプションの動作を明確化

**修正ファイル**:
- `GossipSubConfiguration.swift` - デフォルト値変更
- `Tests/Protocols/GossipSubTests/GossipSubRouterTests.swift` - テスト設定を`.testing`に更新

**動作**:
- 署名必須、未署名メッセージは拒否
- 2020年以前のレガシー実装（未署名メッセージ）との互換性は非対応

### ピアスコアリング強化 (2026-01-23)

**問題**: ピアスコアリングがバックオフ追跡のみで、スパム/Sybil攻撃への防御が不十分だった

**解決策**: 包括的なスコアリングシステムを実装

**新機能**:

1. **IWANT重複追跡**
   - 同じメッセージへの過剰なIWANTリクエストを検出
   - `iwantDuplicateThreshold` (デフォルト: 3回) 以上でペナルティ
   - ウィンドウベースの追跡 (`iwantTrackingWindow`: 60秒)

2. **メッセージ配信追跡**
   - 最初の配信者にボーナス (`firstDeliveryBonus`: +5.0)
   - 低配信率ピアにペナルティ (`minDeliveryRate`: 80%)
   - ハートビートで配信率を評価

3. **IPコロケーション追跡 (Sybil防御)**
   - 同一IPからの複数ピアを追跡
   - 閾値超過でペナルティ (`ipColocationThreshold`: 2)
   - IPv4-mapped IPv6の正規化

4. **スコア減衰**
   - 時間経過でスコアが回復 (`decayFactor`: 0.9, 60秒間隔)
   - グレイリスト閾値 (`graylistThreshold`: -1000.0)

**修正ファイル**:
- `Scoring/PeerScorer.swift` - 追跡状態と新メソッド追加
- `Router/GossipSubRouter.swift` - IWANT追跡、配信追跡、IP登録メソッド追加
- `GossipSubEvent.swift` - `sybilSuspected`, `lowDeliveryRate`, `ipColocation` イベント追加

**使用例**:
```swift
let config = PeerScorerConfig(
    ipColocationThreshold: 3,      // 同一IPから3ピアまで許可
    ipColocationPenalty: -20.0,    // 超過時のペナルティ
    minDeliveryRate: 0.7,          // 70%以上の配信率を期待
    lowDeliveryPenalty: -50.0      // 低配信率ペナルティ
)
let router = GossipSubRouter(
    localPeerID: myPeerID,
    peerScorerConfig: config
)

// ピア接続時にIPを登録
router.registerPeerIP(peerID, ip: "192.0.2.1")

// ハートビートでスコアリングメンテナンス
router.performScoringMaintenance()
```

**テスト**: `Tests/Protocols/GossipSubTests/PeerScorerTests.swift` (34テスト: グローバル21 + Per-topic13)

### Per-topic スコアリング実装 (2026-01-30)

**新機能**: GossipSub v1.1 仕様に準拠した per-topic スコアリング

**実装内容**:

1. **TopicScoreParams** (`Scoring/TopicScoreParams.swift`)
   - P1: Time in Mesh (mesh参加時間ボーナス)
   - P2: First Message Deliveries (最初の配信ボーナス)
   - P3: Mesh Message Delivery Deficit (配信不足ペナルティ)
   - P3b: Mesh Failure Penalty (mesh障害ペナルティ)
   - P4: Invalid Messages (無効メッセージペナルティ)
   - トピック重み (`topicWeight`) で全体スコアへの寄与度を制御

2. **PeerScorer 拡張**
   - `peerJoinedMesh()` / `peerLeftMesh()` — mesh参加/離脱追跡
   - `recordFirstMessageDelivery()` / `recordMeshMessageDelivery()` — 配信追跡
   - `recordInvalidMessageDelivery()` / `recordMeshFailure()` — ペナルティ追跡
   - `computeScore(for:)` — グローバル + per-topic の総合スコア計算
   - per-topic カウンタへの減衰 (`applyDecayToAll()`)

3. **GossipSubRouter 統合**
   - GRAFT 時: `peerJoinedMesh()`
   - PRUNE 時: `peerLeftMesh()` + delivery deficit があれば `recordMeshFailure()`
   - メッセージ受信時: `recordFirstMessageDelivery()` / `recordMeshMessageDelivery()`
   - 無効メッセージ時: `recordInvalidMessageDelivery()`

4. **GossipSubConfiguration 拡張**
   - `topicScoreParams: [String: TopicScoreParams]` — per-topic 設定
   - `defaultTopicScoreParams: TopicScoreParams?` — デフォルト設定

**テスト**: 13 per-topic テスト追加（合計34テスト）

### Per-topic スコアリング mesh 管理修正 (2026-01-31)

**問題**: `isGraylisted()` と `sortByScore()` がグローバルスコア (`score(for:)`) のみを使用し、per-topic スコアが mesh 管理判断に反映されていなかった

**解決策**: `isGraylisted()` と `sortByScore()` を `computeScore(for:)` 経由に変更。`selectBestPeers()` と `filterGraylisted()` も per-topic スコアを考慮するようになった

**修正ファイル**: `Scoring/PeerScorer.swift`

### PeerScorer ネストロック解消 (2026-01-31)

**問題**: `applyDeliveryRatePenalties()` と `registerPeerIP()` で `deliveryTracking`/`ipColocation` ロック内から `scores` ロックを取得するネストパターンがあった

**解決策**: ロック内でデータを収集し、ロック外でスコア変更を適用するパターンに修正。デッドロックリスクを排除

**修正ファイル**: `Scoring/PeerScorer.swift`

---

## Known Issues (2026-01-26 レビュー)

### LOW: IDONTWANT 辞書のサイズ上限なし

**場所**: `Router/PeerState.swift` - `dontWantMessages` 辞書

**問題**: ピアが大量の IDONTWANT メッセージを送信した場合、辞書が無制限に成長する可能性がある

**対応**: `addDontWant()` に最大サイズチェックを追加

```swift
private let maxDontWantEntries = 10000

func addDontWant(_ messageID: MessageID) {
    guard dontWantMessages.count < maxDontWantEntries else { return }
    dontWantMessages[messageID] = .now
}
```

### INFO: HeartbeatManager のライフサイクル文書化

**場所**: `Heartbeat/HeartbeatManager.swift`

**補足**: `stop()` が呼ばれずにインスタンスが解放された場合、Task は停止するが明示的な文書化がない

**対応**: deinit コメントまたは明示的なドキュメントを追加

### INFO: emit() の戻り値無視

**場所**: `Router/GossipSubRouter.swift:896`

```swift
_ = state.continuation?.yield(event)  // 戻り値を無視
```

**補足**: シャットダウン中にストリームが閉じている場合は正常。設計上の意図として文書化すべき

### INFO: 双方向イベント発火

**場所**: `Router/GossipSubRouter.swift:764, 770`

**補足**: `peerJoinedMesh` と `grafted` が同じアクションで両方発火される。異なる監視目的のための設計決定

**対応**: コメントで設計意図を明確化
