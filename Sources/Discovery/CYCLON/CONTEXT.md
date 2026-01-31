# P2PDiscoveryCYCLON

CYCLON ランダムピアサンプリングプロトコルの実装。

## 概要

各ノードが部分ビュー (partial view) を維持し、定期的にランダムなピアとエントリを交換 (shuffle) することで、ネットワーク全体のトポロジをランダム化する。

## アーキテクチャ

- **CYCLONDiscovery** (actor): `DiscoveryService` 準拠。低頻度シャッフル操作
- **CYCLONPartialView** (final class + Mutex): 部分ビュー管理。高頻度アクセス
- **EventBroadcaster<Observation>**: 多消費者イベントパターン (Discovery 層統一)

## 通信

- プロトコルID: `/cyclon/1.0.0`
- ワイヤフォーマット: 手書き protobuf
- ストリーム: `StreamOpener` 経由で length-prefixed メッセージ交換

## 参考

- 論文: "CYCLON: Inexpensive Membership Management for Unstructured P2P Overlays"
- 同モジュール内パターン: `SWIMMembership` (actor + EventBroadcaster)
