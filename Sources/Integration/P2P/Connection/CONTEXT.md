# Connection Directory Context

> **Purpose**: Connection resilience components for managing connection lifecycle

## Overview

This directory contains components for connection pool management, automatic reconnection, connection limits, gating, and health monitoring.

## Components

| File | Type | Responsibility |
|------|------|----------------|
| `ConnectionID.swift` | struct | Unique connection identifier |
| `ConnectionDirection.swift` | enum | Inbound/outbound direction |
| `ConnectionState.swift` | enum | Connection state machine |
| `DisconnectReason.swift` | enum | Disconnect reason codes |
| `ConnectionLimits.swift` | struct | High/low watermark settings |
| `BackoffStrategy.swift` | struct | Exponential backoff for reconnection |
| `ReconnectionPolicy.swift` | struct | Reconnection behavior settings |
| `ConnectionGater.swift` | protocol | Connection filtering interface |
| `ConnectionPool.swift` | class | Central connection state manager (internal) |
| `ConnectionTrimReport.swift` | struct | Trim decision inspection snapshot for diagnostics |
| `ConnectionTrimmedContext.swift` | struct | Structured metadata for `ConnectionEvent.trimmedWithContext` |
| `HealthMonitor.swift` | actor | Ping-based health checking |
| `ConnectionEvent.swift` | enum | Connection-related events |

## Design Principles

### ConnectionPool is Internal

`ConnectionPool` is `internal` and only accessed by `Node` actor. This ensures:
- Node actor serializes all access
- No external parallel access concerns
- Clean responsibility separation (Node=API, Pool=state)

### Mutex Pattern

All mutable state uses `Mutex<StateStruct>`:
```swift
private let state: Mutex<PoolState>
state.withLock { $0.connections[id] = conn }
```

Never call async functions inside `withLock`.

### Atomic Activity Tracking

`ConnectionPool.connection(to:)` atomically retrieves a connection AND records activity:
```swift
func connection(to peer: PeerID) -> (any MuxedConnection)? {
    let now = ContinuousClock.now
    return state.withLock { state in
        // ... find connection ...
        state.connections[id]?.lastActivity = now  // Atomic update
        return managed.connection
    }
}
```

This design ensures:
- No separate `recordActivity()` call needed by callers
- Activity is always recorded when a connection is used
- Single atomic operation (no TOCTOU issues)

### State Machine

Connection states follow this flow:
```
Idle → Connecting → Connected → Disconnected → Reconnecting → ...
                                     ↓
                                  Failed
```

## Dependencies

```
ConnectionID ──┐
ConnectionDirection ──┼──▶ ConnectionState ──┐
DisconnectReason ─────┘                      │
                                             │
BackoffStrategy ──▶ ReconnectionPolicy ──────┼──▶ ConnectionPool
ConnectionLimits ────────────────────────────┤
ConnectionGater ─────────────────────────────┤
                                             │
PingProvider ──▶ HealthMonitor ──────────────┘
                                             │
                                             ▼
                                           Node
```

## Reference

See `DESIGN-CONNECTION-RESILIENCE.md` for detailed design decisions.

<!-- CONTEXT_EVAL_START -->
## 実装評価 (2026-02-16)

- 総合評価: **A** (92/100)
- 対象ターゲット: `P2P`
- 実装読解範囲: 30 Swift files / 6434 LOC
- テスト範囲: 11 files / 188 cases / targets 1
- 公開API: types 46 / funcs 60
- 参照網羅率: type 0.63 / func 0.75
- 未参照公開型: 17 件（例: `AllowAllGater`, `Candidate`, `CompositeGater`, `ConnectionDirection`, `ConnectionID`）
- 実装リスク指標: try?=0, forceUnwrap=0, forceCast=0, @unchecked Sendable=0, EventLoopFuture=0, DispatchQueue=0
- 評価所見: 重大な静的リスクは検出されず

### 重点アクション
- 未参照の公開型に対する直接テスト（生成・失敗系・境界値）を追加する。

※ 参照網羅率は「テストコード内での公開API名参照」を基準にした静的評価であり、動的実行結果そのものではありません。

<!-- CONTEXT_EVAL_END -->
