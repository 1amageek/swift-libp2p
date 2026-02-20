# Mplex 実装

## 概要

Mplex (`/mplex/6.7.0`) は libp2p のストリーム多重化プロトコル。
Yamux と異なり、フロー制御がなく、varint ベースのフレーミングを使用する。

## フレーム形式

```
[header: varint] [length: varint] [data: bytes]

header = (streamID << 3) | flag

flag:
  0 = NewStream       - 新規ストリーム開始
  1 = MessageReceiver - データ (受信側視点)
  2 = MessageInitiator- データ (送信側視点)
  3 = CloseReceiver   - 半閉鎖 (受信側視点)
  4 = CloseInitiator  - 半閉鎖 (送信側視点)
  5 = ResetReceiver   - リセット (受信側視点)
  6 = ResetInitiator  - リセット (送信側視点)
```

## Yamux との主な違い

| 機能 | Mplex | Yamux |
|------|-------|-------|
| ヘッダー形式 | varint | 12バイト固定 |
| フロー制御 | なし | ウィンドウベース |
| KeepAlive | なし | Ping/Pong |
| 視点表現 | Initiator/Receiver | なし |

## Stream ID ルール

Yamux と同じ:
- **Initiator**: 奇数 ID (1, 3, 5, ...)
- **Responder**: 偶数 ID (2, 4, 6, ...)

## ファイル構成

- `MplexFrame.swift` - フレームエンコード/デコード
- `MplexStream.swift` - ストリーム状態管理
- `MplexConnection.swift` - 接続管理 + readLoop
- `MplexMuxer.swift` - Muxer プロトコル実装

## 設計原則

1. **Mutex<State> パターン**: Yamux と同様に高頻度操作用
2. **actor FrameWriter**: 書き込みシリアライズ
3. **EventEmitting 不要**: 内部実装のため

## テストカバレッジ

84テスト / 5スイート:
- `MplexFrameTests` (15) — フレームエンコード/デコード
- `MplexMuxerTests` (5) — Muxer プロトコル準拠
- `MplexConnectionTests` (32) — 接続管理、ストリーム生成、close 伝播、並行性
- `MplexStreamTests` (26) — ストリーム状態、半閉鎖、バッファ、リセット
- `MplexConcurrencyTests` (6) — 並行読書、ストリーム独立性

## Known Issues

### LOW: FrameWriter 命名の不一致

**場所**: `MplexConnection.swift:11`

```swift
private actor MplexFrameWriter  // Mplex 固有名
// Yamux は汎用名: private actor FrameWriter
```

**対応**: 一貫性のため汎用名に変更を検討

### INFO: best-effort cleanup

**場所**: `MplexConnection.swift`, `MplexStream.swift`

**現状**: シャットダウン時や拒否応答時の `sendFrame` / `stream.close()` は
`do-catch` で明示処理し、失敗理由を debug ログに記録する。

<!-- CONTEXT_EVAL_START -->
## 実装評価 (2026-02-16)

- 総合評価: **A** (100/100)
- 対象ターゲット: `P2PMuxMplex`
- 実装読解範囲: 4 Swift files / 1084 LOC
- テスト範囲: 6 files / 84 cases / targets 2
- 公開API: types 7 / funcs 10
- 参照網羅率: type 0.86 / func 1.0
- 未参照公開型: 1 件（例: `MplexFlag`）
- 実装リスク指標: try?=0, forceUnwrap=0, forceCast=0, @unchecked Sendable=0, EventLoopFuture=0, DispatchQueue=0
- 評価所見: 重大な静的リスクは検出されず

### 重点アクション
- [x] Connection/Stream レベルのテスト追加（32+26+6テスト追加済み）
- 未参照の公開型に対する直接テスト（生成・失敗系・境界値）を追加する。

※ 参照網羅率は「テストコード内での公開API名参照」を基準にした静的評価であり、動的実行結果そのものではありません。

<!-- CONTEXT_EVAL_END -->
