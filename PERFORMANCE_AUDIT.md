# swift-libp2p パフォーマンス最適化監査レポート

全モジュール (187ファイル) を対象に、パフォーマンス最適化の観点で調査した結果をまとめる。

---

## 修正状況サマリ (2026-02-06 更新)

| 重大度 | 総数 | ✅ 修正済み | ⬜ 未修正 |
|--------|------|-----------|----------|
| HIGH | 8件 | 6件 | 2件 (1.7 Noise HKDF, 1.8 HealthMonitor) |
| MEDIUM | 14件 | 10件 | 4件 (2.6 GossipSub protobuf, 2.8 AddressBook, 2.13 EventBroadcaster, 2.1 MessageCache) |
| LOW | 10件 | 0件 | 10件 (将来対応) |

---

## 目次

1. [重大度HIGH: 即時対応推奨](#1-重大度high-即時対応推奨)
2. [重大度MEDIUM: 改善推奨](#2-重大度medium-改善推奨)
3. [重大度LOW: 将来的な改善候補](#3-重大度low-将来的な改善候補)
4. [最適化済み（問題なし）](#4-最適化済み問題なし)
5. [全体サマリ](#5-全体サマリ)

---

## 1. 重大度HIGH: 即時対応推奨

### 1.1 ✅ TCP_NODELAY 未設定 — 修正済み

| 項目 | 値 |
|------|-----|
| ファイル | `Sources/Transport/TCP/TCPTransport.swift:52` |
| ステータス | ✅ 修正済み |

`TCPTransport.swift:52-53` と `TCPListener.swift:62-63` に `tcp_nodelay` + `so_keepalive` 設定済み。

---

### 1.2 ✅ Base58デコードの O(n²) 計算量 — 修正済み

| 項目 | 値 |
|------|-----|
| ファイル | `Sources/Core/P2PCore/Utilities/Base58.swift` |
| ステータス | ✅ 修正済み — `append` + `reverse` パターンに変更済み |

---

### 1.3 ✅ Multiaddr.bytes の O(n²) Data結合 — 修正済み

| 項目 | 値 |
|------|-----|
| ファイル | `Sources/Core/P2PCore/Addressing/Multiaddr.swift:127-133` |
| ステータス | ✅ 修正済み — `for` + `append` パターンに変更済み（O(n)） |

---

### 1.4 ✅ RoutingTable.closestPeers の全エントリソート — 修正済み

| 項目 | 値 |
|------|-----|
| ファイル | `Sources/Protocols/Kademlia/RoutingTable.swift` |
| ステータス | ✅ 修正済み — `smallest()` 部分ソート + bucket-proximity expansion 使用 |

---

### 1.5 ✅ PeerStore LRU 管理の O(n) touchPeer — 修正済み

| 項目 | 値 |
|------|-----|
| ファイル | `Sources/Discovery/P2PDiscovery/PeerStore.swift` |
| ステータス | ✅ 修正済み — `LRUOrder<PeerID>` 二重連結リストで O(1) 操作 |

---

### 1.6 ✅ CompositeDiscovery の逐次サービス問い合わせ — 修正済み

| 項目 | 値 |
|------|-----|
| ファイル | `Sources/Discovery/P2PDiscovery/CompositeDiscovery.swift:166` |
| ステータス | ✅ 修正済み — `withTaskGroup` による並列クエリに変更済み |

---

### 1.7 Noise HKDF鍵導出の不要なData変換

| 項目 | 値 |
|------|-----|
| ファイル | `Sources/Security/Noise/NoiseCryptoState.swift:228-258` |
| 影響 | ハンドシェイク中に2回呼ばれる鍵分割処理 |
| 原因 | `SymmetricKey` ↔ `Data` の繰り返し変換 |

```swift
// 現状: 各反復で不要なData変換
let prk = HMAC<SHA256>.authenticationCode(
    for: ikm.withUnsafeBytes { Data($0) },  // 変換1
    using: SymmetricKey(data: salt)
)
// ループ内:
let block = HMAC<SHA256>.authenticationCode(
    for: input,
    using: SymmetricKey(data: Data(prk))  // 毎回変換
)
t = Data(block)  // 毎回変換
```

`withUnsafeBytes` を使い中間Data生成を排除すべき。

---

### 1.8 HealthMonitor のピア毎Task生成

| 項目 | 値 |
|------|-----|
| ファイル | `Sources/Integration/P2P/Connection/HealthMonitor.swift:133-136,168-205` |
| 影響 | 1000ピアで1000個のTask生成 |
| 原因 | `monitoringTasks: [PeerID: Task<Void, Never>]` |

ピア毎に個別のTaskを作成するため、大量のピアでスケールしない。バッチ処理に変更すべき。

---

## 2. 重大度MEDIUM: 改善推奨

### 2.1 GossipSub MessageCache.getGossipIDs の二重イテレーション

| 項目 | 値 |
|------|-----|
| ファイル | `Sources/Protocols/GossipSub/Router/MessageCache.swift:108-124` |
| 影響 | 毎秒のハートビートで呼ばれる |
| 計算量 | O(windows × IDs_per_window) + dictionary lookups |

ウィンドウの全メッセージIDに対してディクショナリ検索を行い、トピックでフィルタリングしている。トピック別のインデックスを追加することで O(1) でアクセス可能になる。

---

### 2.2 ✅ MeshState.allMeshPeers のキャッシュなし再計算 — 修正済み

| 項目 | 値 |
|------|-----|
| ファイル | `Sources/Protocols/GossipSub/Router/MeshState.swift:39` |
| ステータス | ✅ 修正済み — `allMeshPeersCache` でキャッシュ、メッシュ変更時にinvalidate |

---

### 2.3 ✅ Yamux/Mplex バッファスライス生成 — 修正済み

| 項目 | 値 |
|------|-----|
| ファイル | `Sources/Mux/Yamux/YamuxConnection.swift`, `Sources/Mux/Mplex/MplexConnection.swift` |
| ステータス | ✅ 修正済み — NIO `ByteBuffer` の reader/writer index 使用 |

---

### 2.4 ✅ TCP/WebSocket 読み取りパスの不要なデータコピー — 改善済み

| 項目 | 値 |
|------|-----|
| ファイル | `Sources/Transport/TCP/TCPConnection.swift`, `Sources/Transport/WebSocket/WebSocketConnection.swift` |
| ステータス | ✅ 改善済み — NIO ByteBuffer lifecycle を延長、最小限のコピーに削減 |

---

### 2.5 ✅ Noise NoiseConnection 読み取りバッファの dropFirst コピー — 修正済み

| 項目 | 値 |
|------|-----|
| ファイル | `Sources/Security/Noise/NoiseConnection.swift:22-36` |
| ステータス | ✅ 修正済み — `bufferOffset` トラッキング + 閾値圧縮パターン |

---

### 2.6 GossipSub Protobuf エンコードの複数Data生成

| 項目 | 値 |
|------|-----|
| ファイル | `Sources/Protocols/GossipSub/Wire/GossipSubProtobuf.swift:65-93` |
| 影響 | 全メッセージ送信時 |

各フィールドのエンコードで新規Dataオブジェクトを生成し、appendを繰り返している。事前容量確保またはバッファプールを使うべき。

---

### 2.7 ✅ PeerID.description の繰り返しBase58エンコード — 修正済み

| 項目 | 値 |
|------|-----|
| ファイル | `Sources/Core/P2PCore/Identity/PeerID.swift:20,106` |
| ステータス | ✅ 修正済み — `_description` プロパティでinit時にキャッシュ |

---

### 2.8 AddressBook スコアリングの非同期ループ

| 項目 | 値 |
|------|-----|
| ファイル | `Sources/Discovery/P2PDiscovery/AddressBook.swift:191-205` |
| 影響 | アドレス毎に個別のMutexロック取得 |

```swift
for address in addresses {
    let addressScore = await score(address: address, for: peer)  // 毎回ロック
    scoredAddresses.append((address, addressScore))
}
```

バッチ取得に変更し、ロック回数を1回にすべき。

---

### 2.9 ✅ CYCLON evictIfNeeded の O(n²) 削除 — 修正済み

| 項目 | 値 |
|------|-----|
| ファイル | `Sources/Discovery/CYCLON/CYCLONPartialView.swift` |
| ステータス | ✅ 修正済み — 単一ソートベースの削除に変更 |

---

### 2.10 ✅ ProtoBook プロトコル検索の逆引きインデックス欠落 — 修正済み

| 項目 | 値 |
|------|-----|
| ファイル | `Sources/Discovery/P2PDiscovery/MemoryProtoBook.swift:21` |
| ステータス | ✅ 修正済み — `protocolPeers: [String: Set<PeerID>]` 逆引きインデックス追加 |

---

### 2.11 ✅ ConnectionPool.connectedPeers のネスト走査 — 修正済み

| 項目 | 値 |
|------|-----|
| ファイル | `Sources/Integration/P2P/Connection/ConnectionPool.swift:112` |
| ステータス | ✅ 修正済み — `connectedPeerCache: Set<PeerID>` で接続/切断時に更新 |

---

### 2.12 ✅ SeenCache の重複データ構造 — 修正済み

| 項目 | 値 |
|------|-----|
| ファイル | `Sources/Protocols/GossipSub/Router/MessageCache.swift` |
| ステータス | ✅ 修正済み — `LRUOrder<MessageID>` で統合 |

---

### 2.13 EventBroadcaster.emit の配列コピー

| 項目 | 値 |
|------|-----|
| ファイル | `Sources/Core/P2PCore/Lifecycle/EventBroadcaster.swift:79-84` |
| 影響 | 全イベント発行時にcontinuation配列をコピー |

```swift
let conts = state.withLock { Array($0.continuations.values) }
```

事前確保配列の再利用、またはRWLockの検討。

---

### 2.14 ✅ HexEncoding の文字列コピー — 修正済み

| 項目 | 値 |
|------|-----|
| ファイル | `Sources/Core/P2PCore/Utilities/HexEncoding.swift` |
| ステータス | ✅ 修正済み — UTF-8 バイトレベル処理に変更 |

---

## 3. 重大度LOW: 将来的な改善候補

### 3.1 TCPソケットバッファサイズ未チューニング

| 項目 | 値 |
|------|-----|
| ファイル | `Sources/Transport/TCP/TCPTransport.swift`, `TCPListener.swift` |
| 内容 | `SO_SNDBUF` / `SO_RCVBUF` がデフォルト値 |

高帯域・高レイテンシ環境では256KBなど明示的な設定が有効。

---

### 3.2 TCP/WebSocket バッファサイズのハードコード

| 項目 | 値 |
|------|-----|
| ファイル | `Sources/Transport/TCP/TCPConnection.swift:13`, `Sources/Transport/WebSocket/WebSocketConnection.swift:14` |
| 内容 | 1MB固定、設定不可 |

設定可能にし、用途に応じて調整できるようにすべき。

---

### 3.3 WebRTC UDP バックプレッシャーなし

| 項目 | 値 |
|------|-----|
| ファイル | `Sources/Transport/WebRTC/WebRTCUDPSocket.swift:90` |
| 内容 | `writeAndFlush(envelope, promise: nil)` — fire-and-forget |

高負荷時のデータ損失につながる。送信キュー深度のメトリクス追加を検討すべき。

---

### 3.4 Yamux フレームヘッダの個別バイト追加

| 項目 | 値 |
|------|-----|
| ファイル | `Sources/Mux/Yamux/YamuxFrame.swift:87-117` |
| 内容 | 12回の `append(UInt8)` 呼び出し |

12バイトのヘッダ配列を一括追加に変更可能。

---

### 3.5 Yamux ストリーム ウィンドウ待機のTaskGroup生成

| 項目 | 値 |
|------|-----|
| ファイル | `Sources/Mux/Yamux/YamuxStream.swift:169-203` |
| 内容 | ゼロウィンドウ時に毎回TaskGroup + 2子タスク生成 |

タイムアウトの仕組みを単純化すべき。

---

### 3.6 LazyPushBuffer のグローバルサイズ制限なし

| 項目 | 値 |
|------|-----|
| ファイル | `Sources/Protocols/Plumtree/LazyPushBuffer.swift:36-56` |
| 内容 | ピア毎制限のみ。1000ピアでグローバル制限なし |

グローバルサイズ上限とLRU/FIFO退避ポリシーを追加すべき。

---

### 3.7 Envelope marshal の複数中間Data生成

| 項目 | 値 |
|------|-----|
| ファイル | `Sources/Core/P2PCore/Record/Envelope.swift:103-124` |
| 内容 | Varint.encode() の度にData生成 |

事前容量確保の単一バッファで一括エンコードすべき。

---

### 3.8 Protocol Negotiation のループ内String生成

| 項目 | 値 |
|------|-----|
| ファイル | `Sources/Negotiation/P2PNegotiation/P2PNegotiation.swift:200-207` |
| 内容 | プロトコル毎に `(proto + "\n").utf8` でData生成 |

バッファへの直接書き込みに変更可能。

---

### 3.9 Mplex フレームデコードのDataスライスコピー

| 項目 | 値 |
|------|-----|
| ファイル | `Sources/Mux/Mplex/MplexFrame.swift:177` |
| 内容 | `Data(buffer[dataStart..<dataStart + Int(length)])` でコピー |

参照スライスまたはオフセットベースのデコードに変更可能。

---

### 3.10 MultiaddrProtocol IPv4/IPv6 デコードのString生成

| 項目 | 値 |
|------|-----|
| ファイル | `Sources/Core/P2PCore/Addressing/MultiaddrProtocol.swift:244,249` |
| 内容 | バイト毎にString生成 → joined |

直接的なバイト→文字列フォーマットに変更可能。

---

## 4. 最適化済み（問題なし）

以下の領域は適切に最適化されている:

| 領域 | ファイル | 内容 |
|------|---------|------|
| LengthPrefixedFraming | `LengthPrefixedFraming.swift` | `reserveCapacity()` 使用済み |
| ProtobufLite | `ProtobufLite.swift` | 効率的なフィールドエンコード |
| DefaultResourceManager | `DefaultResourceManager.swift` | アトミックなマルチスコープチェック |
| ConnectionPool.cleanupStaleEntries | `ConnectionPool.swift` | 2パス走査（必要な設計） |
| Yamux readBuffer compaction | `YamuxConnection.swift` | オフセットトラッキング + 閾値圧縮 |
| TCPConnection ロック外continuation resume | `TCPConnection.swift` | ロック外でcontinuationをresume |
| EventBroadcaster ロック外emit | `EventBroadcaster.swift` | ロック外でyield |
| PlumtreeProtobuf varint | `PlumtreeProtobuf.swift:48-54` | `@inline(__always)` 使用 |

---

## 5. 全体サマリ

### 重大度別集計 (2026-02-06 更新)

| 重大度 | 総数 | ✅ 修正済み | ⬜ 未修正 |
|--------|------|-----------|----------|
| HIGH | 8件 | 6件 | 2件 |
| MEDIUM | 14件 | 10件 | 4件 |
| LOW | 10件 | 0件 | 10件 |

### 未修正項目一覧

**HIGH (2件)**:
1. **1.7 Noise HKDF** — `SymmetricKey` ↔ `Data` の不要な中間変換
2. **1.8 HealthMonitor** — ピアごとの個別Task生成（バッチ化が必要）

**MEDIUM (4件)**:
1. **2.1 MessageCache.getGossipIDs** — トピック別インデックス欠如
2. **2.6 GossipSub Protobuf** — 内部エンコーダの capacity ヒントなし
3. **2.8 AddressBook** — アドレスごとの個別ロック取得
4. **2.13 EventBroadcaster.emit** — continuation配列の毎回コピー

### 推奨対応順序

1. **HealthMonitor** — バッチ監視に変更（スケーラビリティ影響大）
2. **Noise HKDF** — 中間Data変換の排除
3. **EventBroadcaster.emit** — 配列コピー回避
4. **AddressBook** — バッチスコアリング
5. **GossipSub Protobuf** — capacity ヒント追加
6. **MessageCache** — トピック別インデックス追加
