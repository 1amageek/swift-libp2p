# P2PDiscoverySWIM

SWIM (Scalable Weakly-consistent Infection-style Membership) によるクラスタ
メンバーシップ管理と障害検出。

## 概要

UDP 上で SWIM プロトコルを動かし、メンバーの alive/suspect/dead を追跡しゴシップで
伝播する `DiscoveryService` 実装。

## キーとなる型

- **SWIMMembership** (`actor`): `DiscoveryService` 準拠。低頻度・ユーザー向けAPI
- **SWIMMembershipConfiguration**: `port` (既定 7946)、`bindHost` (`0.0.0.0`)、
  `advertisedHost`（routable 必須、nil なら自動検出）、`swimConfig`
- **SWIMTransportAdapter**: `NIOUDPTransport` を SWIM の `SWIMTransport` に適合させる
- **SWIMBridge**: PeerID/Multiaddr ↔ SWIM `MemberID` の変換ユーティリティ

## 依存 (swift-SWIM facade)

- `import SWIM` — エンジン `SWIMCluster`（旧 `SWIMInstance` から改名。init 形状と
  `start/shutdown/join/leave/members/aliveCount/events` API は同一）、`Member` /
  `MemberID` / `SWIMConfiguration`
- `import SWIMWire` — Tier-3 ワイヤコーデック `SWIMMessageCodec`（transport adapter で使用）
- `import NIOUDPTransport` — UDP datagram トランスポート

## 不変条件

- **EventBroadcaster<PeerObservation>**: 多消費者イベント（Discovery 層統一）。
  SWIM ステータス遷移を `PeerObservation` に変換して emit する
- **advertisedHost は routable**: `0.0.0.0` / `::` は bind 専用。広告には不可
  （`resolveAdvertisedHost()` が検証）
- **announce ≠ メンバーシップ**: SWIM は明示 announce を使わず、`join(seeds:)` で
  クラスタに参加する。`announce(addresses:)` は localAddress 記録のみ
- **shutdown 契約**: `func shutdown() async throws` を実装。`forwardTask` cancel →
  `swim.leave()` → `swim.shutdown()` → `transport.shutdown()` → 状態リセット →
  `broadcaster.shutdown()`。冪等
- `deinit` で `broadcaster.shutdown()`（idempotent）

## SWIM 固有 API

`join(seeds:)` / `leave()` / `members` / `aliveCount` — `DiscoveryService` 要件外の
クラスタ操作。`DiscoveryServiceOwnershipRegistry.preconditionAccessible` で
pipeline 移譲後の直接アクセスをガードする。

## 同モジュール内パターン

`MDNSDiscovery` / `CYCLONDiscovery`（actor + EventBroadcaster<PeerObservation>）。
