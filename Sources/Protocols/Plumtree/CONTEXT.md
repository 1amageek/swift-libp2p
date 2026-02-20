# Plumtree — Epidemic Broadcast Trees

## Overview

Plumtree implements the Epidemic Broadcast Trees protocol for efficient
message dissemination across a peer-to-peer network. It combines two
complementary strategies:

- **Eager push** (tree links): Full messages are forwarded immediately
  to peers in the eager set, forming a spanning tree.
- **Lazy push** (gossip links): IHave notifications are sent to peers
  in the lazy set, providing redundancy for tree repair.

## Protocol ID

`/plumtree/1.0.0`

## Architecture

| Component | Pattern | Role |
|-----------|---------|------|
| PlumtreeRouter | final class + Mutex | Core state machine (eager/lazy peer sets, dedup, message store) |
| LazyPushBuffer | final class + Mutex | IHave batching buffer |
| PlumtreeService | final class + Mutex | Public API, ProtocolService conformance, stream I/O |

All components follow the **class + Mutex** pattern (high-frequency message routing).

### イベントパターン

PlumtreeServiceは **EventBroadcaster（多消費者）** を使用。

- **理由**: Pub/Sub型プロトコル。複数の消費者が異なるトピックを同時に購読する（`subscribe(to: Topic)`）
- **実装**: 2つのbroadcaster
  - `eventBroadcaster`: プロトコルイベント（pruneSent, graftSent等）
  - `messageBroadcaster`: メッセージ配信（トピックごとのフィルタリング）
- **ライフサイクル**: `stop()` で両方のbroadcasterを `shutdown()`

## Algorithm

```
New peer connects:
  → Add to eagerPeers for all subscribed topics

GOSSIP received (from peer P):
  if unseen message:
    → Deliver to local subscribers
    → Forward GOSSIP to eagerPeers (excluding P)
    → Send IHave to lazyPeers (excluding P)
    → Cancel any pending IHave timer for this message
  if duplicate:
    → Send PRUNE to P (move P to lazyPeers)

IHAVE received (from peer P):
  if message not yet received:
    → Start timer (ihaveTimeout)
    → On timeout: send GRAFT to P (move P to eagerPeers)

GRAFT received (from peer P):
  → Move P to eagerPeers
  → Re-send requested message if available

PRUNE received (from peer P):
  → Move P to lazyPeers
```

## Wire Format

Hand-written protobuf (same pattern as GossipSub).

## Dependencies

- P2PProtocols (ProtocolService, StreamOpener, HandlerRegistry)
- P2PCore (PeerID, Multiaddr, Varint, EventBroadcaster)
- P2PMux (MuxedStream)

<!-- CONTEXT_EVAL_START -->
## 実装評価 (2026-02-16)

- 総合評価: **A** (92/100)
- 対象ターゲット: `P2PPlumtree`
- 実装読解範囲: 8 Swift files / 1882 LOC
- テスト範囲: 6 files / 77 cases / targets 2
- 公開API: types 17 / funcs 18
- 参照網羅率: type 0.65 / func 0.94
- 未参照公開型: 6 件（例: `HandleGossipResult`, `HandleGraftResult`, `HandleIHaveResult`, `HandlePruneResult`, `IHaveTimeoutResult`）
- 実装リスク指標: try?=0, forceUnwrap=0, forceCast=0, @unchecked Sendable=0, EventLoopFuture=0, DispatchQueue=0
- 評価所見: 重大な静的リスクは検出されず

### 重点アクション
- 未参照の公開型に対する直接テスト（生成・失敗系・境界値）を追加する。

※ 参照網羅率は「テストコード内での公開API名参照」を基準にした静的評価であり、動的実行結果そのものではありません。

<!-- CONTEXT_EVAL_END -->
