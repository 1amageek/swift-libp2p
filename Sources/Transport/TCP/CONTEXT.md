# P2PTransportTCP

## 概要
SwiftNIOを使用したTCPトランスポートの実装。

## 責務
- TCP接続の確立（dial）
- TCPリスナーの作成（listen）
- NIO ChannelをRawConnectionにラップ

## 依存関係
- `P2PTransport` (Transport protocol)
- `NIOCore` (EventLoop, Channel)
- `NIOPosix` (TCP bootstrap)

## 主要な型

| 型名 | 状態 | 説明 |
|-----|------|------|
| `TCPTransport` | ✅ 完了 | Transport実装 - ClientBootstrap使用 |
| `TCPConnection` | ✅ 完了 | RawConnection実装 - Mutex<State>ベース |
| `TCPListener` | ✅ 完了 | Listener実装 - Mutex\<ListenerState\>ベース |

## 内部コンポーネント

| コンポーネント | 責務 |
|-------------|------|
| `TCPReadHandler` | ChannelInboundHandler - チャネル読み込みハンドリング |
| `HandlerCollector` | listener 遅延バインディング時の handler 収集と callback 伝播 |

## 実装ノート

### TCPTransport
```swift
public final class TCPTransport: Transport, Sendable {
    private let group: EventLoopGroup
    private let ownsGroup: Bool

    public var protocols: [[String]] { [["ip4", "tcp"], ["ip6", "tcp"]] }

    public func dial(_ address: Multiaddr) async throws -> any RawConnection
    public func listen(_ address: Multiaddr) async throws -> any Listener
    public func canDial(_ address: Multiaddr) -> Bool
    public func canListen(_ address: Multiaddr) -> Bool
}
```

### TCPConnection
- NIO `Channel` をラップ
- 読み取りは `TCPReadHandler` でバッファリング
- `Mutex<TCPConnectionState>` で read continuation とバッファを管理
- write(): `channel.writeAndFlush`
- close(): Channel切断 + read continuation を終了

### NIO統合パターン
- **async/await を全面採用**（EventLoopFuture は使わない）
- `Channel` + `ChannelInboundHandler` で読み取りをブリッジ
- Channel状態管理が必要な場合のみ `class + mutex`
- `TCPListener` は `Mutex<ListenerState>` を使用（`HandlerCollector` / `TCPReadHandler` も `Mutex<T>` ベース）

## Wire Protocol
- 標準TCP（libp2p固有のフレーミングなし）
- Security/Mux層でプロトコルネゴシエーション

## 注意点
- EventLoopGroupのライフサイクル管理
- 接続タイムアウトの適切な設定
- バックプレッシャー処理

## Codex Review (2026-01-18, Updated 2026-02-14)

### Warning
| Issue | Location | Status | Description |
|-------|----------|--------|-------------|
| Concurrent read deadlock | `TCPConnection.swift` | ✅ Fixed | `readWaiters` queue に変更し、同時 `read()` を FIFO で処理 |
| Concurrent accept deadlock | `TCPListener.swift` | ✅ Fixed | `acceptWaiters` queue に変更し、同時 `accept()` を FIFO で処理 |
| Buffered data loss on close | `TCPConnection.swift` | ✅ Fixed | `read()` が close 判定前に `readBuffer` を返すため、close 直前の受信データを回収可能 |
| Unbounded inbound buffering | `TCPConnection.swift` | ✅ Fixed | `tcpMaxReadBufferSize` 上限を導入し、オーバーフロー時は接続を閉じて waiters を失敗復帰 |

### Info
| Issue | Location | Status | Description |
|-------|----------|--------|-------------|
| Pending connections leak | `TCPListener.swift` | ✅ Fixed | `close()` が pending 接続も順次 close してリークを防止 |
| No local isClosed check in write | `TCPConnection.swift` | ✅ Fixed | `write()` 冒頭でローカル close 状態を検査し即時エラー化 |
| Port 0 fallback | `TCPConnection.swift` | ✅ Fixed | `SocketAddress.toMultiaddr()` は port 欠落時に `nil` を返し、不正 `/tcp/0` 生成を回避 |

<!-- CONTEXT_EVAL_START -->
## 実装評価 (2026-02-16, Updated)

- 総合評価: **A-** (85/100)
- 対象ターゲット: `P2PTransportTCP`
- 実装読解範囲: 3 Swift files / 790 LOC
- テスト範囲: 37 cases (25既存 + 12追加: EmbeddedChannel 3件 + 統合テスト 9件)
- 公開API: types 3 / funcs 8
- 参照網羅率: type 1.0 / func 1.0
- 未参照公開型: 0 件（TCPConnection, TCPListener, TCPReadHandler すべてテスト参照あり）
- 実装リスク指標: try?=0, forceUnwrap=0, forceCast=0, @unchecked Sendable=0, EventLoopFuture=0, DispatchQueue=0
- 評価所見: バッファオーバーフロー、冪等close、ハンドラ単体テスト、FIFO順序等を網羅

### 重点アクション
- TransportError型の標準化（TCP固有エラーとTransportErrorの統一）

※ 参照網羅率は「テストコード内での公開API名参照」を基準にした静的評価であり、動的実行結果そのものではありません。

<!-- CONTEXT_EVAL_END -->
