# P2PAutoNAT

AutoNAT protocol implementation for detecting NAT status.

## Overview

AutoNAT allows a node to determine if it is publicly reachable or behind a Network Address Translation (NAT) device by requesting other peers to dial its addresses. This helps the node behave correctly in the network by not advertising undialable addresses and potentially seeking a relay server for connectivity.

## Protocol IDs

- **AutoNAT v1**: `/libp2p/autonat/1.0.0` - Single protocol for dial requests
- **AutoNAT v2**: `/libp2p/autonat/2/dial-request` - Nonce-based reachability verification
- **AutoNAT v2 dial-back**: `/libp2p/autonat/2/dial-back` - Dial-back nonce exchange

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
| `AutoNATv2Service.swift` | AutoNAT v2 main service (EventEmitting, nonce management, rate limiting) |
| `AutoNATv2Messages.swift` | AutoNAT v2 message types and wire format codec |
| `AutoNATv2Handler.swift` | AutoNAT v2 stream handler (client + server) |
| `AutoNATv2Error.swift` | AutoNAT v2 error types |

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

## AutoNAT v2 Wire Protocol

### Message Format

Messages are protobuf-style encoded and length-prefixed.

```
Message {
  MessageType type = 1;          // 0=DialRequest, 1=DialResponse, 2=DialBack
  DialRequest dialRequest = 2;   // if type == 0
  DialResponse dialResponse = 3; // if type == 1
  DialBack dialBack = 4;         // if type == 2
}

DialRequest {
  bytes address = 1;    // Multiaddr bytes
  fixed64 nonce = 2;    // Random nonce for verification (8 bytes LE)
}

DialResponse {
  uint32 status = 1;    // DialStatus (0=ok, 100=dialError, 101=dialBackError, ...)
  bytes address = 2;    // Checked address (optional)
}

DialBack {
  fixed64 nonce = 1;    // Nonce from original request (8 bytes LE)
}
```

### AutoNAT v2 Flow

```
Client                           Server
   |                                |
   |-- open stream (v2) ----------->|
   |-- DialRequest(addr, nonce) --->|
   |                                | (dial addr)
   |                                | (send nonce via dial-back)
   |<-- DialResponse(status) -------|
   |-- close stream ----------------|
```

### AutoNAT v2 Improvements over v1

- **Nonce-based verification**: Proves server actually connected to address
- **Address-specific**: Check individual addresses instead of all at once
- **Rate limiting**: Per-server cooldown (default 30s) prevents amplification

## AutoNAT v1 Flow

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

    /// Timeout for dial-back attempts
    public var dialTimeout: Duration = .seconds(30)

    /// Maximum addresses to include in DIAL request
    public var maxAddresses: Int = 16

    /// Function to get local addresses
    public var getLocalAddresses: @Sendable () -> [Multiaddr]

    /// Dialer function for server-side dial-back
    public var dialer: (@Sendable (Multiaddr) async throws -> Void)?

    // --- Rate Limiting (NEW 2026-01-23) ---

    /// Maximum requests per peer within the rate limit window (default: 10)
    public var maxRequestsPerPeer: Int = 10

    /// Rate limit time window (default: 60 seconds)
    public var rateLimitWindow: Duration = .seconds(60)

    /// Maximum concurrent dial-back operations per peer (default: 3)
    public var maxConcurrentDialsPerPeer: Int = 3

    /// Maximum concurrent dial-back operations globally (default: 50)
    public var maxConcurrentDialsGlobal: Int = 50

    /// Maximum total requests globally within the rate limit window (default: 500)
    public var maxGlobalRequests: Int = 500

    /// Backoff duration after rate limit is exceeded (default: 30 seconds)
    public var rateLimitBackoff: Duration = .seconds(30)

    /// Allowed port range for dial-back (nil = all ports allowed)
    public var allowedPortRange: ClosedRange<UInt16>? = nil

    /// Require peer ID in dial request to match the remote peer (default: true)
    public var requirePeerIDMatch: Bool = true
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

### Implementation (2026-01-23)

The following protections are now implemented:

**Rate Limiting**:
- Per-peer request limit within a time window (`maxRequestsPerPeer`, `rateLimitWindow`)
- Per-peer concurrent dial limit (`maxConcurrentDialsPerPeer`)
- Global concurrent dial limit (`maxConcurrentDialsGlobal`)
- Global request limit (`maxGlobalRequests`)
- Backoff period after rate limit exceeded (`rateLimitBackoff`)

**Address Validation**:
- IP address matching (existing)
- Port range filtering (`allowedPortRange`)
- Peer ID validation (`requirePeerIDMatch`)

**Events**:
- `dialRequestRejected(from:reason:)` - Emitted when a request is rejected
- `rateLimitStateChanged(globalConcurrent:globalRequests:)` - For monitoring

**Errors**:
- `rateLimited(RateLimitReason)` - Request was rate limited
- `peerIDMismatch` - Peer ID in request doesn't match remote peer
- `portNotAllowed(UInt16)` - Port not in allowed range

## Test Strategy

1. **Unit tests**: Protobuf encoding/decoding, status determination logic
2. **Integration tests**: Two-node setup using MemoryTransport
3. **Interop tests**: Connect to rust-libp2p/go-libp2p nodes

## 既知の制限事項

### NATステータス判定
- 最小3プローブ必要、不安定なネットワークでは判定遅延
- ステータス変化時の自動アドレス更新なし

### サーバー動作
- ~~ダイアルバックは同期的~~ → `dialBackParallel()` で並列ダイアル実装済み
- ダイアルバック結果のキャッシュなし

## 品質向上TODO

### 高優先度
- [x] **AutoNATServiceテストの追加** - クライアント/サーバー両側テスト ✅ (66テスト)
- [x] **Protobufエンコードテスト** - Dial/DialResponseラウンドトリップ ✅
- [x] **NATステータス判定テスト** - 各ステータスへの遷移検証 ✅
- [x] **増幅攻撃対策** - レート制限、Peer ID検証、ポート制限 ✅ 2026-01-23

### 中優先度
- [x] **設定可能なレート制限** - ピアあたり、グローバルの制限設定 ✅ 2026-01-23
- [ ] **ダイアルバック結果キャッシュ** - 同一ピアへの重複ダイアル防止

### 低優先度
- [x] **AutoNAT v2対応** - ノンスベース検証プロトコル ✅ 2026-02-08
- [ ] **自動アドレス広告** - NATステータス変化時のIdentify Push連携
- [x] **並列ダイアルバック** - `dialBackParallel()` で実装済み ✅

## References

- [AutoNAT v1 Spec](https://github.com/libp2p/specs/blob/master/autonat/README.md)
- [rust-libp2p autonat](https://github.com/libp2p/rust-libp2p/tree/master/protocols/autonat)

## テスト実装状況

| テストスイート | テスト数 | 説明 |
|--------------|---------|------|
| `AutoNATProtocolTests` | 2 | プロトコルID、メッセージサイズ |
| `AutoNATProtobufTests` | 15 | Protobufエンコード/デコード |
| `AutoNATErrorTests` | 3 | エラー型、RateLimitReason |
| `AutoNATEventTests` | 5 | イベント型 |
| `AutoNATServiceTests` | 12 | サービス初期化、シャットダウン |
| `AutoNATRateLimitingTests` | 6 | レート制限設定、イベント |
| `AutoNATIntegrationTests` | 15 | 統合テスト |
| `NATStatusTests` | 7 | NATステータス判定 |
| `NATStatusTransitionTests` | 5 | ステータス遷移 |
| `NATStatusErrorHandlingTests` | 2 | エラー処理 |
| `ProbeResultTests` | 2 | プローブ結果 |

| `AutoNATv2NonceTests` | 7 | ノンス生成・検証 |
| `AutoNATv2ConcurrentNonceTests` | 1 | 並行ノンス操作 |
| `AutoNATv2ExpiredNonceTests` | 3 | 期限切れノンスクリーンアップ |
| `AutoNATv2RateLimitingTests` | 4 | クールダウン制限 |
| `AutoNATv2ReachabilityTests` | 3 | 到達性状態 |
| `AutoNATv2MessageTests` | 13 | メッセージエンコード/デコード |
| `AutoNATv2DialStatusTests` | 3 | DialStatusテスト |
| `AutoNATv2EventTests` | 3 | イベント発行 |
| `AutoNATv2ShutdownTests` | 4 | EventEmittingシャットダウン |
| `AutoNATv2ErrorTests` | 2 | エラー型 |
| `AutoNATv2HandlerTests` | 1 | ハンドラー初期化 |
| `AutoNATv2ProtocolTests` | 6 | プロトコル定数 |
| `AutoNATv2MessageTypeTests` | 4 | メッセージ型等値性 |

**合計: 134テスト** (v1: 74, v2: 53, その他: 7) (2026-02-08時点)

## Codex Review (2026-01-18) - UPDATED 2026-01-23

### Warning
| Issue | Location | Status | Description |
|-------|----------|--------|-------------|
| ~~IPv6 normalization incorrect~~ | `AutoNATService.swift:421-469` | ✅ Fixed | `normalizeIPv6()` strips zone identifiers, validates characters, and rejects multiple `::` |

<!-- CONTEXT_EVAL_START -->
## 実装評価 (2026-02-16)

- 総合評価: **A** (99/100)
- 対象ターゲット: `P2PAutoNAT`
- 実装読解範囲: 11 Swift files / 2830 LOC
- テスト範囲: 5 files / 142 cases / targets 1
- 公開API: types 27 / funcs 10
- 参照網羅率: type 0.96 / func 0.6
- 未参照公開型: 1 件（例: `AutoNATDial`）
- 実装リスク指標: try?=0, forceUnwrap=1, forceCast=0, @unchecked Sendable=0, EventLoopFuture=0, DispatchQueue=0
- 評価所見: 強制アンラップを含む実装がある

### 重点アクション
- 未参照の公開型に対する直接テスト（生成・失敗系・境界値）を追加する。
- 強制アンラップ箇所に前提条件テストを追加し、回帰時に即検出できるようにする。

※ 参照網羅率は「テストコード内での公開API名参照」を基準にした静的評価であり、動的実行結果そのものではありません。

<!-- CONTEXT_EVAL_END -->
