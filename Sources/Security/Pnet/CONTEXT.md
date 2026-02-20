# P2PSecurityPnet

## 概要
Private Network (pnet) 実装。Pre-Shared Key (PSK) と XSalsa20 ストリーム暗号で全ネットワークトラフィックを暗号化し、同じ PSK を持つノードのみが通信できるプライベートネットワークを構築する。

## 責務
- PSK ファイルの解析 (go-libp2p 互換フォーマット)
- XSalsa20 ストリーム暗号による接続の暗号化
- ノンス交換ハンドシェイク
- PSK フィンガープリントの計算

## 依存関係
- `P2PCore` (RawConnection, Multiaddr)
- `Crypto` (SHA256 のみ、フィンガープリント計算用)
- `NIOCore` (ByteBuffer)
- `Synchronization` (Mutex)

---

## ファイル構成

```
Sources/Security/Pnet/
├── PnetProtector.swift     # PSK プロテクタ (エントリポイント)
├── PnetConnection.swift    # 暗号化接続ラッパー
├── XSalsa20.swift          # XSalsa20 ストリーム暗号 (純粋 Swift)
└── PnetError.swift         # エラー定義
```

## 主要な型

| 型名 | 状態 | 説明 |
|-----|------|------|
| `PnetProtector` | Done | PSK プロテクタ、接続をラップ |
| `PnetConfiguration` | Done | PSK 設定、ファイル解析 |
| `PnetFingerprint` | Done | PSK の SHA-256 フィンガープリント |
| `PnetConnection` | Done | XSalsa20 で暗号化された RawConnection |
| `XSalsa20` | Done | XSalsa20 ストリーム暗号 |
| `PnetError` | Done | エラー定義 |

---

## PSK ファイルフォーマット (go-libp2p 互換)

```
/key/swarm/psk/1.0.0/
/base16/
<64 hex chars = 32 bytes PSK>
```

## ハンドシェイクプロトコル

```
Peer A                          Peer B
  |                               |
  |----> local_nonce (24 bytes)-->|  Step 1: ノンス送信
  |<---- remote_nonce (24 bytes)<-|  Step 2: ノンス受信
  |                               |
  |  write cipher: XSalsa20(psk, local_nonce)
  |  read cipher:  XSalsa20(psk, remote_nonce)
  |                               |
  |<==== encrypted traffic ======>|  Step 3: 全データ暗号化
```

## 暗号化詳細

### XSalsa20

XSalsa20 = HSalsa20 + Salsa20:
1. HSalsa20(key, nonce[0..16]) → 32 バイトサブキー
2. Salsa20(subkey, nonce[16..24]) → キーストリーム生成

### Salsa20 コア
- 4x4 uint32 マトリクスに対する 20 ラウンド (10 ダブルラウンド)
- 各ダブルラウンド = カラムラウンド + ダイアゴナルラウンド
- クォーターラウンド: `b ^= (a+d) <<< 7` 等

### カウンター
- 64 ビットブロックカウンター、64 バイトブロックごとにインクリメント

---

## 状態管理
- **PnetConnection**: `Mutex<PnetSendState>` + `Mutex<PnetRecvState>` で全二重通信をロック競合なく実現
- **XSalsa20**: `struct: Sendable` (値型、内部カウンターを `mutating` メソッドで管理)
- **PnetProtector**: イミュータブル、`Sendable` (PSK とフィンガープリントのみ保持)

## 接続フロー

```
RawConnection (TCP/QUIC)
    ↓ PnetProtector.protect()
RawConnection (pnet encrypted)
    ↓ multistream-select
    ↓ SecurityUpgrader.secure()
SecuredConnection (Noise/TLS over pnet)
```

pnet は SecurityUpgrader の下のレイヤーで動作する。全トラフィック (セキュリティハンドシェイク含む) が PSK で暗号化される。

---

## テスト

```
Tests/Security/PnetTests/
└── PnetTests.swift    # XSalsa20, HSalsa20, PSK 解析, 接続テスト
```

---

## 参照

- [go-libp2p pnet](https://github.com/libp2p/go-libp2p/tree/master/p2p/net/pnet)
- [XSalsa20 spec](https://cr.yp.to/snuffle/xsalsa-20081128.pdf)
- [Salsa20 spec](https://cr.yp.to/snuffle/spec/20110711/snuffle-spec.pdf)

<!-- CONTEXT_EVAL_START -->
## 実装評価 (2026-02-16)

- 総合評価: **A** (100/100)
- 対象ターゲット: `P2PPnet`
- 実装読解範囲: 4 Swift files / 700 LOC
- テスト範囲: 1 files / 48 cases / targets 1
- 公開API: types 6 / funcs 4
- 参照網羅率: type 1.0 / func 1.0
- 未参照公開型: 0 件（例: `なし`）
- 実装リスク指標: try?=0, forceUnwrap=0, forceCast=0, @unchecked Sendable=0, EventLoopFuture=0, DispatchQueue=0
- 評価所見: 重大な静的リスクは検出されず

### 重点アクション
- 現行のテスト網羅を維持し、機能追加時は同一粒度でテストを増やす。

※ 参照網羅率は「テストコード内での公開API名参照」を基準にした静的評価であり、動的実行結果そのものではありません。

<!-- CONTEXT_EVAL_END -->
