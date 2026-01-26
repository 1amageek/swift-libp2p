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

- `TLSUpgrader.swift` - SecurityUpgrader 実装
- `TLSConnection.swift` - SecuredConnection 実装
- `TLSCertificate.swift` - 証明書生成/検証
- `TLSError.swift` - エラー定義

## 設計原則

1. **Noise パターン適用**: 送受信で独立した状態管理
2. **Mutex<State>**: 高頻度操作用
3. **Network.framework 活用**: Apple の TLS 実装を使用

## プロトコル ID

`/tls/1.0.0`
