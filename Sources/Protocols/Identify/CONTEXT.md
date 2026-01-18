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
private let peerInfoCache: Mutex<[PeerID: IdentifyInfo]>

// キャッシュAPI
func getCachedInfo(for peer: PeerID) -> IdentifyInfo?
func clearCache()
func allCachedPeers() -> [PeerID]
```

### signedPeerRecordの制限
- フィールド8（signedPeerRecord）はエンコードされるが検証は未実装
- 将来的に署名付きピアレコード検証を追加予定

## テスト

```
Tests/Protocols/IdentifyTests/
├── IdentifyProtobufTests.swift   # Encode/decode
├── IdentifyServiceTests.swift    # サービステスト
└── IdentifyInteropTests.swift    # Go/Rust相互運用
```

### 実装状況
| ファイル | ステータス | 説明 |
|---------|----------|------|
| IdentifyProtobufTests | ✅ 実装済み | エンコード/デコードテスト |
| IdentifyServiceTests | ✅ 実装済み | 基本サービステスト |
| IdentifyInteropTests | ⏳ 計画中 | Go/Rust相互運用（未実装）|

## 品質向上TODO

### 高優先度
- [ ] **signedPeerRecord検証の実装** - フィールド8は存在するが署名検証なし
- [ ] **IdentifyServiceテストの追加** - キャッシュ動作、Push/Query両方向テスト
- [ ] **Protobufラウンドトリップテスト** - 全フィールドのエンコード/デコード検証

### 中優先度
- [ ] **キャッシュTTL/サイズ制限** - 現在は無制限、メモリリーク防止
- [ ] **observedAddr検証** - 観察アドレスの妥当性チェック
- [ ] **Identify Push自動送信** - アドレス変更時の自動プッシュ

### 低優先度
- [ ] **Delta更新対応** - 差分のみの情報交換（帯域節約）
- [ ] **protocolVersion/agentVersionパース** - バージョン比較ユーティリティ

## Codex Review (2026-01-18)

### Warning
| Issue | Location | Description |
|-------|----------|-------------|
| readAll silently truncates | `IdentifyService.swift:306-324` | Reads truncated at 64KB with no error; large messages silently incomplete |
