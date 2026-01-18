# P2PAutoNAT

AutoNAT protocol implementation for detecting NAT status.

## Overview

AutoNAT allows a node to determine if it is publicly reachable or behind a Network Address Translation (NAT) device by requesting other peers to dial its addresses. This helps the node behave correctly in the network by not advertising undialable addresses and potentially seeking a relay server for connectivity.

## Protocol IDs

- **AutoNAT v1**: `/libp2p/autonat/1.0.0` - Single protocol for dial requests

## Dependencies

- `P2PCore` - PeerID, Multiaddr, Varint
- `P2PMux` - MuxedStream
- `P2PProtocols` - ProtocolService, StreamOpener, HandlerRegistry

## Files

| File | Responsibility |
|------|---------------|
| `AutoNATProtocol.swift` | Protocol constants and defaults |
| `AutoNATError.swift` | Error types and status codes |
| `AutoNATMessages.swift` | Message types (Dial, DialResponse) |
| `AutoNATProtobuf.swift` | Protobuf encoding/decoding |
| `AutoNATService.swift` | Main service (client + server combined) |
| `NATStatus.swift` | NAT status type with confidence |
| `AutoNATEvent.swift` | Event types |

## Wire Protocol

### Message Format

Messages are protobuf-encoded and length-prefixed.

```protobuf
message Message {
  enum MessageType {
    DIAL = 0;
    DIAL_RESPONSE = 1;
  }

  message PeerInfo {
    optional bytes id = 1;
    repeated bytes addrs = 2;
  }

  message Dial {
    optional PeerInfo peer = 1;
  }

  message DialResponse {
    enum ResponseStatus {
      OK = 0;
      E_DIAL_ERROR = 100;
      E_DIAL_REFUSED = 101;
      E_BAD_REQUEST = 200;
      E_INTERNAL_ERROR = 300;
    }
    optional ResponseStatus status = 1;
    optional string statusText = 2;
    optional bytes addr = 3;
  }

  optional MessageType type = 1;
  optional Dial dial = 2;
  optional DialResponse dialResponse = 3;
}
```

## Flow

### Client → Server

```
Client                          Server
   |                               |
   |-- open stream --------------->|
   |-- DIAL (PeerInfo) ----------->|
   |                               | (attempt dial-back)
   |<-- DIAL_RESPONSE -------------|
   |-- close stream ---------------|
```

### NAT Detection Algorithm

1. Client sends DIAL requests to multiple peers (minimum 3 recommended)
2. Each server attempts to dial the client's addresses
3. Client collects responses:
   - If >3 peers report OK → assume **Public** (reachable)
   - If >3 peers report E_DIAL_ERROR → assume **Private** (behind NAT)
   - Otherwise → **Unknown**
4. Confidence increases with more consistent responses

## NATStatus

```swift
public enum NATStatus: Sendable, Equatable {
    /// NAT status is unknown (not enough probes yet)
    case unknown

    /// Node is publicly reachable at the given address
    case publicReachable(Multiaddr)

    /// Node is behind NAT (not directly reachable)
    case privateBehindNAT
}
```

## Configuration

```swift
public struct AutoNATConfiguration: Sendable {
    /// Minimum number of successful probes to determine status
    public var minProbes: Int = 3

    /// Interval between probe attempts when status is unknown
    public var retryInterval: Duration = .seconds(60)

    /// Interval between probe attempts when status is known
    public var refreshInterval: Duration = .seconds(3600)

    /// Timeout for dial-back attempts
    public var dialTimeout: Duration = .seconds(30)

    /// Maximum addresses to include in DIAL request
    public var maxAddresses: Int = 16

    /// Function to get local addresses
    public var getLocalAddresses: @Sendable () -> [Multiaddr]

    /// Dialer function for server-side dial-back
    public var dialer: (@Sendable (Multiaddr) async throws -> Void)?
}
```

## Usage

### Combined Service

```swift
let autonat = AutoNATService(configuration: .init(
    getLocalAddresses: { node.listenAddresses },
    dialer: { addr in try await node.connect(to: addr) }
))
await autonat.registerHandler(registry: node)

// Manually trigger a probe
let status = try await autonat.probe(using: node, servers: [peer1, peer2, peer3])

// Get current status
let currentStatus = autonat.status

// Listen for status changes
for await event in autonat.events {
    switch event {
    case .statusChanged(let newStatus):
        print("NAT status: \(newStatus)")
    case .probeCompleted(let peer, let result):
        print("Probe to \(peer): \(result)")
    }
}
```

## Integration with DCUtR

AutoNAT integrates with DCUtR for NAT traversal:

1. AutoNAT detects node is behind NAT (`privateBehindNAT`)
2. Node makes reservation on relay (Circuit Relay)
3. When connecting to another NAT'd peer, DCUtR attempts hole punching
4. If hole punch fails, communication continues over relay

## Amplification Attack Prevention

To prevent amplification attacks, the server MUST:
1. Only dial addresses whose IP matches the observed IP of the requesting client
2. Limit the rate of dial-back attempts per peer
3. Refuse requests from unknown peers (optionally require prior connection)

## Test Strategy

1. **Unit tests**: Protobuf encoding/decoding, status determination logic
2. **Integration tests**: Two-node setup using MemoryTransport
3. **Interop tests**: Connect to rust-libp2p/go-libp2p nodes

## 既知の制限事項

### NATステータス判定
- 最小3プローブ必要、不安定なネットワークでは判定遅延
- ステータス変化時の自動アドレス更新なし

### 増幅攻撃対策
- IPアドレス検証は実装されているが、レート制限の設定が固定

### サーバー動作
- ダイアルバックは同期的（並列ダイアルなし）
- ダイアルバック結果のキャッシュなし

## 品質向上TODO

### 高優先度
- [ ] **AutoNATServiceテストの追加** - クライアント/サーバー両側テスト
- [ ] **Protobufエンコードテスト** - Dial/DialResponseラウンドトリップ
- [ ] **NATステータス判定テスト** - 各ステータスへの遷移検証

### 中優先度
- [ ] **増幅攻撃対策テスト** - IPアドレス検証、レート制限の検証
- [ ] **設定可能なレート制限** - ピアあたり、グローバルの制限設定
- [ ] **ダイアルバック結果キャッシュ** - 同一ピアへの重複ダイアル防止

### 低優先度
- [ ] **AutoNAT v2対応** - より効率的なプロトコル（将来仕様）
- [ ] **自動アドレス広告** - NATステータス変化時のIdentify Push連携
- [ ] **並列ダイアルバック** - サーバー側の複数アドレス同時検証

## References

- [AutoNAT v1 Spec](https://github.com/libp2p/specs/blob/master/autonat/README.md)
- [rust-libp2p autonat](https://github.com/libp2p/rust-libp2p/tree/master/protocols/autonat)

## Codex Review (2026-01-18)

### Warning
| Issue | Location | Description |
|-------|----------|-------------|
| IPv6 normalization incorrect | `AutoNATService.swift:393-445` | `::` expansion uses `emptyIndex` from pre-filtered array; can miscompare addresses and refuse valid dial-backs |
