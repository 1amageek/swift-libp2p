# TLS 実装 (TCP 用)

## 概要

TCP 接続用の TLS セキュリティアップグレーダー。
libp2p TLS 仕様に準拠し、SecurityUpgrader プロトコルを実装。

## libp2p TLS 仕様

### 証明書要件
1. **自己署名 X.509 証明書**
2. **エフェメラル P-256 鍵ペア** (TLS 用)
3. **libp2p 拡張** (OID: 1.3.6.1.4.1.53594.1.1)
   - SignedKey 構造体を含む
   - libp2p 公開鍵 + 署名

### SignedKey 構造体
```
SignedKey {
    publicKey: bytes    // protobuf エンコードされた libp2p 公開鍵
    signature: bytes    // "libp2p-tls-handshake:" + SPKI(DER) の署名
}
```

## ファイル構成

- `TLSUpgrader.swift` - SecurityUpgrader 実装（タイムアウト対応）
- `TLSConnection.swift` - SecuredConnection 実装（3-Mutex パターン）
- `TLSCertificate.swift` - 証明書生成/検証
- `TLSCryptoState.swift` - AES-GCM 暗号化状態管理
- `TLSUtils.swift` - 共有ユーティリティ（ASN.1 解析、フレーミング）
- `TLSError.swift` - エラー定義

## 設計原則

1. **3-Mutex パターン**: Noise と同じ SendState/RecvState/SharedState 分離
2. **AES-256-GCM 暗号化**: nonce カウンタ管理、認証タグ検証
3. **2バイト長プレフィックス**: シンプルなフレームフォーマット

## アーキテクチャ

```
TLSUpgrader.secure()
  └─> TLSCertificate.generate()     // 証明書生成
  └─> performHandshake()            // タイムアウト付き
      ├─> sendCertificate() / receiveCertificate()
      ├─> TLSCertificate.verifyAndExtractPeerID()
      └─> deriveSessionKeys()
  └─> TLSConnection(...)            // 暗号化接続を返す

TLSConnection
  ├─> sendState: Mutex<TLSSendState>   // write() 専用
  ├─> recvState: Mutex<TLSRecvState>   // read() 専用
  └─> sharedState: Mutex<TLSSharedState>  // isClosed
```

## プロトコル ID

`/tls/1.0.0`

## 定数

```swift
tlsMaxMessageSize = 16640     // 16KB + overhead
tlsMaxPlaintextSize = 16624   // 16640 - 16 (auth tag)
tlsAuthTagSize = 16           // AES-GCM 認証タグ
tlsNonceSize = 12             // AES-GCM nonce
```

## 実装状況

| 機能 | 状態 |
|------|------|
| 証明書生成 | ✅ 完了 |
| 証明書検証 | ✅ 完了 |
| AES-GCM 暗号化 | ✅ 完了 |
| 3-Mutex 状態管理 | ✅ 完了 |
| フレーミング | ✅ 完了 |
| タイムアウト | ✅ 完了 |
| ASN.1 共通化 | ✅ 完了 |

## 修正済み Issues

- ~~CRITICAL: 暗号化が未実装~~ → AES-256-GCM 実装済み
- ~~HIGH: ASN.1 解析の重複~~ → TLSUtils.swift に統合
- ~~HIGH: handshakeTimeout が未使用~~ → Task ベースのタイムアウト実装
- ~~MEDIUM: エラーを握りつぶしている~~ → 適切なエラー伝播
- ~~LOW: デッドコード (TLSRecord)~~ → 削除済み
- ~~MEDIUM: nonce フィールドが未使用~~ → TLSCipherState で使用
