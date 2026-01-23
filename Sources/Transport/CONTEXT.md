# Transport Layer

## 概要
ネットワークトランスポート層のプロトコル定義と実装を含むグループ。

## ディレクトリ構造
```
Transport/
├── P2PTransport/     # Protocol定義のみ（NIO依存なし）
├── TCP/              # P2PTransportTCP（SwiftNIO使用）
├── Memory/           # P2PTransportMemory（テスト用）
└── QUIC/             # P2PTransportQUIC（将来実装）
```

## 設計原則
- **Protocol定義と実装の分離**: P2PTransportはprotocolのみ、実装は別ターゲット
- **依存関係の最小化**: P2PTransportはP2PCoreのみに依存（NIO依存なし）
- **テスト容易性**: MemoryTransportでユニットテストを高速化

## サブモジュール

| ターゲット | 責務 | 依存関係 |
|-----------|------|----------|
| `P2PTransport` | Transport/Listenerプロトコル定義 | P2PCore |
| `P2PTransportTCP` | SwiftNIOを使用したTCP実装 | P2PTransport, NIO |
| `P2PTransportMemory` | テスト用インメモリ実装 | P2PTransport |

## 主要なプロトコル

```swift
public protocol Transport: Sendable {
    var protocols: [[String]] { get }
    func dial(_ address: Multiaddr) async throws -> any RawConnection
    func listen(_ address: Multiaddr) async throws -> any Listener
    func canDial(_ address: Multiaddr) -> Bool
    func canListen(_ address: Multiaddr) -> Bool  // NEW: リッスン可能か確認
}

public protocol Listener: Sendable {
    var localAddress: Multiaddr { get }
    func accept() async throws -> any RawConnection
    func close() async throws
}
```

## 実装ステータス

| 実装 | ステータス | 説明 |
|-----|----------|------|
| TCPTransport | ✅ 完了 | SwiftNIOベースのTCP実装 |
| MemoryTransport | ✅ 完了 | テスト用インメモリ実装 |
| RelayTransport | ✅ 完了 | Circuit Relay v2ラッパー |
| QUICTransport | ✅ 完了 | swift-quic使用（TLS 1.3 + libp2p証明書） |

## 実装ガイドライン
- `RawConnection`を返す（SecuredConnectionはSecurity層で処理）
- アドレス解析はMultiaddrを使用
- エラーは`TransportError`を使用

## エラー型階層

```
TransportError (P2PTransport)
├── unsupportedAddress(Multiaddr)
├── connectionFailed(underlying: Error)
├── listenerClosed
└── timeout

MemoryHubError (P2PTransportMemory内部)
├── invalidAddress
├── noListener
└── addressInUse

MemoryListenerError (P2PTransportMemory内部)
└── concurrentAcceptNotSupported

MemoryConnection.ConnectionError
├── closed
└── concurrentReadNotSupported
```

## シングルリーダー/アクセプター制約

### MemoryConnection
- **シングルリーダー**: 同時に1つの`read()`呼び出しのみ許可
- 同時読み取りはエラーまたはハングの可能性
- 決定論的なテスト動作を保証するための設計

### MemoryListener
- **シングルアクセプター**: 同時`accept()`は明示的にエラー
- エラー: `concurrentAcceptNotSupported`

### TCPConnection/TCPListener
- **並行read/accept対応**: waiters配列でFIFOキュー実装、複数の同時呼び出しを安全に処理
- **バッファサイズ制限**: `tcpMaxReadBufferSize` (1MB) でDoS対策
- **close時のバッファ優先**: read()はisClosed前にバッファをチェック、データ消失を防止
- **リソースクリーンアップ**: close()で全waitersと pending connections を適切に処理

## バックプレッシャー処理

- **TCPConnection**: NIOのwriteAndFlush()が暗黙的なバックプレッシャー提供
- **MemoryConnection**: 無制限バッファリング（テスト専用、大規模データには不適切）

## 品質向上TODO

### 高優先度
- [ ] **TCPTransportユニットテストの追加** - 現在統合テストのみ
- [x] **RelayTransportユニットテストの追加** - ✅ 2026-01-23 (18テスト)
- [ ] **TransportError型の標準化** - 各実装で異なるエラー型が混在

### 中優先度
- [ ] **接続タイムアウトの統一** - Transport共通の設定オプション化
- [ ] **バックプレッシャー処理のドキュメント化** - 各実装での挙動を明確化
- [ ] **WebSocketTransportの実装** - ブラウザ互換性向上

### 低優先度
- [x] **QUICTransportの実装** - ✅ swift-quic使用で実装完了
- [ ] **レイテンシシミュレーション** - MemoryTransportへの追加（テスト用）

## テスト実装状況

| テスト | ステータス | 説明 |
|-------|----------|------|
| MemoryTransportTests | ✅ 実装済み | 基本接続、双方向通信、複数接続 |
| TransportTests | ⚠️ プレースホルダー | 1テストのみ |
| TCPTransportTests | ✅ 実装済み | 接続、リッスン、双方向通信 |
| RelayTransportTests | ✅ 実装済み | アドレス解析、RelayListener、RawConnection (18テスト) |
| QUICTransportTests | ✅ 実装済み | TLS、マルチストリーム、接続管理 (55テスト) |

**推奨**: TCPTransportのエラーハンドリングテスト追加

## Codex Review (2026-01-18) - UPDATED 2026-01-23

### TCP Transport Issues

| Issue | Location | Status | Description |
|-------|----------|--------|-------------|
| ~~Concurrent read deadlock~~ | `TCPConnection.swift:19,67-96` | ✅ Fixed | `readWaiters` array provides FIFO queue for concurrent reads |
| ~~Concurrent accept deadlock~~ | `TCPListener.swift:21,71-112` | ✅ Fixed | `acceptWaiters` array provides FIFO queue for concurrent accepts |
| ~~Buffered data loss on close~~ | `TCPConnection.swift:72-80` | ✅ Fixed | `read()` checks buffer before `isClosed`, returns data even after close |
| ~~Unbounded inbound buffering~~ | `TCPConnection.swift:13,155-157` | ✅ Fixed | `tcpMaxReadBufferSize` (1MB) limit, drops data when full |
| ~~Pending connections leak~~ | `TCPListener.swift:130-133` | ✅ Fixed | `close()` closes all pending connections |
| ~~No isClosed check in write~~ | `TCPConnection.swift:98-104` | ✅ Fixed | Early `isClosed` check added for clearer error messages |

### Info (Design Decisions)
| Issue | Location | Description |
|-------|----------|-------------|
| Port 0 fallback | `TCPReadHandler.channelActive` | Falls back to port 0 if remote address is nil; acceptable for edge cases |
| Empty Data EOF | `MemoryChannel.swift` | Empty `Data()` as EOF sentinel; documented behavior |
