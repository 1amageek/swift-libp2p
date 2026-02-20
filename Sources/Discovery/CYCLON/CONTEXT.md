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
- Node統合: `NodeDiscoveryHandlerRegistrable` + `NodeDiscoveryStartableWithOpener` に準拠

## 参考

- 論文: "CYCLON: Inexpensive Membership Management for Unstructured P2P Overlays"
- 同モジュール内パターン: `SWIMMembership` (actor + EventBroadcaster)

<!-- CONTEXT_EVAL_START -->
## 実装評価 (2026-02-16)

- 総合評価: **A** (86/100)
- 対象ターゲット: `P2PDiscoveryCYCLON`
- 実装読解範囲: 7 Swift files / 781 LOC
- テスト範囲: 3 files / 27 cases / targets 1
- 公開API: types 6 / funcs 8
- 参照網羅率: type 0.67 / func 0.5
- 未参照公開型: 2 件（例: `CYCLONConfiguration`, `CYCLONError`）
- 実装リスク指標: try?=0, forceUnwrap=0, forceCast=0, @unchecked Sendable=0, EventLoopFuture=0, DispatchQueue=0
- 評価所見: 公開関数の直接参照テストが薄い

### 重点アクション
- 未参照の公開型に対する直接テスト（生成・失敗系・境界値）を追加する。
- API名での直接参照だけでなく、振る舞い検証中心の統合テストを補強する。

※ 参照網羅率は「テストコード内での公開API名参照」を基準にした静的評価であり、動的実行結果そのものではありません。

<!-- CONTEXT_EVAL_END -->
