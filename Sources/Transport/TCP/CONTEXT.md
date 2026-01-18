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
| `TCPListener` | ✅ 完了 | Listener実装 - OSAllocatedUnfairLock使用 |

## 内部コンポーネント

| コンポーネント | 責務 |
|-------------|------|
| `TCPReadHandler` | ChannelInboundHandler - チャネル読み込みハンドリング |
| `TCPAcceptHandler` | ChannelInboundHandler - 接続受け入れハンドリング |

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
- `TCPListener` は `OSAllocatedUnfairLock` を使用（NIOハンドラは `@unchecked Sendable`）

## Wire Protocol
- 標準TCP（libp2p固有のフレーミングなし）
- Security/Mux層でプロトコルネゴシエーション

## 注意点
- EventLoopGroupのライフサイクル管理
- 接続タイムアウトの適切な設定
- バックプレッシャー処理

## Codex Review (2026-01-18)

### Warning
| Issue | Location | Description |
|-------|----------|-------------|
| Concurrent read deadlock | `TCPConnection.swift:37-51` | `read()` overwrites `readContinuation` without checking if one is already waiting; earlier callers can hang forever |
| Concurrent accept deadlock | `TCPListener.swift:61-74` | `accept()` overwrites `acceptContinuation` without guarding; earlier acceptors may hang |
| Buffered data loss on close | `TCPConnection.swift:37-47,90-98` | `channelInactive()` sets `isClosed=true`; subsequent `read()` throws even if `readBuffer` has data |
| Unbounded inbound buffering | `TCPConnection.swift:9-11`, `TCPListener.swift:37-44` | Memory/DoS risk: accumulates all inbound bytes with `autoRead=true` and no backpressure |

### Info
| Issue | Location | Description |
|-------|----------|-------------|
| Pending connections leak | `TCPListener.swift:79-88,91-98` | `close()` doesn't close pending accepted-but-unhandled connections |
| No local isClosed check in write | `TCPConnection.swift:56-60` | Relies on NIO to throw; consider early reject for clearer errors |
| Port 0 fallback | `TCPConnection.swift:143-154` | `toMultiaddr()` falls back to port 0 if nil; can produce invalid multiaddr |
