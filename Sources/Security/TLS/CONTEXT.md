# TLS 実装 (TCP 用)

## 概要

TCP 接続用の TLS 1.3 セキュリティアップグレーダー。
[swift-tls](https://github.com/1amageek/swift-tls) を使用し、libp2p TLS 仕様に準拠。
SecurityUpgrader プロトコルを実装。

## 依存ライブラリ

- **swift-tls** (`TLSCore`, `TLSRecord`) — TLS 1.3 ハンドシェイク・レコード層
- **swift-certificates** (`X509`) — X.509 証明書の生成・解析
- **swift-asn1** (`SwiftASN1`) — ASN.1 DER エンコード/デコード
- **swift-crypto** (`Crypto`) — P-256 鍵生成（証明書用エフェメラル鍵）

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

- `TLSUpgrader.swift` — SecurityUpgrader 実装（タイムアウト対応）
- `TLSConnection.swift` — SecuredConnection 実装（swift-tls ラッパー）
- `TLSCertificate.swift` — 証明書生成/検証（swift-certificates 使用）
- `TLSError.swift` — エラー定義

## アーキテクチャ

```
TLSUpgrader.secure()
  └─> LibP2PCertificate.generate()         // swift-certificates で証明書生成
  └─> TLSCore.TLSConfiguration 構築        // ALPN, mTLS, certificateValidator 設定
  └─> TLSRecord.TLSConnection 作成
  └─> performHandshake()                   // Mutex<Bool> タイムアウト付き
      ├─> startHandshake(isClient:)        // ClientHello / ServerHello 送信
      └─> processReceivedData() ループ     // ハンドシェイク完了まで
  └─> validatedPeerInfo → PeerID 抽出      // certificateValidator の結果
  └─> TLSSecuredConnection(...)            // 暗号化接続を返す

TLSSecuredConnection
  ├─> read()  → underlying.read() → processReceivedData() → applicationData
  ├─> write() → writeApplicationData() → underlying.write()
  └─> close() → close() → underlying.write(close_notify) → underlying.close()
```

## 設計

1. **swift-tls 委譲**: TLS 1.3 ハンドシェイク・暗号化/復号は swift-tls が担当
2. **certificateValidator**: swift-tls のコールバックで PeerID を抽出・検証
3. **initialApplicationData バッファ**: ハンドシェイク完了時に TCP セグメントに混在したアプリケーションデータを保持
4. **タイムアウト判定**: `Mutex<Bool>` フラグで外部キャンセルとタイムアウトを区別

## プロトコル ID

`/tls/1.0.0`

## Early Muxer Negotiation (ALPN)

✅ **実装済み** — `EarlyMuxerNegotiating` プロトコル準拠。

ALPN トークンに muxer ヒントを含め、TLS ハンドシェイク中に muxer を決定する。
multistream-select の muxer ネゴシエーション RTT を省略。

### ALPN フォーマット
```
Client/Server ALPN list (priority order):
  ["libp2p/yamux/1.0.0", "libp2p/mplex/6.7.0", "libp2p"]
           ↑ muxer hints                         ↑ fallback
```

### フロー
- `negotiatedALPN` が `"libp2p/"` で始まる場合: muxer プロトコルを抽出（例: `/yamux/1.0.0`）
- `negotiatedALPN` が `"libp2p"` の場合: 従来の multistream-select で muxer ネゴシエーション

### API
- `TLSUpgrader.secureWithEarlyMuxer()` — muxer プロトコル一覧を ALPN に含めてハンドシェイク
- `TLSUpgrader.buildALPNProtocols()` — ALPN トークン一覧を構築
- `TLSUpgrader.extractMuxerProtocol()` — negotiated ALPN から muxer を抽出
