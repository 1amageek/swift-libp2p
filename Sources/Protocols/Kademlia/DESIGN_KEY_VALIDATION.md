# KademliaKey 入力検証設計

## 問題の背景

Kademlia DHT では、ネットワークから受信したメッセージに含まれる `key` フィールドを処理する必要がある。
不正なキー長の入力を適切に検証しないと、`precondition` 違反によりプロセスがクラッシュする。

## Kademlia メッセージタイプと key フィールドの使い方

| メッセージタイプ | key の内容 | 期待される長さ | 処理方法 |
|-----------------|-----------|---------------|---------|
| FIND_NODE | PeerID の SHA-256 ハッシュ | 32 バイト固定 | 直接使用（検証必須） |
| GET_VALUE | 任意のレコードキー | 可変長 | SHA-256 ハッシュして使用 |
| PUT_VALUE | レコード内に含まれる | 可変長 | SHA-256 ハッシュして使用 |
| GET_PROVIDERS | CID (Content ID) | 可変長 | SHA-256 ハッシュして使用 |
| ADD_PROVIDER | CID (Content ID) | 可変長 | SHA-256 ハッシュして使用 |

## セキュリティ設計

### 1. イニシャライザの分離

`KademliaKey` に2つのイニシャライザを提供:

```swift
/// 内部使用専用 - 呼び出し元が32バイトを保証する場合
/// precondition で検証（違反時はクラッシュ）
public init(bytes: Data)

/// 外部入力用 - ネットワークからの未検証データ
/// throws で検証（違反時はエラーをスロー）
public init(validating bytes: Data) throws
```

### 2. 使い分けルール

| 状況 | 使用するイニシャライザ |
|-----|---------------------|
| PeerID からキー生成 | `init(from: PeerID)` → 内部で `init(hashing:)` |
| 任意データのハッシュ | `init(hashing: Data)` → SHA-256 は常に32バイト |
| ネットワーク受信データ（32バイト期待） | `init(validating:)` → 検証付き |
| XOR 距離計算結果 | `init(bytes:)` → 内部で32バイト保証 |

### 3. メッセージハンドラでの検証

```
FIND_NODE 受信
    ↓
key フィールド存在確認
    ↓
KademliaKey(validating: key) で32バイト検証
    ↓
失敗時: KademliaError.protocolViolation をスロー
    ↓
成功時: ルーティングテーブル検索に使用
```

### 4. エラー階層

```
KademliaKeyError
├── invalidLength(actual: Int, expected: Int)
│   └── 32バイト以外の入力

KademliaError
├── protocolViolation(String)
│   └── メッセージレベルでの検証失敗
│       （キー長エラーを含む）
```

## 現在の実装状況

### 実装済み

1. ✅ `KademliaKey.init(validating:)` - 32バイト検証付きイニシャライザ
2. ✅ `KademliaKeyError.invalidLength` - 専用エラー型
3. ✅ `handleMessage(.findNode)` での検証 - protocolViolation でラップ

### テスト未実装

1. ⬜ `init(validating:)` の正常系テスト
2. ⬜ `init(validating:)` の異常系テスト（短すぎ、長すぎ）
3. ⬜ `KademliaKeyError.invalidLength` のエラー情報テスト
4. ⬜ FIND_NODE メッセージの不正キー長拒否テスト

## テスト計画

### 1. KademliaKey 単体テスト

```swift
@Suite("KademliaKey Validation Tests")
struct KademliaKeyValidationTests {
    // 正常系: 32バイト入力
    @Test("Validating initializer accepts 32 bytes")

    // 異常系: 短い入力
    @Test("Validating initializer rejects short input")

    // 異常系: 長い入力
    @Test("Validating initializer rejects long input")

    // 異常系: 空入力
    @Test("Validating initializer rejects empty input")

    // エラー情報: actual と expected が正しい
    @Test("InvalidLength error contains correct lengths")
}
```

### 2. プロトコルハンドラ統合テスト

```swift
@Suite("Kademlia Protocol Validation Tests")
struct KademliaProtocolValidationTests {
    // FIND_NODE: 不正キー長で protocolViolation
    @Test("FIND_NODE rejects invalid key length")

    // FIND_NODE: 32バイトキーで正常処理
    @Test("FIND_NODE accepts valid 32-byte key")
}
```

## 将来の拡張

### 追加検討事項

1. **All-zero キーの拒否**: ルーティングに無意味なキーを拒否
2. **レート制限**: 不正リクエストの連続送信を検出・ブロック
3. **ログ記録**: 検証失敗をセキュリティログに記録

### 関連する他のプロトコル

同様の入力検証パターンを適用すべき箇所:
- PeerID のバイト列検証
- Multiaddr のバイト列検証
- Noise ハンドシェイクの公開鍵検証
