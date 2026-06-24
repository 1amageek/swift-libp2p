# TLS 実装 (TCP 用)

## 概要

TCP 接続用の TLS 1.3 セキュリティアップグレーダー。
[swift-tls](https://github.com/1amageek/swift-tls) を使用し、libp2p TLS 仕様に準拠。
SecurityUpgrader プロトコルを実装。

## Deferred: libp2p-TLS peer-identity surfacing (fail-closed)

swift-tls の facade 再設計後、`TLS` facade の `TLSClient`/`TLSServer` は
`certificateValidator` が返した `PeerIdentity` を破棄する（`peerIdentity` が常に
`nil` を返す既知のギャップ）。libp2p-TLS upgrader は検証済み remote PeerID を
`SecuredConnection` の構築に必須とするため、PeerID を取り出せない間は
`TLSError.peerIdentityUnavailable` を **throw して FAIL-CLOSED** する
（未認証/未識別ピアを黙って受理しない）。libp2p-TLS 認証の完成は、facade が
`peerIdentity` を surfacing するという deferred 修正でアンブロックされる。
それまで `TLSUpgrader.secure(...)` は常に reject する。
`TLSCertificateHelper.makeCertificateValidator` は handshake 中に libp2p 拡張を
検証し PeerID を再導出するので、不正/不一致証明書は handshake 内で reject される。

## 依存ライブラリ

- **swift-tls** (`TLS` facade — `TLSClient`/`TLSServer`/`TLSConfiguration`/
  `TLSIdentity`/`Certificate`/`PeerIdentity`) — TLS 1.3 ハンドシェイク・レコード層。
  旧 `TLSCore`/`TLSRecord` は facade 再設計で `TLS` に統合された
- **P2PCoreDER** (swift-p2p-core) — libp2p RPK 証明書の build/parse/verify の
  Embedded-clean minimal-DER コーデック（M6b で swift-certificates から移行）
- **swift-crypto** (`Crypto`) — P-256 鍵生成（証明書用エフェメラル鍵）+ SignedKey
  署名検証 / 自己署名（P2PCoreDER に closure として注入）

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
- `TLSCertificate.swift` — 証明書生成/検証（`LibP2PCertificate` 経由、P2PCoreDER 使用）
- `TLSError.swift` — エラー定義

## アーキテクチャ

```
TLSUpgrader.secure()
  └─> LibP2PCertificate.generate()         // P2PCoreDER で証明書生成（Embedded-clean）
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

<!-- CONTEXT_EVAL_START -->
## 実装評価 (2026-02-16)

- 総合評価: **A** (94/100)
- 対象ターゲット: `P2PSecurityTLS`
- 実装読解範囲: 5 Swift files / 644 LOC
- テスト範囲: 2 files / 32 cases / targets 1
- 公開API: types 8 / funcs 9
- 参照網羅率: type 0.88 / func 0.44
- 未参照公開型: 1 件（例: `TLSSecuredConnection`）
- 実装リスク指標: try?=0, forceUnwrap=0, forceCast=0, @unchecked Sendable=0, EventLoopFuture=0, DispatchQueue=0
- 評価所見: 公開関数の直接参照テストが薄い

### 重点アクション
- 未参照の公開型に対する直接テスト（生成・失敗系・境界値）を追加する。
- API名での直接参照だけでなく、振る舞い検証中心の統合テストを補強する。

※ 参照網羅率は「テストコード内での公開API名参照」を基準にした静的評価であり、動的実行結果そのものではありません。

<!-- CONTEXT_EVAL_END -->
