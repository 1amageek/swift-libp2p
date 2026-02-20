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
| V1 Lazy (0-RTT) | ✅ 実装済み | 先頭プロトコルとヘッダーを同時送信。拒否時は残り候補へフォールバック |

## 既知の制限事項

### V1Lazy
- ✅ `negotiateLazy()` を実装済み
- 先頭候補が受理される場合は 1 RTT で合意
- 先頭候補が `na` の場合は残り候補へ通常フォールバック

### バッファリング
- ✅ `readNextMessage()` が断片化/同時受信（coalesced）を内部で吸収
- `NegotiationResult.remainder` で先読み余剰データを返却

### NegotiationResult.remainder
- ネゴシエーションで先読みした余剰データを保持する
- `Integration/P2P/P2P.swift` では `BufferedMuxedStream` に渡して、上位プロトコルへ確実に受け渡す

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
- [x] **V1Lazy実装** - 0-RTT最適化で単一プロトコルのレイテンシ削減 ✅
- [x] **NegotiationResult.remainder活用** - `P2P.newStream` / inbound handler で余剰データを `BufferedMuxedStream` 経由で継承
- [x] **同時ヘッダー送信最適化** - 初回RTT削減 ✅

### 低優先度
- [ ] **プロトコルキャッシング** - 既知ピアのプロトコル記憶

## 参照
- [multistream-select Spec](https://github.com/multiformats/multistream-select)

## Codex Review (2026-01-18, Updated 2026-02-14)

### Warning
| Issue | Location | Status | Description |
|-------|----------|--------|-------------|
| ls response format interop | `P2PNegotiation.swift` | ✅ Fixed | `ls` response now uses single outer varint + newline-delimited payload (no nested per-protocol varints) |
| Trailing bytes discarded | `P2PNegotiation.swift` | ✅ Fixed | Decode API returns consumed length and call sites preserve `remainder` for coalesced reads |
| Invalid UTF-8 accepted | `P2PNegotiation.swift` | ✅ Fixed | Decoder uses strict `String(data:encoding:)` and rejects invalid UTF-8 |
| Unbounded message length | `P2PNegotiation.swift` | ✅ Fixed | `maxMessageSize` upper bound and `Int.max` guard added before allocation/use |

### Info
| Issue | Location | Status | Description |
|-------|----------|--------|-------------|
| Linear contains check | `P2PNegotiation.swift` | ✅ Fixed | `handle()` now uses `Set(supported)` for protocol lookup |
| Full-message read assumption | `P2PNegotiation.swift` | ✅ Fixed | Negotiation now accumulates fragments via buffered `readNextMessage()` and handles partial reads safely |

<!-- CONTEXT_EVAL_START -->
## 実装評価 (2026-02-16)

- 総合評価: **A** (100/100)
- 対象ターゲット: `P2PNegotiation`
- 実装読解範囲: 1 Swift files / 321 LOC
- テスト範囲: 2 files / 46 cases / targets 1
- 公開API: types 3 / funcs 0
- 参照網羅率: type 1.0 / func 1.0
- 未参照公開型: 0 件（例: `なし`）
- 実装リスク指標: try?=0, forceUnwrap=0, forceCast=0, @unchecked Sendable=0, EventLoopFuture=0, DispatchQueue=0
- 評価所見: 重大な静的リスクは検出されず

### 重点アクション
- 現行のテスト網羅を維持し、機能追加時は同一粒度でテストを増やす。

※ 参照網羅率は「テストコード内での公開API名参照」を基準にした静的評価であり、動的実行結果そのものではありません。

<!-- CONTEXT_EVAL_END -->
