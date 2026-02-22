# P2PIdentify

## 概要
libp2p Identifyプロトコルの実装。

## 責務
- Peer情報の交換（公開鍵、プロトコル、アドレス）
- 接続時の自動識別
- 情報更新のプッシュ通知

## Protocol IDs
- `/ipfs/id/1.0.0` - Identify (query)
- `/ipfs/id/push/1.0.0` - Identify Push (broadcast)

## 依存関係
- `P2PCore` (PeerID, PublicKey, Multiaddr, Envelope)
- `P2PMux` (MuxedStream)
- `P2PProtocols` (ProtocolService)

---

## ファイル構成

```
Sources/Protocols/Identify/
├── IdentifyService.swift     # メインサービス実装
├── IdentifyInfo.swift        # 交換データ構造
├── IdentifyProtobuf.swift    # Wire format encode/decode
├── IdentifyError.swift       # エラー定義
└── CONTEXT.md
```

## 主要な型

| 型名 | 説明 |
|-----|------|
| `IdentifyService` | プロトコルサービス実装 |
| `IdentifyInfo` | Peer情報構造体 |
| `IdentifyConfiguration` | サービス設定 |
| `IdentifyEvent` | イベント通知 |
| `IdentifyError` | エラー型 |

---

## Wire Protocol

### Protobuf Message

```protobuf
message Identify {
  optional bytes publicKey = 1;
  repeated bytes listenAddrs = 2;
  repeated string protocols = 3;
  optional bytes observedAddr = 4;
  optional string protocolVersion = 5;
  optional string agentVersion = 6;
  optional bytes signedPeerRecord = 8;  // field 7 is skipped
}
```

### Message Flow

**Identify (query):**
```
Initiator              Responder
    |---- stream open ---->|
    |<--- Identify msg ----|
    |---- stream close --->|
```

**Identify Push:**
```
Sender                 Receiver
    |---- stream open ---->|
    |---- Identify msg --->|
    |---- stream close --->|
```

---

## API

### Handler登録

```swift
let identifyService = IdentifyService(configuration: .init(
    agentVersion: "my-app/1.0.0"
))

await identifyService.registerHandlers(
    node: node,
    localKeyPair: keyPair,
    getListenAddresses: { await node.configuration.listenAddresses },
    getSupportedProtocols: { await node.supportedProtocols }
)
```

### Peer識別

```swift
let info = try await identifyService.identify(remotePeer, using: node)
print("Agent: \(info.agentVersion)")
print("Protocols: \(info.protocols)")
```

### Push送信

```swift
try await identifyService.push(
    to: remotePeer,
    using: node,
    localKeyPair: keyPair,
    listenAddresses: addresses,
    supportedProtocols: protocols
)
```

---

## 実装詳細

### キャッシュ管理
`IdentifyService`は識別済みピア情報をキャッシュ:

```swift
// 設定
IdentifyConfiguration(
    cacheTTL: .seconds(24 * 60 * 60),  // デフォルト24時間
    maxCacheSize: 1000,                 // デフォルト1000エントリ
    cleanupInterval: .seconds(300)      // デフォルト5分（nil で無効化）
)

// キャッシュAPI
func cachedInfo(for peer: PeerID) -> IdentifyInfo?  // 期限切れは nil を返す
var allCachedInfo: [PeerID: IdentifyInfo]           // 期限切れをフィルタ
func clearCache(for peer: PeerID)
func clearAllCache()
func cleanup() -> Int                                // 手動クリーンアップ

// メンテナンスAPI
func startMaintenance()  // バックグラウンドクリーンアップ開始
func stopMaintenance()   // 停止
func shutdown() async    // stopMaintenance() + イベントストリーム終了
```

**削除戦略**:
1. 期限切れエントリ優先
2. LRU（最古アクセス）

**注意**: `startMaintenance()` を明示的に呼び出す必要あり。

### signedPeerRecord検証
- フィールド8（signedPeerRecord）の署名検証を実装 ✅ 2026-01-23
- `verifySignedPeerRecord()` で Envelope 署名を検証
- PeerID の一致を確認（record内、envelope署名者、期待値）

### イベント

```swift
public enum IdentifyEvent: Sendable {
    case received(peer: PeerID, info: IdentifyInfo)
    case sent(peer: PeerID)
    case pushReceived(peer: PeerID, info: IdentifyInfo)
    case error(peer: PeerID?, IdentifyError)
    case maintenanceCompleted(entriesRemoved: Int)
}
```

## テスト

```
Tests/Protocols/IdentifyTests/
├── IdentifyProtobufTests.swift   # Encode/decode
└── IdentifyServiceTests.swift    # サービステスト

Tests/Interop/Protocols/
└── IdentifyInteropTests.swift    # Go/Rust相互運用（QUIC）

Tests/Interop/Existing/
├── GoLibp2pInteropTests.swift   # Identifyケース含む
└── RustInteropTests.swift       # Identifyケース含む
```

### 実装状況
| ファイル | ステータス | 説明 |
|---------|----------|------|
| IdentifyProtobufTests | ✅ 実装済み | エンコード/デコードテスト |
| IdentifyServiceTests | ✅ 実装済み | 基本サービステスト |
| IdentifyInteropTests | ✅ 実装済み | Go/Rust相互運用（identify応答デコード） |

## 品質向上TODO

### 高優先度
- [x] **signedPeerRecord検証の実装** - `verifySignedPeerRecord()` で署名とPeerID検証 ✅ 2026-01-23
- [x] **キャッシュTTL/サイズ制限** - TTL ベース有効期限 + LRU 削除 + バックグラウンドメンテナンス ✅ 2026-01-23
- [x] **IdentifyServiceテストの追加** - キャッシュ TTL/LRU/メンテナンステスト追加 ✅ 2026-01-23
- [ ] **Protobufラウンドトリップテスト** - 全フィールドのエンコード/デコード検証

### 中優先度
- [ ] **observedAddr検証** - 観察アドレスの妥当性チェック
- [x] **Identify Push自動送信** - IdentifyService側実装済み + Node統合完了（NodeConfiguration.identifyService で自動登録・peer lifecycle通知） ✅

### 低優先度
- [ ] **Delta更新対応** - 差分のみの情報交換（帯域節約）
- [ ] **protocolVersion/agentVersionパース** - バージョン比較ユーティリティ

## Codex Review (2026-01-18) - UPDATED 2026-01-23

### Warning
| Issue | Location | Status | Description |
|-------|----------|--------|-------------|
| ~~readAll silently truncates~~ | `IdentifyService.swift:384-398` | ✅ Fixed | Now throws `messageTooLarge` error when exceeding 64KB limit |

<!-- CONTEXT_EVAL_START -->
## 実装評価 (2026-02-16)

- 総合評価: **A** (100/100)
- 対象ターゲット: `P2PIdentify`
- 実装読解範囲: 4 Swift files / 1117 LOC
- テスト範囲: 25 files / 107 cases / targets 2
- 公開API: types 5 / funcs 13
- 参照網羅率: type 1.0 / func 0.69
- 未参照公開型: 0 件（例: `なし`）
- 実装リスク指標: try?=0, forceUnwrap=0, forceCast=0, @unchecked Sendable=0, EventLoopFuture=0, DispatchQueue=0
- 評価所見: 重大な静的リスクは検出されず

### 重点アクション
- 現行のテスト網羅を維持し、機能追加時は同一粒度でテストを増やす。

※ 参照網羅率は「テストコード内での公開API名参照」を基準にした静的評価であり、動的実行結果そのものではありません。

<!-- CONTEXT_EVAL_END -->
