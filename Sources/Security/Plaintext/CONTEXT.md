# P2PSecurityPlaintext

## 概要
テスト用のプレーンテキストセキュリティ実装（暗号化なし）。

## 責務
- 公開鍵の交換とPeerID検証
- 暗号化なしの透過的なデータ転送
- テスト環境での高速な接続確立

## 依存関係
- `P2PSecurity` (SecurityUpgrader protocol)

## 主要な型

| 型名 | 状態 | 説明 |
|-----|------|------|
| `PlaintextUpgrader` | ✅ 実装済み | SecurityUpgrader実装 |
| `PlaintextConnection` | ✅ 実装済み | SecuredConnection実装 |
| `Exchange` | ✅ 実装済み | ハンドシェイクメッセージ型 |
| `PlaintextError` | ✅ 実装済み | エラー型 |

## Wire Protocol

### プロトコルID
`/plaintext/2.0.0`

### ハンドシェイク
```protobuf
message Exchange {
  bytes id = 1;        // PeerIDバイト
  bytes pubkey = 2;    // 公開鍵（protobuf encoded）
}
```

### フロー
```
Initiator                       Responder
    |                               |
    |----> Exchange --------------->|
    |<---- Exchange <---------------|
    |     (PeerID confirmed)        |
```

### フレームフォーマット
```
+------------------+------------------+
| Length (varint)  | Exchange (proto) |
+------------------+------------------+
```

## 実装ノート

### PlaintextUpgrader
```swift
public final class PlaintextUpgrader: SecurityUpgrader, Sendable {
    public var protocolID: String { "/plaintext/2.0.0" }
    
    public func secure(
        _ connection: any RawConnection,
        localKeyPair: KeyPair,
        as role: SecurityRole,
        expectedPeer: PeerID?
    ) async throws -> any SecuredConnection
}
```

### PlaintextConnection
```swift
public final class PlaintextConnection: SecuredConnection, Sendable {
    public let localPeer: PeerID
    public let remotePeer: PeerID
    private let underlying: any RawConnection
    
    // read/write は underlying に直接委譲
}
```

## エラー型

### PlaintextError

| エラー | 説明 |
|-------|------|
| `insufficientData` | Exchangeメッセージのデコード中にデータ不足 |
| `invalidExchange` | Exchangeメッセージに必須フィールド（peerID、pubkey）がない |
| `peerIDMismatch` | 公開鍵から導出したPeerIDと主張されたPeerIDが不一致 |
| `messageTooLarge` | Exchange長プレフィックスが上限（64KB）を超過 |

### SecurityErrorへのラッピング
`PlaintextUpgrader`は`PlaintextError`を`SecurityError`にラップして投げる:
```swift
throw SecurityError.handshakeFailed(underlying: PlaintextError.peerIDMismatch)
throw SecurityError.peerMismatch(expected: expected, actual: actual)
```

## 実装詳細

### バッファリング
`readLengthPrefixedMessage()`関数がTCPストリームセマンティクスを適切に処理:
- varint長プレフィックスの完全読み取り
- メッセージ全体の受信まで待機
- 余剰データを`remainder`として返却

### initialBuffer
ハンドシェイク後の余剰データは`PlaintextConnection`の`initialBuffer`に渡される:
- 最初の`read()`で優先して返却
- バッファが空になったら基底接続から読み取り

## 注意点
- **テスト専用**: 本番環境では絶対に使用しない
- PeerID検証は必須（expectedPeerがある場合）
- 暗号化なし = 盗聴・改ざん可能

## 品質向上TODO

### 高優先度
- [x] **PlaintextUpgraderテスト** - Exchange encode/decode / mismatch / バッファリング（`PlaintextTests.swift`）

### 中優先度
- [ ] **Go/Rust相互運用テスト** - 実際のノードとのハンドシェイク
- [ ] **エラーメッセージの詳細化** - デバッグ情報の追加

## 参照
- [Plaintext 2.0 Spec](https://github.com/libp2p/specs/blob/master/plaintext/README.md)

## Codex Review (2026-01-18, Updated 2026-02-14)

### Warning
| Issue | Location | Status | Description |
|-------|----------|--------|-------------|
| Unbounded handshake size | `PlaintextUpgrader.swift:readLengthPrefixedMessage` | ✅ Fixed | `maxPlaintextHandshakeSize` (64KB) を導入し、超過時は `messageTooLarge` で即失敗。回帰テスト `handshakeRejectsOversizedLengthPrefix` を追加 |

### Info
| Issue | Location | Description |
|-------|----------|-------------|
| Handshake ordering | `PlaintextUpgrader.swift` | Sends local exchange before reading regardless of role. Full-duplex OK, but may reduce interop if peer expects initiator-first |
| Repeated Data allocations | `PlaintextUpgrader.swift` | Minor perf: repeated `Data` wrapping in varint decoding |

<!-- CONTEXT_EVAL_START -->
## 実装評価 (2026-02-16)

- 総合評価: **A** (92/100)
- 対象ターゲット: `P2PSecurityPlaintext`
- 実装読解範囲: 2 Swift files / 264 LOC
- テスト範囲: 18 files / 266 cases / targets 4
- 公開API: types 4 / funcs 5
- 参照網羅率: type 0.75 / func 1.0
- 未参照公開型: 1 件（例: `PlaintextConnection`）
- 実装リスク指標: try?=0, forceUnwrap=0, forceCast=0, @unchecked Sendable=0, EventLoopFuture=0, DispatchQueue=0
- 評価所見: 重大な静的リスクは検出されず

### 重点アクション
- 未参照の公開型に対する直接テスト（生成・失敗系・境界値）を追加する。

※ 参照網羅率は「テストコード内での公開API名参照」を基準にした静的評価であり、動的実行結果そのものではありません。

<!-- CONTEXT_EVAL_END -->
