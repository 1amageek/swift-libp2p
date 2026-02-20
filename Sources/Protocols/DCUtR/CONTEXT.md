# P2PDCUtR

DCUtR (Direct Connection Upgrade through Relay) implementation.

## Overview

DCUtR enables peers to upgrade relayed connections to direct connections via hole punching. After establishing a connection through a Circuit Relay, peers can use DCUtR to coordinate a simultaneous dial attempt that may succeed in establishing a direct connection.

## Protocol ID

`/libp2p/dcutr`

## Dependencies

- `P2PCore` - PeerID, Multiaddr, Varint
- `P2PMux` - MuxedStream
- `P2PProtocols` - ProtocolService, StreamOpener, HandlerRegistry

## Files

| File | Responsibility |
|------|---------------|
| `DCUtRProtocol.swift` | Protocol constants |
| `DCUtRError.swift` | Error types |
| `DCUtRMessages.swift` | CONNECT, SYNC message types |
| `DCUtRProtobuf.swift` | Protobuf encoding/decoding |
| `DCUtRService.swift` | Main service implementation |
| `DCUtREvent.swift` | Event types |

## Wire Protocol

Messages are protobuf-encoded and length-prefixed.

```protobuf
message HolePunch {
    Type type = 1;
    repeated bytes ObsAddrs = 2;
}

enum Type {
    CONNECT = 100;
    SYNC = 300;
}
```

## Hole Punching Flow

```
Peer A (Initiator)           Peer B (via relay)
       |                            |
       |-- CONNECT [addresses] ---->|  (over relayed connection)
       |                            |
       |<-- CONNECT [addresses] ----|
       |                            |
       |-- SYNC ------------------->|  (timed to coordinate)
       |                            |
       |<======= simultaneous dial =======>|
       |                            |
       [Direct connection established]
```

### Timing

1. A sends CONNECT with its observable addresses
2. B responds with CONNECT containing its addresses
3. A measures RTT during exchange
4. A sends SYNC and waits RTT/2
5. Both sides attempt to dial each other simultaneously
6. Simultaneous open creates a direct connection

## Usage

```swift
let dcutr = DCUtRService(configuration: .init(
    timeout: .seconds(30),
    maxAttempts: 3,
    getLocalAddresses: { node.listenAddresses }
))

// Register handler for incoming requests
await dcutr.registerHandler(registry: node)

// Initiate upgrade from relayed to direct
try await dcutr.upgradeToDirectConnection(
    with: remotePeer,
    using: node,
    dialer: { addr in
        try await node.connect(to: addr)
    }
)

// Listen for events
for await event in dcutr.events {
    switch event {
    case .directConnectionEstablished(let peer, let addr):
        print("Direct connection to \(peer) via \(addr)")
    case .holePunchFailed(let peer, let reason):
        print("Hole punch failed for \(peer): \(reason)")
    default:
        break
    }
}
```

## Integration with Circuit Relay

DCUtR works in conjunction with Circuit Relay:

1. Establish relayed connection via `RelayClient`
2. Use DCUtR to attempt upgrade to direct connection
3. If successful, use direct connection and close relay
4. If failed, continue using relayed connection

## 既知の制限事項

### ホールパンチング
- 対称NAT（Symmetric NAT）では成功率が低い
- UPnP/NAT-PMPによるポートマッピングなし

### タイミング
- RTT測定の精度はネットワーク状況に依存
- SYNC後の待機時間は固定（動的調整なし）

### アドレスフィルタリング
- プライベートアドレスのフィルタリングなし
- IPv4/IPv6混在時の優先順位付けなし

## 品質向上TODO

### 高優先度
- [x] **DCUtRServiceテストの追加** - CONNECT/SYNCフロー検証 ✅ (50テスト)
- [x] **Protobufエンコードテスト** - HolePunchメッセージラウンドトリップ ✅
- [ ] **タイミング検証テスト** - RTT測定とSYNC待機の正確性

### 中優先度
- [ ] **ホールパンチ成功率計測** - 成功/失敗統計の収集
- [ ] **アドレスフィルタリング** - プライベート/ループバック除外
- [ ] **IPv6優先対応** - デュアルスタック環境での適切な選択

### 低優先度
- [ ] **UPnP/NAT-PMP統合** - 自動ポートマッピング
- [ ] **適応タイミング** - 過去の成功率に基づくタイミング調整
- [ ] **複数アドレス同時試行** - 並列ダイアルによる成功率向上

## References

- [DCUtR Specification](https://github.com/libp2p/specs/blob/master/relay/DCUtR.md)
- [Circuit Relay v2 Specification](https://github.com/libp2p/specs/blob/master/relay/circuit-v2.md)

## テスト実装状況

| テストスイート | テスト数 | 説明 |
|--------------|---------|------|
| `DCUtRProtocolTests` | 2 | プロトコルID、メッセージサイズ |
| `DCUtRMessageTests` | 3 | CONNECT/SYNCメッセージ型 |
| `DCUtRProtobufTests` | 13 | Protobufエンコード/デコード |
| `DCUtRErrorTests` | 4 | エラー型 |
| `DCUtREventTests` | 6 | イベント型 |
| `DCUtRConfigurationTests` | 2 | 設定 |
| `DCUtRServiceTests` | 9 | サービス初期化、シャットダウン |
| `DCUtRIntegrationTests` | 11 | 統合テスト |

**合計: 50テスト** (2026-01-23時点)

## Codex Review (2026-01-18) - UPDATED 2026-01-23

### Warning
| Issue | Location | Status | Description |
|-------|----------|--------|-------------|
| ~~Reads have no timeout~~ | `DCUtRService.swift:324-338` | ✅ Fixed | `readMessage()` wraps reads with `withTimeout(configuration.timeout)` |
| ~~maxAttempts not enforced~~ | `DCUtRService.swift:146-190` | ✅ Fixed | `upgradeToDirectConnection()` now retries up to `maxAttempts` with exponential backoff |

<!-- CONTEXT_EVAL_START -->
## 実装評価 (2026-02-16)

- 総合評価: **A** (100/100)
- 対象ターゲット: `P2PDCUtR`
- 実装読解範囲: 8 Swift files / 1335 LOC
- テスト範囲: 4 files / 108 cases / targets 1
- 公開API: types 14 / funcs 5
- 参照網羅率: type 1.0 / func 1.0
- 未参照公開型: 0 件（例: `なし`）
- 実装リスク指標: try?=0, forceUnwrap=0, forceCast=0, @unchecked Sendable=0, EventLoopFuture=0, DispatchQueue=0
- 評価所見: 重大な静的リスクは検出されず

### 重点アクション
- 現行のテスト網羅を維持し、機能追加時は同一粒度でテストを増やす。

※ 参照網羅率は「テストコード内での公開API名参照」を基準にした静的評価であり、動的実行結果そのものではありません。

<!-- CONTEXT_EVAL_END -->
