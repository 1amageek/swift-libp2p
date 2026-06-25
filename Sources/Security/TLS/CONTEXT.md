# TLS 実装 (TCP 用)

## 概要

TCP 接続用の TLS 1.3 セキュリティアップグレーダー。
[swift-tls](https://github.com/1amageek/swift-tls) を使用し、libp2p TLS 仕様に準拠。
SecurityUpgrader プロトコルを実装。

## libp2p-TLS mutual authentication (complete, fail-closed)

libp2p-TLS の相互認証は **完成済み**。

- **相互 TLS**: `requireClientCertificate: true` で両端が証明書を提示する。
- **PeerID 抽出**: handshake 完了後、`TLSUpgrader` は `endpoint.peerIdentity`
  （Tier-1 `TLS` facade が surfacing する検証済み `PeerIdentity`）から remote
  PeerID を取り出し、`TLSSecuredConnection` にバインドする。
- **`verifyPeer: false` は正しい設計**: libp2p 証明書は CA チェーンを持たない
  自己署名 X.509 のため、facade 標準の CA チェーン検証は使わない。認証は弱まらない:
  (1) CertificateVerify の所有証明（peer がリーフ秘密鍵を保持する証明）が in-core で
  常に検証され、(2) custom `certificateValidator` が libp2p 拡張署名・PeerID 導出・
  `expectedPeer` 一致を強制する。これは動作実績のある swift-quic libp2p-TLS パスと同じ。
- **FAIL-CLOSED**: 検証済み identity が genuinely 取得できない場合のみ
  `TLSError.peerIdentityUnavailable` を throw する（未識別ピアを黙って受理しない）。
  さらに防御として、`expectedPeer` 指定時は surfacing された PeerID との一致を
  upgrader 側でも再確認する（validator 単独に依存しない）。

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
  └─> cachedIdentity(for:)                 // P2PCoreDER で自己署名証明書生成・identity 単位でキャッシュ
  └─> TLSConfiguration 構築                // ALPN, mTLS (requireClientCertificate),
  │                                        // verifyPeer:false, certificateValidator 設定
  └─> makeEndpoint() → TLSClient/TLSServer // role に応じて Tier-1 facade endpoint を作成
  └─> performTimedHandshake()              // Mutex<Bool> タイムアウト付き
      ├─> endpoint.startHandshake()        // ClientHello / ServerHello 送信
      └─> endpoint.receive() ループ        // endpoint.isEstablished まで
  └─> endpoint.peerIdentity → PeerID 抽出  // certificateValidator が surfacing した検証済み identity
  └─> TLSSecuredConnection(...)            // 暗号化接続を返す（early app data も保持）

TLSSecuredConnection
  ├─> read()  → underlying.read() → endpoint.receive() → applicationData
  ├─> write() → endpoint で暗号化 → underlying.write()
  └─> close() → close_notify → underlying.close()
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
