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
