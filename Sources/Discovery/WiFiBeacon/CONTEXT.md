# P2PDiscoveryWiFiBeacon

WiFi beacon transport adapter — `TransportAdapter` の参照実装。

## 概要

UDP マルチキャストを使用して Beacon ペイロードを LAN 上で送受信する。
OS 固有 API（CoreBluetooth, MultipeerConnectivity 等）は不要。
SwiftNIO の `NIOUDPTransport` のみに依存。

## アーキテクチャ

```
WiFiBeaconAdapter (TransportAdapter 準拠)
├── NIOUDPTransport (UDP multicast)
├── WiFiBeaconFrame (8B header + payload)
└── WiFiBeaconConfiguration (group, port, interval)
```

## ワイヤーフォーマット

```
[Magic "P2" (2B)] [Version (1B)] [Flags (1B)] [PayloadLen (2B)] [Reserved (2B)] [Payload (NB)]
```

- Magic `0x50 0x32`: 非 P2P トラフィック即座拒否
- Max payload: 512B (`MediumCharacteristics.wifiDirect`)
- Total: 8 + 512 = 520B (MTU 内)

## デフォルト設定

| パラメータ | 値 | 根拠 |
|-----------|-----|------|
| Multicast group | `239.2.0.1` | RFC 2365 Organization-Local Scope |
| Port | `9876` | IANA 未登録 |
| Transmit interval | 5 秒 | BeaconDiscovery のデフォルト beaconRateLimit |
| Loopback | false | 自ビーコン受信は不要（テスト時のみ true） |

## 並行処理

- Class + Mutex パターン（プロジェクト規約: Transport 層は Mutex）
- `discoveries` は単一消費者パターン（EventEmitting）
- `shutdown() async` で `continuation.finish()` + `stream = nil`

## 依存

- `P2PDiscoveryBeacon`: `TransportAdapter` プロトコル、`RawDiscovery`、`OpaqueAddress`
- `P2PCore`: `PeerID`、`Multiaddr`
- `NIOUDPTransport`: UDP マルチキャスト送受信

<!-- CONTEXT_EVAL_START -->
## 実装評価 (2026-02-16)

- 総合評価: **A** (92/100)
- 対象ターゲット: `P2PDiscoveryWiFiBeacon`
- 実装読解範囲: 4 Swift files / 484 LOC
- テスト範囲: 3 files / 20 cases / targets 1
- 公開API: types 3 / funcs 3
- 参照網羅率: type 0.67 / func 1.0
- 未参照公開型: 1 件（例: `WiFiBeaconError`）
- 実装リスク指標: try?=0, forceUnwrap=0, forceCast=0, @unchecked Sendable=0, EventLoopFuture=0, DispatchQueue=0
- 評価所見: 重大な静的リスクは検出されず

### 重点アクション
- 未参照の公開型に対する直接テスト（生成・失敗系・境界値）を追加する。

※ 参照網羅率は「テストコード内での公開API名参照」を基準にした静的評価であり、動的実行結果そのものではありません。

<!-- CONTEXT_EVAL_END -->
