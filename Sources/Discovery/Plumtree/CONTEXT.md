# P2PDiscoveryPlumtree

Plumtree ベースの DiscoveryService 実装。

## 目的

- Plumtree ゴシップを使って自己アナウンスを配布
- 受信アナウンスを `Observation` / `ScoredCandidate` に変換
- `find(peer:)` / `knownPeers()` で候補探索に利用

## 構成

- `PlumtreeDiscovery` (actor): `DiscoveryService` 実装
- `PlumtreeDiscoveryConfiguration`: topic/TTL/容量/スコア設定
- `PlumtreeDiscoveryAnnouncement`: gossip wire payload (JSON)
- `PlumtreeDiscoveryError`: エラー定義

## 統合ポイント

- `NodeDiscoveryHandlerRegistrable` / `NodeDiscoveryStartable` / `NodeDiscoveryPeerStreamService` に準拠
- `registerHandler(registry:)` で Plumtree ハンドラ登録
- `handlePeerConnected` / `handlePeerDisconnected` で peer lifecycle を反映
- `start()` で topic 購読を開始し、`announce()` が publish 可能になる

## 制約

- Announcement payload は自己申告形式（暗号署名なし）
- `peerID` と gossip source peer の一致は必須
- `requireAddresses = true` の場合、妥当な Multiaddr が1つ以上必要

<!-- CONTEXT_EVAL_START -->
## 実装評価 (2026-02-16)

- 総合評価: **A** (92/100)
- 対象ターゲット: `P2PDiscoveryPlumtree`
- 実装読解範囲: 4 Swift files / 428 LOC
- テスト範囲: 1 files / 6 cases / targets 1
- 公開API: types 4 / funcs 9
- 参照網羅率: type 0.75 / func 0.67
- 未参照公開型: 1 件（例: `PlumtreeDiscoveryConfiguration`）
- 実装リスク指標: try?=0, forceUnwrap=0, forceCast=0, @unchecked Sendable=0, EventLoopFuture=0, DispatchQueue=0
- 評価所見: 重大な静的リスクは検出されず

### 重点アクション
- 未参照の公開型に対する直接テスト（生成・失敗系・境界値）を追加する。

※ 参照網羅率は「テストコード内での公開API名参照」を基準にした静的評価であり、動的実行結果そのものではありません。

<!-- CONTEXT_EVAL_END -->
