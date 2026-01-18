# Security Layer

## 概要
接続のセキュリティアップグレード層のプロトコル定義と実装を含むグループ。

## ディレクトリ構造
```
Security/
├── P2PSecurity/      # Protocol定義のみ
├── Noise/            # P2PSecurityNoise（Noise XX）
└── Plaintext/        # P2PSecurityPlaintext（テスト用）
```

## 設計原則
- **Protocol定義と実装の分離**: P2PSecurityはprotocolのみ
- **RawConnection → SecuredConnection**: 暗号化アップグレード
- **相互認証**: PeerID検証を含む

## サブモジュール

| ターゲット | 責務 | 依存関係 |
|-----------|------|----------|
| `P2PSecurity` | SecurityUpgraderプロトコル定義 | P2PCore |
| `P2PSecurityNoise` | Noise XXパターン実装 | P2PSecurity, swift-crypto |
| `P2PSecurityPlaintext` | テスト用プレーンテキスト | P2PSecurity |

## 主要なプロトコル

```swift
public protocol SecurityUpgrader: Sendable {
    var protocolID: String { get }
    
    func secure(
        _ connection: any RawConnection,
        localKeyPair: KeyPair,
        as role: SecurityRole,
        expectedPeer: PeerID?
    ) async throws -> any SecuredConnection
}
```

## 接続フロー
```
RawConnection
    ↓ multistream-select (/noise or /plaintext/2.0.0)
    ↓ SecurityUpgrader.secure()
SecuredConnection (localPeer, remotePeer確定)
```

## Wire Protocol IDs
- `/noise` - Noise XXパターン
- `/plaintext/2.0.0` - プレーンテキスト（テスト用）

## 実装の特性

### 状態管理
- **NoiseConnection**: `Mutex<NoiseConnectionState>`でスレッドセーフ
- **PlaintextConnection**: initialBufferのみMutex管理
- ハンドシェイク中のNoiseHandshakeはスレッドセーフでない（単一async taskで使用が前提）

### バッファリング戦略
- NoiseUpgrader/PlaintextUpgrader: ハンドシェイク中に読み込みバッファ生成、SecuredConnectionに初期バッファとして渡す
- NoiseConnection: フレーム再構成用の読み込みバッファ
- PlaintextConnection: Exchange後の余剰データバッファ

## 注意点
- expectedPeerが指定された場合、PeerID検証必須
- ハンドシェイク失敗時は適切なSecurityError
- **SecuredConnectionプロトコルはP2PCore内で定義**（P2PSecurityではない）

## PlaintextError

```swift
public enum PlaintextError: Error, Sendable {
    case insufficientData         // 不完全なメッセージ
    case invalidExchange          // 必須フィールドの欠落
    case peerIDMismatch           // 派生PeerID ≠ 主張PeerID
}
```

## Noise実装詳細

### 暗号化スイート
`Noise_XX_25519_ChaChaPoly_SHA256`

### HKDF実装
- RFC 5869準拠のカスタムHKDF-Expand実装を使用
- swift-cryptoのHKDF型は使わず、HMAC-SHA256で可変長出力を生成

### フレーム定数
| 定数 | 値 | 説明 |
|------|-----|------|
| noiseMaxMessageSize | 65535 | 最大フレームサイズ（2バイト長プレフィックス含む）|
| noiseMaxPlaintextSize | 65519 | 最大平文サイズ（65535 - 16認証タグ）|
| noiseAuthTagSize | 16 | ChaCha20-Poly1305認証タグ |
| noisePublicKeySize | 32 | X25519公開鍵サイズ |

### ノンス形式
12バイトノンス = 4バイトゼロ + 8バイトリトルエンディアンカウンタ

## テスト実装状況

| テスト | ステータス | テスト数 | 説明 |
|-------|----------|---------|------|
| NoiseCryptoStateTests | ✅ 完了 | 260行 | MixHash, MixKey, Split |
| NoisePayloadTests | ✅ 完了 | 284行 | エンコード/デコード、署名 |
| NoiseHandshakeTests | ✅ 完了 | 401行 | メッセージA/B/Cシーケンス |
| NoiseIntegrationTests | ✅ 完了 | 423行 | E2Eハンドシェイク、読み書き |
| PlaintextTests | ✅ 完了 | 300行 | Exchange、双方向通信 |

**合計**: ~1,678行のテストコード

## 品質向上TODO

### 高優先度
- [x] **PlaintextErrorの文書化** - CONTEXT.mdに追加済み
- [ ] **エラーメッセージの一貫性** - NoiseUpgraderのエラーメッセージ形式統一

### 中優先度
- [ ] **TLS実装の追加** - rust-libp2pとの互換性向上
- [ ] **セキュリティ監査** - Noise実装の第三者レビュー
- [ ] **鍵交換メトリクス** - ハンドシェイク時間の計測

### 低優先度
- [ ] **Noiseパターンの拡張** - IKパターンのサポート（0-RTT用）
