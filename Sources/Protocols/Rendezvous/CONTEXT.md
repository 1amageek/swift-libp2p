# P2PRendezvous

## Overview

Rendezvous protocol implementation for namespace-based peer discovery.

Peers register themselves under named namespaces at a rendezvous point, and other peers can discover them by querying the same namespace. This enables lightweight, topic-based peer discovery without a full DHT.

## Protocol ID

- `/rendezvous/1.0.0`

## Dependencies

- `P2PCore` (PeerID, Multiaddr, EventEmitting)
- `P2PProtocols` (ProtocolService)

---

## File Structure

```
Sources/Protocols/Rendezvous/
├── RendezvousProtocol.swift     # Protocol constants
├── RendezvousMessages.swift     # Wire protocol message types
├── RendezvousError.swift        # Error types
├── RendezvousService.swift      # Client service (register/discover)
├── RendezvousPoint.swift        # Server-side rendezvous point
└── CONTEXT.md
```

## Key Types

| Type | Description |
|------|-------------|
| `RendezvousProtocol` | Protocol constants (ID, limits, defaults) |
| `RendezvousMessageType` | Wire protocol message type enum |
| `RendezvousRegistration` | A peer's registration entry |
| `RendezvousStatus` | Response status codes |
| `RendezvousError` | Error types for all operations |
| `RendezvousService` | Client service for registering/discovering |
| `RendezvousPoint` | Server-side rendezvous point |

---

## Architecture

### Client (RendezvousService)

- Manages local registration state
- Provides discovery with local caching
- Emits events via EventEmitting pattern (single consumer)
- Configuration: default TTL, auto-refresh, refresh buffer

### Server (RendezvousPoint)

- Stores registrations per namespace
- Supports cookie-based paginated discovery
- Enforces limits: per-peer, per-namespace, total namespaces
- Periodic expired registration cleanup
- Emits events via EventEmitting pattern (single consumer)

## Wire Protocol

### Message Types

| Type | Code | Direction | Description |
|------|------|-----------|-------------|
| Register | 0 | Client -> Server | Register under namespace |
| RegisterResponse | 1 | Server -> Client | Registration result |
| Unregister | 2 | Client -> Server | Remove registration |
| Discover | 3 | Client -> Server | Query namespace |
| DiscoverResponse | 4 | Server -> Client | Query results |

### Registration Flow

```
Client                    RendezvousPoint
   |-- Register(ns, ttl) ------>|
   |<-- RegisterResponse(ok) ---|
   |                            | (stores registration)
   |                            |
   |-- Discover(ns) ----------->|
   |<-- DiscoverResponse(peers) |
```

### Cookie-Based Pagination

```
Client                    RendezvousPoint
   |-- Discover(ns) ----------->|
   |<-- Response(peers, cookie) |
   |                            |
   |-- Discover(ns, cookie) --->|
   |<-- Response(more, cookie2) |
   |                            |
   |-- Discover(ns, cookie2) -->|
   |<-- Response(rest, nil) ----|
```

## Concurrency Model

- **Class + Mutex** for both RendezvousService and RendezvousPoint
- Separate Mutex instances for event state and service/point state
- Events emitted outside of locks to prevent deadlocks

## Lifecycle

- `shutdown() async` - Terminates event stream (EventEmitting protocol)

## Configuration

### RendezvousService.Configuration

| Parameter | Default | Description |
|-----------|---------|-------------|
| `defaultTTL` | 2 hours | Default TTL for registrations |
| `autoRefresh` | true | Auto-refresh before expiry |
| `refreshBuffer` | 5 minutes | Buffer before expiry |

### RendezvousPoint.Configuration

| Parameter | Default | Description |
|-----------|---------|-------------|
| `maxRegistrationsPerPeer` | 100 | Max registrations per peer |
| `maxRegistrationsPerNamespace` | 1000 | Max registrations per namespace |
| `maxNamespaces` | 10000 | Max namespaces tracked |

## Tests

```
Tests/Protocols/RendezvousTests/
└── RendezvousTests.swift    # Comprehensive tests
```

## References

- [Rendezvous Spec](https://github.com/libp2p/specs/blob/master/rendezvous/README.md)
- [go-libp2p-rendezvous](https://github.com/libp2p/go-libp2p-rendezvous)

<!-- CONTEXT_EVAL_START -->
## 実装評価 (2026-02-16)

- 総合評価: **A** (100/100)
- 対象ターゲット: `P2PRendezvous`
- 実装読解範囲: 5 Swift files / 1047 LOC
- テスト範囲: 1 files / 93 cases / targets 1
- 公開API: types 11 / funcs 10
- 参照網羅率: type 1.0 / func 1.0
- 未参照公開型: 0 件（例: `なし`）
- 実装リスク指標: try?=0, forceUnwrap=0, forceCast=0, @unchecked Sendable=0, EventLoopFuture=0, DispatchQueue=0
- 評価所見: 重大な静的リスクは検出されず

### 重点アクション
- 現行のテスト網羅を維持し、機能追加時は同一粒度でテストを増やす。

※ 参照網羅率は「テストコード内での公開API名参照」を基準にした静的評価であり、動的実行結果そのものではありません。

<!-- CONTEXT_EVAL_END -->
