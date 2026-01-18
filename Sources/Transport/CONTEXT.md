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
| QUICTransport | ⏳ 計画中 | QUIC実装（将来）|

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
- NIOの特性上、複数リーダーは可能だが推奨しない
- MemoryTransportとの動作差異に注意

## バックプレッシャー処理

- **TCPConnection**: NIOのwriteAndFlush()が暗黙的なバックプレッシャー提供
- **MemoryConnection**: 無制限バッファリング（テスト専用、大規模データには不適切）

## 品質向上TODO

### 高優先度
- [ ] **TCPTransportユニットテストの追加** - 現在統合テストのみ
- [ ] **RelayTransportユニットテストの追加** - 現在統合テストのみ
- [ ] **TransportError型の標準化** - 各実装で異なるエラー型が混在

### 中優先度
- [ ] **接続タイムアウトの統一** - Transport共通の設定オプション化
- [ ] **バックプレッシャー処理のドキュメント化** - 各実装での挙動を明確化
- [ ] **WebSocketTransportの実装** - ブラウザ互換性向上

### 低優先度
- [ ] **QUICTransportの実装** - 計画中だが未着手
- [ ] **レイテンシシミュレーション** - MemoryTransportへの追加（テスト用）

## テスト実装状況

| テスト | ステータス | 説明 |
|-------|----------|------|
| MemoryTransportTests | ✅ 実装済み | 基本接続、双方向通信、複数接続（`Tests/Transport/P2PTransportTests/MemoryTransportTests.swift`） |
| TransportTests | ⚠️ プレースホルダー | 1テストのみ |
| TCPTransportTests | ❌ なし | 統合テスト依存 |

**推奨**: TCPTransport専用のユニットテスト追加
