# P2PNegotiation

## 概要
multistream-selectプロトコルの実装。

## 責務
- プロトコルネゴシエーション（initiator/responder）
- プロトコルリスト（ls コマンド）
- 複数プロトコルの優先順位付き選択

## 依存関係
- `P2PCore` (Varint)

## 主要な型

| 型名 | 状態 | 説明 |
|-----|------|------|
| `MultistreamSelect` | 実装済み | ネゴシエーションロジック |
| `NegotiationResult` | 実装済み | ネゴシエーション結果 |
| `NegotiationError` | 実装済み | エラー型 |

## Wire Protocol

### プロトコルID
`/multistream/1.0.0`

### メッセージフォーマット
```
+------------------+------------------+
| Length (varint)  | Message + "\n"   |
+------------------+------------------+
```

### ネゴシエーションフロー

#### 成功ケース
```
Dialer                          Listener
  |                                |
  |----> /multistream/1.0.0\n ---->|
  |<---- /multistream/1.0.0\n <----|
  |----> /noise\n ---------------->|
  |<---- /noise\n <----------------|
  |     (protocol selected)        |
```

#### 失敗ケース
```
Dialer                          Listener
  |                                |
  |----> /multistream/1.0.0\n ---->|
  |<---- /multistream/1.0.0\n <----|
  |----> /unknown\n -------------->|
  |<---- na\n <--------------------|
  |----> /noise\n ---------------->|
  |<---- /noise\n <----------------|
```

## API

### Initiator側
```swift
let result = try await MultistreamSelect.negotiate(
    protocols: ["/noise", "/plaintext/2.0.0"],
    read: { ... },
    write: { ... }
)
// result.protocolID == "/noise"
```

### Responder側
```swift
let result = try await MultistreamSelect.handle(
    supported: ["/noise", "/yamux/1.0.0"],
    read: { ... },
    write: { ... }
)
```

## エンコーディング

### encode
```swift
// "/noise" → varint(7) + "/noise\n"
MultistreamSelect.encode("/noise")
```

### decode
```swift
// varint(7) + "/noise\n" → "/noise"
MultistreamSelect.decode(data)
```

## 実装ステータス

| 機能 | ステータス | 説明 |
|------|----------|------|
| multistream-select v1 (Initiator) | ✅ 実装済み | ヘッダー交換 + プロトコル選択 |
| multistream-select v1 (Responder) | ✅ 実装済み | ヘッダー交換 + プロトコル応答 |
| ls コマンド | ✅ 実装済み | サポートプロトコル一覧 |
| V1 Lazy (0-RTT) | ❌ 未実装 | 単一プロトコル時のレイテンシ最適化 |

## 既知の制限事項

### V1Lazy未実装
- 現在の実装は標準のV1ネゴシエーションのみ
- ❌ V1Lazy（0-RTT最適化）は未実装
- 単一プロトコルのダイアラーでも2 RTT必要
- Go/Rust 実装ではダイアラーが単一プロトコルの場合、ヘッダーとプロトコル選択を同時送信してRTTを削減

### バッファリング
- 不完全な読み取りが発生する可能性あり
- 統合層（ConnectionUpgrader）でバッファリングを処理
- 呼び出し側は部分的な読み取りに備える必要あり

### NegotiationResult.remainder
- `remainder`フィールドは現在常に`Data()`
- 将来的にネゴシエーション後の余剰データを返す可能性

## 注意点
- プロトコルIDは大文字小文字を区別
- 改行文字 `\n` は必須
- `na` は "not available" の略
- `ls` でサポートプロトコル一覧を取得可能
- タイムアウト処理はトランスポート層で行う

## テスト実装状況

| カテゴリ | テスト数 | ステータス |
|---------|---------|----------|
| エンコード/デコード | 6 | ✅ 完了 |
| Initiatorネゴシエーション | 5 | ✅ 完了 |
| Responderネゴシエーション | 2 | ✅ 完了 |
| lsコマンド | 3 | ✅ 完了 |
| 定数 | 1 | ✅ 完了 |
| NegotiationResult | 2 | ✅ 完了 |
| NegotiationError | 1 | ✅ 完了 |
| **合計** | **20** | ✅ 全テスト通過 |

## 品質向上TODO

### 高優先度
- [x] **テストの実装** - 完了: 20の包括的なテスト
  - ✅ エンコード/デコードラウンドトリップテスト
  - ✅ Initiator/Responderネゴシエーションテスト
  - ✅ エラーハンドリングテスト
  - ✅ `ls`コマンドテスト
- [ ] **Go/Rust相互運用テスト** - 実際のlibp2pノードとの接続テスト

### 中優先度
- [ ] **V1Lazy実装** - 0-RTT最適化で単一プロトコルのレイテンシ削減
- [ ] **NegotiationResult.remainder活用** - 余剰データの適切な受け渡し
- [ ] **同時ヘッダー送信最適化** - 初回RTT削減

### 低優先度
- [ ] **プロトコルキャッシング** - 既知ピアのプロトコル記憶

## 参照
- [multistream-select Spec](https://github.com/multiformats/multistream-select)

## Codex Review (2026-01-18)

### Warning
| Issue | Location | Description |
|-------|----------|-------------|
| ls response format interop | `P2PNegotiation.swift:100-110` | Per-protocol varints in ls response may break go/rust interop; spec expects newline-delimited list with single outer length |
| Trailing bytes discarded | `P2PNegotiation.swift:130-145` | `decode()` discards trailing bytes after first message; coalesced reads can desync |
| Invalid UTF-8 accepted | `P2PNegotiation.swift:135-136` | `String(decoding:as:)` replaces invalid UTF-8 instead of failing; use `String(data:encoding:)` |
| Unbounded message length | `P2PNegotiation.swift:131-136` | No upper bound on decoded message length; DoS risk from huge varint |

### Info
| Issue | Location | Description |
|-------|----------|-------------|
| Linear contains check | `P2PNegotiation.swift:97` | `supported.contains` is O(n); Set would be better for large lists |
| Full-message read assumption | `P2PNegotiation.swift:36-65,79-114` | Assumes full-message reads; partial reads throw invalidMessage |
