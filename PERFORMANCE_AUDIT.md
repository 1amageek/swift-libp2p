# swift-libp2p パフォーマンス最適化監査レポート

全モジュール (187ファイル) を対象に、パフォーマンス最適化の観点で調査した結果をまとめる。

---

## 目次

1. [重大度HIGH: 即時対応推奨](#1-重大度high-即時対応推奨)
2. [重大度MEDIUM: 改善推奨](#2-重大度medium-改善推奨)
3. [重大度LOW: 将来的な改善候補](#3-重大度low-将来的な改善候補)
4. [最適化済み（問題なし）](#4-最適化済み問題なし)
5. [全体サマリ](#5-全体サマリ)

---

## 1. 重大度HIGH: 即時対応推奨

### 1.1 TCP_NODELAY 未設定

| 項目 | 値 |
|------|-----|
| ファイル | `Sources/Transport/TCP/TCPTransport.swift:51` |
| 影響 | 全TCP通信に40ms以上の遅延 (Nagle's Algorithm) |
| 修正コスト | 1行追加 |

Nagle's Algorithmが有効のため、小さなパケットがバッファリングされ遅延する。p2pプロトコルは小さなメッセージを頻繁に送るため影響が大きい。

```swift
// 現状: SO_REUSEADDR のみ
.channelOption(.socketOption(.so_reuseaddr), value: 1)

// 追加すべき設定
.channelOption(.socketOption(.tcp_nodelay), value: 1)
.channelOption(.socketOption(.so_keepalive), value: 1)
```

`TCPListener.swift:54,61` にも同様の設定追加が必要。

---

### 1.2 Base58デコードの O(n²) 計算量

| 項目 | 値 |
|------|-----|
| ファイル | `Sources/Core/P2PCore/Utilities/Base58.swift:85-104` |
| 影響 | PeerIDの生成・パース時に毎回発生 |
| 原因 | `insert(at: 0)` による配列先頭挿入 |

```swift
// 現状: O(n²) — 先頭挿入のたびに全要素シフト
for byte in bytes.reversed() {
    let product = UInt(byte) * base + carry
    newBytes.insert(UInt8(product & 0xFF), at: 0)  // O(n)
    carry = product >> 8
}

// 改善案: append + reverse で O(n)
for byte in bytes.reversed() {
    let product = UInt(byte) * base + carry
    newBytes.append(UInt8(product & 0xFF))  // O(1)
    carry = product >> 8
}
newBytes.reverse()
```

---

### 1.3 Multiaddr.bytes の O(n²) Data結合

| 項目 | 値 |
|------|-----|
| ファイル | `Sources/Core/P2PCore/Addressing/Multiaddr.swift:128` |
| 影響 | Multiaddrのシリアライズ時に毎回発生 |
| 原因 | `reduce` + `+` 演算子が中間Dataオブジェクトを生成 |

```swift
// 現状: 中間Dataが N-1 個生成される
public var bytes: Data {
    protocols.reduce(Data()) { $0 + $1.bytes }
}

// 改善案: 事前容量確保 + append
public var bytes: Data {
    var result = Data()
    result.reserveCapacity(protocols.reduce(0) { $0 + $1.bytes.count })
    for proto in protocols {
        result.append(contentsOf: proto.bytes)
    }
    return result
}
```

---

### 1.4 RoutingTable.closestPeers の全エントリソート

| 項目 | 値 |
|------|-----|
| ファイル | `Sources/Protocols/Kademlia/RoutingTable.swift:120-142` |
| 影響 | Kademliaクエリの度に呼ばれるホットパス |
| 現在の計算量 | O(n log n) (全エントリ収集 + ソート) |
| 改善後の計算量 | O(n log k) (部分ソート / k-way merge) |

```swift
// 現状: 全バケットの全エントリを収集→ソート
var allEntries: [KBucketEntry] = []
for bucket in buckets {
    allEntries.append(contentsOf: bucket.allEntries)  // 最大5120エントリ
}
let sorted = filtered.sorted { ... }  // O(n log n)
return Array(sorted.prefix(count))
```

K=20個だけ必要なのに全エントリをソートしている。バケット構造を活用し、ターゲットに最も近いバケットから順に取得するk-way mergeに変更すべき。

---

### 1.5 PeerStore LRU 管理の O(n) touchPeer

| 項目 | 値 |
|------|-----|
| ファイル | `Sources/Discovery/P2PDiscovery/PeerStore.swift:491-494` |
| 影響 | ピアへの全アクセスで発生 (`addresses(for:)`, `addAddresses`, `recordSuccess`) |
| 原因 | `Array.firstIndex(of:)` が O(n) |

```swift
// 現状: O(n) 線形探索
private func touchPeer(_ peer: PeerID, state s: inout State) {
    if let index = s.accessOrder.firstIndex(of: peer) {
        s.accessOrder.remove(at: index)  // O(n)
        s.accessOrder.append(peer)
    }
}
```

1000ピアで毎回O(1000)。`OrderedSet` または二重連結リストで O(1) にできる。

---

### 1.6 CompositeDiscovery の逐次サービス問い合わせ

| 項目 | 値 |
|------|-----|
| ファイル | `Sources/Discovery/P2PDiscovery/CompositeDiscovery.swift:125-149` |
| 影響 | ピア探索レイテンシが全サービスの合計になる |
| 原因 | `for (service, weight) in services` が逐次実行 |

```swift
// 現状: T1 + T2 + T3 (逐次)
for (service, weight) in services {
    let candidates = try await service.find(peer: peer)
    // ...
}

// 改善案: max(T1, T2, T3) (並列)
try await withThrowingTaskGroup(of: ...) { group in
    for (service, weight) in services {
        group.addTask { try await service.find(peer: peer) }
    }
}
```

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

### 2.2 MeshState.allMeshPeers のキャッシュなし再計算

| 項目 | 値 |
|------|-----|
| ファイル | `Sources/Protocols/GossipSub/Router/MeshState.swift:170-178` |
| 影響 | 呼び出し毎に全トピックのSet unionを再計算 |

結果をキャッシュし、メッシュ変更時のみ無効化すべき。

---

### 2.3 Yamux/Mplex バッファスライス生成

| 項目 | 値 |
|------|-----|
| ファイル | `Sources/Mux/Yamux/YamuxConnection.swift:50-51,289` |
| 同様 | `Sources/Mux/Mplex/MplexConnection.swift:261` |
| 影響 | フレーム処理ループの毎反復でDataスライスを生成 |

`unprocessedBuffer` プロパティアクセスの度に `readBuffer[readBufferOffset...]` でDataスライスを生成している。デコード関数にオフセットを直接渡す設計に変更すべき。

---

### 2.4 TCP/WebSocket 読み取りパスの不要なデータコピー

| 項目 | 値 |
|------|-----|
| ファイル | `Sources/Transport/TCP/TCPConnection.swift:73-78,342-360` |
| 同様 | `Sources/Transport/WebSocket/WebSocketConnection.swift:50-56` |
| 影響 | 受信パケット毎に ByteBuffer → [UInt8] → Data の変換チェーン |

NIOの `ByteBuffer` をできるだけ長く保持し、`Data` への変換を遅延させるべき。

---

### 2.5 Noise NoiseConnection 読み取りバッファの dropFirst コピー

| 項目 | 値 |
|------|-----|
| ファイル | `Sources/Security/Noise/NoiseConnection.swift:84` |
| 影響 | フレーム読み取り毎にバッファ全体をコピー |

```swift
state.buffer = Data(state.buffer.dropFirst(consumed))  // バッファ全体のコピー
```

Yamuxのようにオフセットトラッキングに変更すべき。

---

### 2.6 GossipSub Protobuf エンコードの複数Data生成

| 項目 | 値 |
|------|-----|
| ファイル | `Sources/Protocols/GossipSub/Wire/GossipSubProtobuf.swift:65-93` |
| 影響 | 全メッセージ送信時 |

各フィールドのエンコードで新規Dataオブジェクトを生成し、appendを繰り返している。事前容量確保またはバッファプールを使うべき。

---

### 2.7 PeerID.description の繰り返しBase58エンコード

| 項目 | 値 |
|------|-----|
| ファイル | `Sources/Core/P2PCore/Identity/PeerID.swift:98-108` |
| 影響 | ログ出力・シリアライズの度に発生 |

```swift
public var description: String { bytes.base58EncodedString }  // 毎回計算
```

Lazy cached propertyで初回のみ計算にすべき。

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

### 2.9 CYCLON evictIfNeeded の O(n²) 削除

| 項目 | 値 |
|------|-----|
| ファイル | `Sources/Discovery/CYCLON/CYCLONPartialView.swift:140-147` |
| 影響 | 大量マージ時のみ |
| 計算量 | O(n²) (whileループ × max(by:)) |

```swift
while s.entries.count > cacheSize {
    if let oldest = s.entries.values.max(by: { $0.age < $1.age }) {  // O(n)
        s.entries.removeValue(forKey: oldest.peerID)
    }
}
```

ヒープ構造またはage順インデックスに変更すべき。

---

### 2.10 ProtoBook プロトコル検索の逆引きインデックス欠落

| 項目 | 値 |
|------|-----|
| ファイル | `Sources/Discovery/P2PDiscovery/MemoryProtoBook.swift:70-73` |
| 影響 | プロトコル探索時に全ピアを走査 |

```swift
func peers(supporting protocolID: String) async -> [PeerID] {
    state.withLock { s in
        s.protocols.compactMap { $0.value.contains(protocolID) ? $0.key : nil }  // O(n)
    }
}
```

`[String: Set<PeerID>]` の逆引きインデックスで O(1) にできる。

---

### 2.11 ConnectionPool.connectedPeers のネスト走査

| 項目 | 値 |
|------|-----|
| ファイル | `Sources/Integration/P2P/Connection/ConnectionPool.swift:356-363` |
| 影響 | 統計取得時 |
| 計算量 | O(P × C) (ピア数 × ピア毎コネクション数) |

接続中ピアのキャッシュSetを持ち、接続/切断時に更新する方式に変更すべき。

---

### 2.12 SeenCache の重複データ構造

| 項目 | 値 |
|------|-----|
| ファイル | `Sources/Protocols/GossipSub/Router/MessageCache.swift:186-189` |
| 影響 | メッセージ重複排除でメモリ2倍使用 |

DictionaryとArrayの両方でMessageIDを保持している。`OrderedDictionary` または `LinkedHashMap` 相当に統合すべき。

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

### 2.14 HexEncoding の文字列コピー

| 項目 | 値 |
|------|-----|
| ファイル | `Sources/Core/P2PCore/Utilities/HexEncoding.swift:11,16` |
| 影響 | Hexデコード毎にString lowercased() のコピー |

UTF-8バイト配列で直接処理し、Stringオブジェクトの生成を避けるべき。

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

### 重大度別集計

| 重大度 | 件数 | 対象 |
|--------|------|------|
| HIGH | 8件 | TCP_NODELAY, Base58 O(n²), Multiaddr O(n²), RoutingTable sort, PeerStore LRU, CompositeDiscovery sequential, Noise HKDF, HealthMonitor per-peer task |
| MEDIUM | 14件 | MessageCache, MeshState, Mux buffer slicing, TCP data copy, Noise buffer, GossipSub protobuf, PeerID caching, AddressBook scoring, CYCLON eviction, ProtoBook index, ConnectionPool, SeenCache, EventBroadcaster, HexEncoding |
| LOW | 10件 | Socket buffers, hardcoded limits, WebRTC backpressure, Yamux frame header, Yamux window wait, LazyPushBuffer, Envelope marshal, Negotiation string, Mplex decode, Multiaddr IP |

### モジュール別集計

| モジュール | HIGH | MEDIUM | LOW |
|-----------|------|--------|-----|
| Transport (TCP/WS/WebRTC) | 1 | 2 | 3 |
| Core (PeerID/Multiaddr/Utilities) | 2 | 3 | 2 |
| Protocols (Kademlia/GossipSub/Plumtree) | 1 | 3 | 1 |
| Discovery (PeerStore/CYCLON/Composite) | 2 | 3 | 0 |
| Security (Noise/TLS) | 1 | 1 | 0 |
| Mux (Yamux/Mplex) | 0 | 1 | 3 |
| Integration (ConnectionPool/Health) | 1 | 1 | 0 |
| Negotiation | 0 | 0 | 1 |

### 推奨対応順序

1. **TCP_NODELAY追加** — 1行の変更で全TCP通信のレイテンシ改善
2. **Base58デコード O(n²) → O(n)** — append+reverseパターンに変更
3. **Multiaddr.bytes O(n²) → O(n)** — reserveCapacity+appendに変更
4. **RoutingTable.closestPeers** — k-way mergeまたは部分ソートに変更
5. **PeerStore LRU** — OrderedSetまたは連結リストに変更
6. **CompositeDiscovery** — TaskGroupによる並列化
7. **Noise HKDF** — 中間Data変換の排除
8. **HealthMonitor** — バッチ監視に変更
