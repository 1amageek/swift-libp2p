# Transport Layer

## 概要
ネットワークトランスポート層のプロトコル定義と実装を含むグループ。

## ディレクトリ構造
```
Transport/
├── P2PTransport/     # Protocol定義のみ（NIO依存なし）
├── TCP/              # P2PTransportTCP（SwiftNIO使用）
├── Memory/           # P2PTransportMemory（テスト用）
├── QUIC/             # P2PTransportQUIC（swift-quic使用）
├── WebRTC/           # P2PTransportWebRTC（swift-webrtc使用）
└── WebSocket/        # P2PTransportWebSocket（NIOWebSocket使用）
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
| `P2PTransportQUIC` | swift-quic使用のQUIC実装 | P2PTransport, P2PMux, QUIC |
| `P2PTransportWebRTC` | swift-webrtc使用のWebRTC Direct実装 | P2PTransport, P2PMux, WebRTC |
| `P2PTransportWebSocket` | NIOWebSocket使用のWebSocket実装 | P2PTransport, NIO, NIOHTTP1, NIOWebSocket |
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
| TCPTransport | ✅ 実装済み | SwiftNIOベースのTCP実装 |
| MemoryTransport | ✅ 実装済み | テスト用インメモリ実装 |
| RelayTransport | ✅ 実装済み | Circuit Relay v2ラッパー |
| QUICTransport | ✅ 実装済み | swift-quic使用（TLS 1.3 + libp2p証明書） |
| WebRTCTransport | ✅ 実装済み | swift-webrtc使用（DTLS 1.2 + SCTP）、25テスト |
| WebSocketTransport | ✅ 実装済み | NIOWebSocket使用（HTTP/1.1 Upgrade）、40テスト |

## 実装ガイドライン
- `RawConnection`を返す（SecuredConnectionはSecurity層で処理）
- アドレス解析はMultiaddrを使用
- エラーは`TransportError`を使用

## エラー型階層

```
TransportError (P2PTransport) — 全 Transport の公開 API 統一エラー型
├── unsupportedAddress(Multiaddr)
├── connectionFailed(underlying: any Error)
├── listenerClosed
├── timeout
├── unsupportedOperation(String)
├── connectionClosed
└── addressInUse(Multiaddr)

MemoryHubDetailError (P2PTransportMemory internal)
└── noListener(Multiaddr)  — connectionFailed の underlying として使用

WebSocketDetailError (P2PTransportWebSocket internal)
├── upgradeFailed           — connectionFailed の underlying として使用
└── tlsConfigurationFailed  — connectionFailed の underlying として使用
```

### connectionFailed の underlying 型に関する設計判断 (2026-02-16)

`connectionFailed(underlying:)` の型を `any Error` から `any Error & Sendable` に変更する案を検討し、**却下**した。

**検討理由**: `TransportError` は `Sendable` だが、`any Error` は `Sendable` を保証しない。型レベルの厳格化が望ましいように見えた。

**却下理由**:
1. Swift コンパイラは existential `Error` に対する Sendable 違反を現時点で検出しない（Apple 自身のコードベースが `Error` を広く使用しているため、将来も enforcement される保証がない）
2. 実効ゼロ — 実行時の挙動は変わらない
3. `catch { error }` が返す `any Error` を `any Error & Sendable` に渡せないため、到達不能コードパス用の `TransportUnderlyingError`（String ラッパー）が必要になり、不要な複雑さが増える
4. E2E テスト（Identify, Ping）が `underlying` を再帰的に unwrap して POSIX errno を検出するパターンがあり、String ラッパーに変換すると型情報が失われる

**方針**: 将来 Swift が strict concurrency で `Error` existential の Sendable enforcement を導入した場合に対処する。現時点では YAGNI。

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
- [x] **TCPTransportユニットテストの追加** - ✅ 2026-02-16 (12テスト追加: EmbeddedChannel + 統合テスト)
- [x] **RelayTransportユニットテストの追加** - ✅ 2026-01-23 (18テスト)
- [x] **TransportError型の標準化** - ✅ 2026-02-16 Memory/WebSocket を TransportError に統一（QUIC/WebRTC/WebTransport は別タスク）

### 中優先度
- [ ] **接続タイムアウトの統一** - Transport共通の設定オプション化
- [ ] **バックプレッシャー処理のドキュメント化** - 各実装での挙動を明確化
- [x] **WebSocketTransportの実装** - ✅ NIOWebSocket使用で実装完了 (2026-01-30)

### 低優先度
- [x] **QUICTransportの実装** - ✅ swift-quic使用で実装完了
- [x] **WebRTCTransportの実装** - ✅ swift-webrtc使用で実装完了 (2026-01-30)
- [ ] **レイテンシシミュレーション** - MemoryTransportへの追加（テスト用）

## テスト実装状況

| テスト | ステータス | 説明 |
|-------|----------|------|
| MemoryTransportTests | ✅ 実装済み | 基本接続、双方向通信、複数接続 |
| TransportTests | ⚠️ プレースホルダー | 1テストのみ |
| TCPTransportTests | ✅ 実装済み | 接続、リッスン、双方向通信、overflow、冪等close、EmbeddedChannel (37テスト) |
| RelayTransportTests | ✅ 実装済み | アドレス解析、RelayListener、RawConnection (18テスト) |
| QUICTransportTests | ✅ 実装済み | TLS、マルチストリーム、接続管理 (55テスト) |
| WebRTCTransportTests | ✅ 実装済み | アドレス、接続、E2E (25テスト) |
| WebSocketTransportTests | ✅ 実装済み | 接続、通信、close挙動、アドレス、ping/pong、masking、overflow (40テスト) |

**推奨**: QUIC/WebRTC/WebTransport の TransportError 標準化（TLS/DTLS 固有のエラー体系が複雑なため別タスク）

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

<!-- CONTEXT_EVAL_START -->
## 実装評価 (2026-02-16)

- 総合評価: **A** (86/100)
- 対象ターゲット: `P2PTransport`, `P2PTransportMemory`, `P2PTransportQUIC`, `P2PTransportTCP`, `P2PTransportWebRTC`, `P2PTransportWebSocket`, `P2PTransportWebTransport`
- 実装読解範囲: 44 Swift files / 7921 LOC
- テスト範囲: 73 files / 801 cases / targets 12
- 公開API: types 59 / funcs 44
- 参照網羅率: type 0.63 / func 0.7
- 未参照公開型: 22 件（例: `CertificateMaterial`, `DeterministicCertificate`, `FailingTLSProvider`, `MemoryListener`, `QUICListener`）
- 実装リスク指標: try?=0, forceUnwrap=0, forceCast=0, @unchecked Sendable=0, EventLoopFuture=5, DispatchQueue=0
- 評価所見: EventLoopFutureブリッジ実装を含む

### 重点アクション
- 未参照の公開型に対する直接テスト（生成・失敗系・境界値）を追加する。
- EventLoopFuture→async/await変換経路の失敗ケースを追加で検証する。

※ 参照網羅率は「テストコード内での公開API名参照」を基準にした静的評価であり、動的実行結果そのものではありません。

<!-- CONTEXT_EVAL_END -->
