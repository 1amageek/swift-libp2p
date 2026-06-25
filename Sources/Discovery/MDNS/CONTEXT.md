# P2PDiscoveryMDNS

mDNS (RFC 6762) / DNS-SD (RFC 6763) によるLAN内ピア発見。

## 概要

ローカルネットワークセグメント上で libp2p ピアをアドバタイズ・発見する
`DiscoveryService` 実装。Multicast DNS を使うため到達範囲は同一リンクに限定される。

## キーとなる型

- **MDNSDiscovery** (`actor`): `DiscoveryService` 準拠。低頻度・ユーザー向けAPI
- **MDNSConfiguration**: サービスタイプ (`_p2p._udp`)、クエリ間隔 (120秒等)、
  IPv4/IPv6、`peerNameStrategy`（既定 `.random`、`.peerID` は opt-in 互換モード）
- **PeerIDServiceCodec**: PeerID ↔ mDNS サービスの変換（`dnsaddr=` TXT 属性 優先）

## 依存 (swift-mDNS facade)

`import MDNS` で Tier-1 facade を使う。主に利用する型:
- `MDNSBrowser` / `MDNSResponder`（`browse(_:)` / `advertise(_:)` で auto-start）
- `MDNSService`（発見されたサービス値）/ `MDNSDiscoveries`（upsert ストリーム）
- `MDNSError`（typed エラー）

## 不変条件

- **EventBroadcaster<PeerObservation>**: 多消費者イベント（Discovery 層統一）
- **Upsert-only / `.unreachable` を合成しない**: facade は goodbye (TTL 0) でも
  最後の `MDNSService` 値を再送するだけで、add/update と値レベルで区別できない。
  存在しないイベントを捏造しないため、本サービスは `.announcement` / `.reachable`
  のみを emit し、`knownServicesByPeerID` は upsert-only キャッシュとする
- **shutdown 契約**: `func shutdown() async throws` を実装。`forwardTask` を cancel し
  browser/responder を stop、内部マップ・`sequenceNumber` をリセット。冪等
- `deinit` で `broadcaster.shutdown()`（idempotent）

## PeerID 推定順序

`dnsaddr`（優先）→ `pk` → legacy service name。service name に依存しない設計のため
`peerNameStrategy = .random` でも復元できる。

## 同モジュール内パターン

`SWIMMembership` / `CYCLONDiscovery`（actor + EventBroadcaster<PeerObservation>）。
