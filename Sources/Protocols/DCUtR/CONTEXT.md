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
- [ ] **DCUtRServiceテストの追加** - CONNECT/SYNCフロー検証
- [ ] **Protobufエンコードテスト** - HolePunchメッセージラウンドトリップ
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

## Codex Review (2026-01-18)

### Warning
| Issue | Location | Description |
|-------|----------|-------------|
| Reads have no timeout | `DCUtRService.swift:136-180` | CONNECT/SYNC reads have no timeout; can hang indefinitely |
| maxAttempts not enforced | `DCUtRService.swift:266-276` | `maxAttempts` configuration exists but retry logic not implemented |
