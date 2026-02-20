# P2PCircuitRelay

Circuit Relay v2 implementation for NAT traversal.

## Overview

Circuit Relay v2 enables peers behind NATs to communicate through public relay nodes. A peer can make a **reservation** on a relay to receive incoming connections, and other peers can **connect through** the relay to reach the reserved peer.

## Protocol IDs

- **Hop**: `/libp2p/circuit/relay/0.2.0/hop` - Client ↔ Relay communication
- **Stop**: `/libp2p/circuit/relay/0.2.0/stop` - Relay → Target notification

## Dependencies

- `P2PCore` - PeerID, Multiaddr, Varint
- `P2PMux` - MuxedStream
- `P2PProtocols` - ProtocolService, StreamOpener, HandlerRegistry
- `P2PTransport` - Transport protocol, Listener

## Files

| File | Responsibility |
|------|---------------|
| `CircuitRelayProtocol.swift` | Protocol constants and defaults |
| `CircuitRelayError.swift` | Error types and status codes |
| `CircuitRelayMessages.swift` | HopMessage, StopMessage types |
| `CircuitRelayProtobuf.swift` | Protobuf encoding/decoding |
| `Reservation.swift` | Reservation type |
| `Limit.swift` | CircuitLimit type |
| `RelayClient.swift` | Client-side relay functionality |
| `RelayServer.swift` | Server-side relay functionality |
| `RelayedConnection.swift` | Relayed connection wrapper |
| `CircuitRelayEvent.swift` | Event types |
| `Transport/RelayTransport.swift` | Transport implementation for /p2p-circuit addresses |
| `Transport/RelayListener.swift` | Listener for incoming relayed connections |

## Wire Protocol

### Hop Protocol (Client ↔ Relay)

Messages are protobuf-encoded and length-prefixed.

```
HopMessage {
    type: enum { RESERVE=0, CONNECT=1, STATUS=2 }
    peer: Peer (for CONNECT)
    reservation: Reservation (in STATUS response)
    limit: Limit
    status: Status
}
```

### Stop Protocol (Relay → Target)

```
StopMessage {
    type: enum { CONNECT=0, STATUS=1 }
    peer: Peer (source peer in CONNECT)
    limit: Limit
    status: Status
}
```

## Flows

### Reservation Flow

```
Client                          Relay
   |                              |
   |-- RESERVE ------------------>|
   |                              | (check limits)
   |<-- STATUS OK + reservation --|
   |                              |
```

### Connection Flow

```
Source                 Relay                  Target (reserved)
   |                     |                        |
   |-- CONNECT(target) ->|                        |
   |                     |-- STOP CONNECT ------->|
   |                     |<-- STOP STATUS OK -----|
   |<-- STATUS OK -------|                        |
   |========= data relay ========================>|
```

## Usage

### Client

```swift
let client = RelayClient()
await client.registerHandler(registry: node)

// Make reservation
let reservation = try await client.reserve(on: relayPeer, using: node)

// Connect through relay
let connection = try await client.connectThrough(
    relay: relayPeer,
    to: targetPeer,
    using: node
)
```

### Server

```swift
let server = RelayServer(configuration: .init(
    maxReservations: 128,
    maxCircuitsPerPeer: 16
))
await server.registerHandler(
    registry: node,
    opener: node,
    localPeer: node.peerID,
    getLocalAddresses: { node.listenAddresses }
)
```

## Multiaddr Format

Relayed addresses use the `p2p-circuit` protocol:

```
/ip4/1.2.3.4/tcp/4001/p2p/{relay}/p2p-circuit/p2p/{target}
```

## Test Strategy

1. **Unit tests**: Protobuf encoding/decoding
2. **Integration tests**: Three-node setup (client, relay, peer) using MemoryTransport
3. **Interop tests**: go-libp2p relay との RESERVE/CONNECT/STATUS wire 互換検証（rust は継続中）

## テスト実装状況

| テストファイル | テスト数 | 説明 |
|--------------|---------|------|
| `CircuitRelayIntegrationTests.swift` | 19 | 統合テスト、キャンセル処理、RelayListenerテスト |
| `CircuitRelayE2ETests.swift` | 7 | E2Eテスト、マルチ接続、データ制限 |
| `RelayServerTests.swift` | 19 | イベント発行、予約管理、サーキット制限、エラーシナリオ |
| `RelayTransportTests.swift` | 18 | アドレス解析、RelayListener、RelayedRawConnection |

**合計: 72テスト** (2026-01-23時点)

## 既知の制限事項

### リレーサーバー
- リレーサーバーのリソース制限は設定可能だが動的調整なし
- 帯域制限は接続単位のみ（ピア単位の総帯域制限なし）

### 接続ラッピング
- `RelayedConnection`はストリーム多重化なし（単一ストリームのみ）

## 品質向上TODO

### 高優先度
- [x] **RelayClientテストの追加** - 予約フロー、接続フローテスト ✅ 2026-01-23
- [x] **RelayServerテストの追加** - 制限チェック、拒否ケーステスト ✅ 2026-01-23
- [x] **Protobufエンコードテスト** - HopMessage/StopMessageラウンドトリップ ✅ 2026-01-23
- [~] **Go/Rust相互運用テスト** - go-libp2p は基本往復（RESERVE/CONNECT）実装済み、rust-libp2p は継続中 ✅/⏳ (2026-02-14)

### 中優先度
- [x] **予約自動更新** - `autoRenewReservations=true`（デフォルト）、`scheduleRenewalOrExpiration()`/`renewReservation()` 実装済み ✅
- [x] **予約失効イベント** - `reservationExpired`/`reservationRenewed`/`reservationRenewalFailed` イベント実装済み ✅
- [ ] **StatusCode詳細処理** - 各エラーステータスの適切な処理

### 低優先度
- [ ] **リレーサーバー統計** - 接続数、帯域使用量の計測
- [ ] **動的リソース制限** - 負荷に応じた制限調整

## References

- [Circuit Relay v2 Spec](https://github.com/libp2p/specs/blob/master/relay/circuit-v2.md)
- [rust-libp2p relay](https://github.com/libp2p/rust-libp2p/tree/master/protocols/relay)

## Codex Review (2026-01-18) - UPDATED 2026-01-22

### Warning (RESOLVED)
| Issue | Location | Description | Status |
|-------|----------|-------------|--------|
| RelayListener receives connections via Listener Registry | `RelayClient.swift:463-489` | handleStop() routes to registered listener via enqueue(). RelayListener.init() calls registerListener(), and handleStop() calls listener.enqueue() for direct delivery. | ✅ Fixed |

**Resolution Details:**
1. `RelayListener.init()` (L72) registers itself: `client.registerListener(self, for: relay)`
2. `RelayClient.handleStop()` (L463-489) routes to listener: `listener.enqueue(connection)`
3. `RelayListener.enqueue()` (L154-183) delivers to waiting continuation or queues

### Info
| Issue | Location | Description |
|-------|----------|-------------|
| Data limits coarse-grained | `RelayServer.swift:452-503` | Limits enforced in 8KB batches; small limits can be overshot |

<!-- CONTEXT_EVAL_START -->
## 実装評価 (2026-02-16)

- 総合評価: **A** (92/100)
- 対象ターゲット: `P2PCircuitRelay`
- 実装読解範囲: 13 Swift files / 3459 LOC
- テスト範囲: 28 files / 173 cases / targets 2
- 公開API: types 26 / funcs 22
- 参照網羅率: type 0.77 / func 0.95
- 未参照公開型: 6 件（例: `AutoRelayReachability`, `HopMessageType`, `HopStatus`, `PeerInfo`, `StopMessageType`）
- 実装リスク指標: try?=0, forceUnwrap=0, forceCast=0, @unchecked Sendable=0, EventLoopFuture=0, DispatchQueue=0
- 評価所見: 重大な静的リスクは検出されず

### 重点アクション
- 未参照の公開型に対する直接テスト（生成・失敗系・境界値）を追加する。

※ 参照網羅率は「テストコード内での公開API名参照」を基準にした静的評価であり、動的実行結果そのものではありません。

<!-- CONTEXT_EVAL_END -->
