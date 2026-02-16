# P2PTransportMemory

## 概要
テスト用のインメモリトランスポート実装。

## 責務
- ネットワークなしで接続をシミュレート
- ユニットテストの高速化
- 決定論的なテスト環境の提供

## 依存関係
- `P2PTransport` (Transport protocol)

## 主要な型

| 型名 | 状態 | 説明 |
|-----|------|------|
| `MemoryTransport` | ✅ 完了 | Transport実装 |
| `MemoryConnection` | ✅ 完了 | RawConnection実装 |
| `MemoryListener` | ✅ 完了 | Listener実装 |
| `MemoryHub` | ✅ 完了 | 接続ルーティング層（リスナー登録管理） |
| `MemoryChannel` | ✅ 完了 | 双方向データチャネル |

## MemoryHub - 接続ルーティング

### 責務
- リスナー登録管理
- ダイアル要求のリスナーへのルーティング
- 接続ペアの生成

### API
```swift
public func register(listener: MemoryListener, at address: Multiaddr) throws
public func unregister(address: Multiaddr)
public func connect(to address: Multiaddr) throws -> MemoryConnection
public func reset()
public var listenerCount: Int { get }
```

### Shared vs Isolated
```swift
// Shared hub (デフォルト、単純なテスト向け)
let transport1 = MemoryTransport()  // MemoryHub.shared を使用
let transport2 = MemoryTransport()

// Isolated hub (テスト分離向け)
let hub = MemoryHub()
let transport1 = MemoryTransport(hub: hub)
let transport2 = MemoryTransport(hub: hub)
hub.reset()  // テスト後のクリーンアップ
```

## エラーハンドリング

全公開 API は `TransportError` を投げる（Transport 層統一エラー型）。

| 場面 | TransportError case |
|------|-------------------|
| 無効なメモリアドレス | `.unsupportedAddress(addr)` |
| リスナー未登録 | `.connectionFailed(underlying: MemoryHubDetailError.noListener(addr))` |
| アドレス重複 | `.addressInUse(addr)` |
| リスナー閉鎖 | `.listenerClosed` |
| 接続閉鎖後の read/write | `.connectionClosed` |
| 同時 accept | `.unsupportedOperation("concurrent accept not supported")` |
| 同時 read | `.unsupportedOperation("concurrent read not supported")` |

`MemoryHubDetailError` は internal エラー型で、`connectionFailed` の underlying に詳細を保持する。

## 設計上の注意点

### シングルリーダー/シングルアクセプター
```swift
// BAD: 複数の reader は TransportError.unsupportedOperation を投げる
async let r1 = connection.read()
async let r2 = connection.read()  // Error!

// BAD: 複数の accepter は TransportError.unsupportedOperation を投げる
async let a1 = listener.accept()
async let a2 = listener.accept()  // Error!
```

### リスナーのライフサイクル
MemoryHub は weak reference を使用。リスナーへの strong reference を保有しなければ自動削除される。

## 使用例
```swift
// テストでの使用
let hub = MemoryHub()
let transport1 = MemoryTransport(hub: hub)
let transport2 = MemoryTransport(hub: hub)

// リスナーを開始
let listener = try await transport1.listen(.memory(id: "server"))

// ダイアル（リスナーを生成）
async let acceptTask = listener.accept()
let clientConn = try await transport2.dial(.memory(id: "server"))
let serverConn = try await acceptTask

// 通信
try await clientConn.write(Data("hello".utf8))
let data = try await serverConn.read()

// クリーンアップ
try await clientConn.close()
try await serverConn.close()
try await listener.close()
hub.reset()
```

## 注意点
- テスト専用（本番環境では使用しない）
- NIO依存なし
- シングルプロセス内でのみ動作
- シングルリーダー/シングルアクセプター制限あり

## Codex Review (2026-01-18)

### Info
| Issue | Location | Description |
|-------|----------|-------------|
| Empty Data EOF sentinel | `MemoryChannel.swift:44-116,120-155` | Empty `Data()` as EOF is ambiguous with zero-length payload; consider explicit EOF signal or document behavior |

### Design Questions
- EOF semantics: Memory returns empty `Data` on EOF while TCP throws. Consider aligning behavior across transports.

<!-- CONTEXT_EVAL_START -->
## 実装評価 (2026-02-16)

- 総合評価: **A** (100/100)
- 対象ターゲット: `P2PTransportMemory`
- 実装読解範囲: 5 Swift files / 744 LOC
- テスト範囲: 30 files / 488 cases / targets 5
- 公開API: types 7 / funcs 12
- 参照網羅率: type 0.86 / func 0.92
- 未参照公開型: 1 件（例: `MemoryListener`）
- 実装リスク指標: try?=0, forceUnwrap=0, forceCast=0, @unchecked Sendable=0, EventLoopFuture=0, DispatchQueue=0
- 評価所見: 重大な静的リスクは検出されず

### 重点アクション
- 未参照の公開型に対する直接テスト（生成・失敗系・境界値）を追加する。

※ 参照網羅率は「テストコード内での公開API名参照」を基準にした静的評価であり、動的実行結果そのものではありません。

<!-- CONTEXT_EVAL_END -->
