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

## Known Issues

### MEDIUM: テストカバレッジ不足

`MplexFrameTests` のみ存在。Connection/Stream レベルのテストが欠如。

**Yamux との比較**:
- Yamux: `YamuxFrameTests`, `YamuxConnectionTests`, `YamuxStreamTests`
- Mplex: `MplexFrameTests` のみ

**対応**: `MplexConnectionTests`, `MplexStreamTests` を追加

### LOW: FrameWriter 命名の不一致

**場所**: `MplexConnection.swift:11`

```swift
private actor MplexFrameWriter  // Mplex 固有名
// Yamux は汎用名: private actor FrameWriter
```

**対応**: 一貫性のため汎用名に変更を検討

### INFO: shutdown での try? 使用

**場所**: `MplexConnection.swift:306, 339, 344, 373, 387, 448`

```swift
try? await sendFrame(rstFrame)  // シャットダウン時は許容
```

**補足**: シャットダウン中のエラーは無視して良いケース。CLAUDE.md のガイドラインとは異なるが、このコンテキストでは適切。
