# Security Layer

## 概要
接続のセキュリティアップグレード層のプロトコル定義と実装を含むグループ。

## ディレクトリ構造
```
Security/
├── P2PSecurity/      # Protocol定義のみ
├── Noise/            # P2PSecurityNoise（Noise XX）
├── TLS/              # P2PSecurityTLS（TLS 1.3、swift-tls使用）
├── Plaintext/        # P2PSecurityPlaintext（テスト用）
└── Pnet/             # P2PSecurityPnet（Private Network、PSK + XSalsa20）
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
| `P2PSecurityTLS` | TLS 1.3実装（swift-tls使用） | P2PSecurity, swift-tls, swift-certificates, swift-asn1, swift-crypto |
| `P2PSecurityPlaintext` | テスト用プレーンテキスト | P2PSecurity |
| `P2PSecurityPnet` | Private Network（PSK + XSalsa20） | P2PCore, Crypto |

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
RawConnection (TCP/QUIC)
    ↓ PnetProtector.protect()     ← pnet有効時のみ
RawConnection (pnet encrypted)
    ↓ multistream-select (/tls/1.0.0 or /noise or /plaintext/2.0.0)
    ↓ SecurityUpgrader.secure()
SecuredConnection (localPeer, remotePeer確定)
```

## Wire Protocol IDs
- `/tls/1.0.0` - TLS 1.3（libp2p TLS仕様準拠、Go/Rust互換）
- `/noise` - Noise XXパターン
- `/plaintext/2.0.0` - プレーンテキスト（テスト用）

## 実装の特性

### 状態管理
- **NoiseConnection**: `Mutex<SendState>` + `Mutex<RecvState>` で全二重通信をロック競合なく実現
- **TLSSecuredConnection**: `Mutex<ConnectionState>` でスレッドセーフ
- **PlaintextConnection**: initialBufferのみMutex管理
- **NoiseHandshake**: `struct: Sendable`（値型で所有権が型レベルで明確、`mutating` メソッドで状態遷移）
- **PnetConnection**: `Mutex<PnetSendState>` + `Mutex<PnetRecvState>` で全二重通信（NoiseConnectionと同パターン）

### バッファリング戦略
- NoiseUpgrader/PlaintextUpgrader/TLSUpgrader: ハンドシェイク中に読み込みバッファ生成、SecuredConnectionに初期バッファとして渡す
- NoiseConnection: フレーム再構成用の読み込みバッファ
- TLSSecuredConnection: ハンドシェイク完了時にTCPセグメントに混在したアプリケーションデータを `initialApplicationData` として保持
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

## TLS 実装詳細

### 概要
swift-tls による RFC 8446 準拠の TLS 1.3 実装。libp2p TLS 仕様に準拠し、Go/Rust 実装との互換性を持つ。

### 暗号化
TLS 1.3 ハンドシェイク・暗号化/復号は swift-tls が担当。libp2p 層は証明書生成/検証のみを実装。

### 証明書
- エフェメラル P-256 鍵ペアで自己署名 X.509 証明書を生成
- libp2p 拡張 (OID: 1.3.6.1.4.1.53594.1.1) に SignedKey 構造体を埋め込み
- CertificateValidator コールバックで PeerID を抽出・検証
- swift-certificates + SwiftASN1 で証明書の生成・解析

### タイムアウト
`Mutex<Bool>` フラグで外部キャンセルとタイムアウトを区別。

## テスト実装状況

| テスト | ステータス | テスト数 | 説明 |
|-------|----------|---------|------|
| NoiseCryptoStateTests | ✅ 完了 | 260行 | MixHash, MixKey, Split |
| NoisePayloadTests | ✅ 完了 | 284行 | エンコード/デコード、署名 |
| NoiseHandshakeTests | ✅ 完了 | 401行 | メッセージA/B/Cシーケンス |
| NoiseIntegrationTests | ✅ 完了 | 423行 | E2Eハンドシェイク、読み書き |
| TLSCertificateTests | ✅ 完了 | 13テスト | 証明書生成、PeerID抽出、CertificateValidator |
| PlaintextTests | ✅ 完了 | 300行 | Exchange、双方向通信 |
| PnetTests | ✅ 完了 | 1025行 | XSalsa20, HSalsa20, PSK解析, 接続テスト |

## 実装ステータス

| 実装 | ステータス | 説明 |
|-----|----------|------|
| Noise XX | ✅ 実装済み | X25519 + ChaChaPoly + SHA256、小次数鍵検証含む |
| TLS 1.3 | ✅ 実装済み | swift-tls、libp2p証明書拡張、Go/Rust互換 |
| Plaintext | ✅ 実装済み | テスト用 |
| Early Muxer Negotiation (TLS ALPN) | ✅ 実装済み | `EarlyMuxerNegotiating` プロトコル + TLSUpgrader ALPN muxerヒント |
| Pnet (Private Network) | ✅ 実装済み | PSK + XSalsa20、go-libp2p互換 |

## 品質向上TODO

### 高優先度
- [x] **PlaintextErrorの文書化** - CONTEXT.mdに追加済み
- [x] **Early Muxer Negotiation** - TLS ALPN に muxer ヒントを含め、muxer ネゴシエーション RTT を省略
- [ ] **エラーメッセージの一貫性** - NoiseUpgraderのエラーメッセージ形式統一

### 中優先度
- [x] **TLS実装の追加** - swift-tls による TLS 1.3 実装完了（Go/Rust互換）
- [ ] **セキュリティ監査** - Noise実装の第三者レビュー
- [ ] **鍵交換メトリクス** - ハンドシェイク時間の計測

### 低優先度
- [ ] **Noiseパターンの拡張** - IKパターンのサポート（0-RTT用）

<!-- CONTEXT_EVAL_START -->
## 実装評価 (2026-02-16)

- 総合評価: **A** (99/100)
- 対象ターゲット: `P2PCertificate`, `P2PPnet`, `P2PSecurity`, `P2PSecurityNoise`, `P2PSecurityPlaintext`, `P2PSecurityTLS`
- 実装読解範囲: 20 Swift files / 3160 LOC
- テスト範囲: 57 files / 567 cases / targets 10
- 公開API: types 27 / funcs 11
- 参照網羅率: type 0.85 / func 0.91
- 未参照公開型: 4 件（例: `GeneratedCertificate`, `LibP2PCertificateError`, `PlaintextConnection`, `TLSSecuredConnection`）
- 実装リスク指標: try?=0, forceUnwrap=1, forceCast=0, @unchecked Sendable=0, EventLoopFuture=0, DispatchQueue=0
- 評価所見: 強制アンラップを含む実装がある

### 重点アクション
- 未参照の公開型に対する直接テスト（生成・失敗系・境界値）を追加する。
- 強制アンラップ箇所に前提条件テストを追加し、回帰時に即検出できるようにする。

※ 参照網羅率は「テストコード内での公開API名参照」を基準にした静的評価であり、動的実行結果そのものではありません。

<!-- CONTEXT_EVAL_END -->
